/* Compiles the real battery_report.c on the host, drives it with known state,
 * and prints the packets it produces as hex. The Swift decoder is then run
 * against that output, so the two sides of the protocol are checked against
 * each other rather than against a hand-written copy of the layout. */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "quantum.h"
#include "raw_hid.h"
#include "battery_report.h"
#include "transport.h"
#include "bluetooth.h"

/* ---- fake keyboard state, driven from main() ---- */
static uint8_t           f_percent   = 64;
static uint16_t          f_voltage   = 3982;
static bool              f_usb       = false;
static bool              f_empty     = false;
static bool              f_critical  = false;
static transport_t       f_transport = TRANSPORT_BLUETOOTH;
static bluetooth_state_t f_bt_state  = BLUETOOTH_CONNECTED;
static uint32_t          f_now       = 100000;
static uint8_t           f_bt_host   = 0;

uint8_t           battery_get_percentage(void)  { return f_percent; }
uint16_t          battery_get_voltage(void)     { return f_voltage; }
bool              battery_is_empty(void)        { return f_empty; }
bool              battery_is_critical_low(void) { return f_critical; }
bool              usb_power_connected(void)     { return f_usb; }
transport_t       get_transport(void)           { return f_transport; }
bluetooth_state_t bluetooth_get_state(void)     { return f_bt_state; }
uint8_t           bluetooth_get_host_index(void) { return f_bt_host; }

uint32_t timer_read32(void)                 { return f_now; }
uint32_t timer_elapsed32(uint32_t last)     { return f_now - last; }

/* unused by these paths but referenced by battery_report.c */
void battery_set_voltage(uint16_t v)   { (void)v; }
void battery_init(void)                {}
void battery_measure(void)             {}
bool battery_power_on_sample(void)     { return false; }
void battery_task(void)                {}
void indicator_battery_low_enable(bool e) { (void)e; }

/* ---- captured outputs ---- */
static void print_hex(const char *tag, const uint8_t *data, uint8_t len) {
    printf("%s ", tag);
    for (uint8_t i = 0; i < len; i++) printf("%02x", data[i]);
    printf("\n");
}

void raw_hid_send(uint8_t *data, uint8_t length) {
    print_hex("RAWHID", data, length);
}

/* The beacon now goes through Keychron's paced send path rather than straight
 * at the module, so that is what gets stubbed. */
void bluetooth_send_consumer(uint16_t report) {
    printf("BEACON %04x\n", report);
}

void ckbt51_send_consumer(uint16_t report) {
    printf("UNPACED %04x\n", report);   /* must never appear */
}

/* everything else ckbt51.h declares, unused here */
void ckbt51_init(bool w) { (void)w; }
void ckbt51_send_cmd(uint8_t *p, uint8_t l, bool a, bool r) { (void)p; (void)l; (void)a; (void)r; }
void ckbt51_send_keyboard(uint8_t *r) { (void)r; }
void ckbt51_send_nkro(uint8_t *r) { (void)r; }
void ckbt51_send_system(uint16_t r) { (void)r; }
void ckbt51_send_mouse(uint8_t *r) { (void)r; }
void ckbt51_task(void) {}

int main(void) {
    uint8_t get[RAW_EPSIZE];
    memset(get, 0, sizeof get);
    get[BATTERY_REPORT_OFF_CMD] = BATTERY_REPORT_RAW_HID_CMD;
    get[BATTERY_REPORT_OFF_SUB] = BATTERY_REPORT_SUB_GET;

    /* 1. no sample taken yet -> must refuse to invent a percentage */
    printf("CASE no-sample\n");
    battery_report_raw_hid_rx(get, RAW_EPSIZE);

    /* 2. discharging on bluetooth, sample 7s old */
    printf("CASE discharging\n");
    f_now = 100000;
    battery_report_notify_sample();
    f_now += 7000;
    battery_report_raw_hid_rx(get, RAW_EPSIZE);

    /* 3. charging, host 2, full */
    printf("CASE charging\n");
    f_usb     = true;
    f_percent = 100;
    f_voltage = 4142;
    f_bt_host = 2;
    battery_report_notify_sample();
    battery_report_raw_hid_rx(get, RAW_EPSIZE);

    /* 4. beacon: needs a connected BT link and recent typing */
    printf("CASE beacon-charging\n");
    battery_report_notify_key_activity(true);    /* press   */
    battery_report_notify_key_activity(false);   /* release */
    f_now += BATTERY_BEACON_QUIET_TIME + 1;      /* line goes quiet */
    battery_report_task();

    printf("CASE beacon-release\n");
    f_now += BATTERY_BEACON_RELEASE_DELAY + 1;
    battery_report_task();

    printf("CASE beacon-discharging\n");
    f_usb     = false;
    f_percent = 37;
    f_now    += BATTERY_BEACON_MIN_INTERVAL + 1;
    battery_report_notify_key_activity(true);
    battery_report_notify_key_activity(false);
    f_now    += BATTERY_BEACON_QUIET_TIME + 1;
    battery_report_notify_sample();
    battery_report_task();

    /* drain the release still pending from the beacon above, so the next case
     * starts from a quiet state */
    f_now += BATTERY_BEACON_RELEASE_DELAY + 1;
    battery_report_task();

    printf("CASE beacon-suppressed-when-idle\n");
    f_now += BATTERY_BEACON_ACTIVITY_WINDOW + BATTERY_BEACON_MIN_INTERVAL + 1;
    f_percent = 36;
    battery_report_notify_sample();
    battery_report_task();          /* must print nothing: host presumed asleep */

    printf("CASE beacon-suppressed-when-usb-transport\n");
    f_transport = TRANSPORT_USB;
    battery_report_notify_key_activity(true);
    battery_report_notify_key_activity(false);
    f_now += BATTERY_BEACON_QUIET_TIME + 1;
    battery_report_notify_sample();
    battery_report_task();          /* must print nothing */

    /* Restore the bluetooth transport and let anything the previous cases left
     * pending go out. Labelled so those emissions are not attributed to the
     * case before or the case after. */
    printf("CASE settle\n");
    f_transport = TRANSPORT_BLUETOOTH;
    for (int i = 0; i < 4; i++) {
        f_now += BATTERY_BEACON_RELEASE_DELAY + 1;
        battery_report_task();
    }

    printf("CASE beacon-suppressed-while-key-held\n");
    f_percent = 35;
    battery_report_notify_key_activity(true);     /* press, never released */
    f_now += BATTERY_BEACON_QUIET_TIME + BATTERY_BEACON_MIN_INTERVAL + 1;
    battery_report_notify_sample();
    battery_report_task();          /* must print nothing: a key is held */

    printf("CASE beacon-resumes-after-release\n");
    battery_report_notify_key_activity(false);    /* release */
    f_now += BATTERY_BEACON_QUIET_TIME + 1;
    battery_report_task();

    printf("DONE\n");
    return 0;
}
