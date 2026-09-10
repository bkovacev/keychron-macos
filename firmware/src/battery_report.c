/* Copyright 2026
 *
 * Battery reporting for Keychron K Pro / Q Pro (CKBT51) keyboards.
 * See battery_report.h for the protocol description.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "quantum.h"
#include "raw_hid.h"
#include "battery.h"
#include "battery_report.h"
#include "bluetooth.h"
#include "ckbt51.h"
#include "lpm.h"
#include "transport.h"

/* ------------------------------------------------------------------ */
/* State                                                              */
/* ------------------------------------------------------------------ */

static bool     has_sample        = false;
static uint32_t sample_time       = 0;

/* Timestamps below are only meaningful when their companion flag is set. A
 * zero sentinel is not usable here: timer_read32() legitimately returns 0 once
 * per wrap, and nudging a timestamp off zero would put it in the future and
 * make timer_elapsed32() underflow. */
static uint32_t last_key_activity  = 0;
static bool     key_activity_seen  = false;

/* Keys currently held. The beacon waits for this to reach zero. */
static uint8_t  keys_down          = 0;

static uint32_t last_beacon_time   = 0;
static bool     beacon_sent        = false;
static uint8_t  last_beacon_value  = BATTERY_REPORT_PERCENT_UNKNOWN;
static bool     last_beacon_chg    = false;
static bool     beacon_dirty       = false;

/* Pending release of the beacon usage. */
static uint32_t release_due        = 0;
static bool     release_pending    = false;

/* Previous link state, so a fresh connection can be detected without claiming
 * one of the bluetooth_enter_*_kb() hooks, which boards already define. */
static bluetooth_state_t prev_bt_state = BLUETOOTH_RESET;

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

uint8_t battery_report_get_percentage(void) {
    if (!has_sample) return BATTERY_REPORT_PERCENT_UNKNOWN;

    uint8_t pct = battery_get_percentage();
    return pct > 100 ? 100 : pct;
}

static uint8_t battery_report_flags(void) {
    uint8_t flags = 0;

    if (usb_power_connected()) flags |= BATTERY_REPORT_FLAG_USB_POWER;
    if (has_sample) flags |= BATTERY_REPORT_FLAG_HAS_SAMPLE;
    if (battery_is_empty()) flags |= BATTERY_REPORT_FLAG_EMPTY;
    if (battery_is_critical_low()) flags |= BATTERY_REPORT_FLAG_CRITICAL;

    return flags;
}

void battery_report_notify_sample(void) {
    has_sample   = true;
    sample_time  = timer_read32();
    beacon_dirty = true;
}

void battery_report_notify_key_activity(bool pressed) {
    last_key_activity = timer_read32();
    key_activity_seen = true;

    if (pressed) {
        if (keys_down < 0xFF) keys_down++;
    } else if (keys_down > 0) {
        keys_down--;
    }
}

/* ------------------------------------------------------------------ */
/* Raw HID (USB)                                                      */
/* ------------------------------------------------------------------ */

static void battery_report_send_state(void) {
    uint8_t  data[RAW_EPSIZE] = {0};
    uint16_t voltage          = battery_get_voltage();
    uint32_t age_ms           = has_sample ? timer_elapsed32(sample_time) : 0;
    uint32_t age_s            = age_ms / 1000;

    if (age_s > 0xFFFF) age_s = 0xFFFF;

    data[BATTERY_REPORT_OFF_CMD]         = BATTERY_REPORT_RAW_HID_CMD;
    data[BATTERY_REPORT_OFF_SUB]         = BATTERY_REPORT_SUB_STATE;
    data[BATTERY_REPORT_OFF_VERSION]     = BATTERY_REPORT_PROTOCOL_VERSION;
    data[BATTERY_REPORT_OFF_PERCENT]     = battery_report_get_percentage();
    data[BATTERY_REPORT_OFF_VOLTAGE]     = voltage & 0xFF;
    data[BATTERY_REPORT_OFF_VOLTAGE + 1] = (voltage >> 8) & 0xFF;
    data[BATTERY_REPORT_OFF_FLAGS]       = battery_report_flags();
    data[BATTERY_REPORT_OFF_TRANSPORT]   = (uint8_t)get_transport();
    data[BATTERY_REPORT_OFF_BT_STATE]    = (uint8_t)bluetooth_get_state();
    data[BATTERY_REPORT_OFF_BT_HOST]     = bluetooth_get_host_index();
    data[BATTERY_REPORT_OFF_AGE]         = age_s & 0xFF;
    data[BATTERY_REPORT_OFF_AGE + 1]     = (age_s >> 8) & 0xFF;

    /* Same checksum convention as Keychron's factory test packets. */
    uint16_t checksum = 0;
    for (uint8_t i = 1; i < RAW_EPSIZE - 2; i++) checksum += data[i];

    data[RAW_EPSIZE - 2] = checksum & 0xFF;
    data[RAW_EPSIZE - 1] = (checksum >> 8) & 0xFF;

    raw_hid_send(data, RAW_EPSIZE);
}

bool battery_report_raw_hid_rx(uint8_t *data, uint8_t length) {
    if (length < 2 || data[BATTERY_REPORT_OFF_CMD] != BATTERY_REPORT_RAW_HID_CMD) return false;

    switch (data[BATTERY_REPORT_OFF_SUB]) {
        case BATTERY_REPORT_SUB_GET:
            battery_report_send_state();
            return true;
        default:
            return false;
    }
}

/* ------------------------------------------------------------------ */
/* Bluetooth beacon                                                   */
/* ------------------------------------------------------------------ */

/* Go through Keychron's own send path rather than straight at the module.
 * bluetooth_send_consumer() honours report_buffer's minimum interval and
 * enqueues when a report is already in flight; calling ckbt51_send_consumer()
 * directly jumps that queue and can corrupt the report stream while the user
 * is typing. */
extern void bluetooth_send_consumer(uint16_t data);

static void beacon_send(uint16_t usage) {
    bluetooth_send_consumer(usage);
}

static bool beacon_link_ready(void) {
    return get_transport() == TRANSPORT_BLUETOOTH && bluetooth_get_state() == BLUETOOTH_CONNECTED;
}

/* The host is only considered awake for a short window after real typing.
 * Beaconing outside that window could wake a sleeping display. */
static bool beacon_host_awake(void) {
    return key_activity_seen && timer_elapsed32(last_key_activity) < BATTERY_BEACON_ACTIVITY_WINDOW;
}

/* Never transmit while a key is down, or in the moments right after an event
 * when more are likely. Both protect the keyboard's own report stream, which
 * matters most for held keys the host is auto-repeating. */
static bool beacon_line_quiet(void) {
    return keys_down == 0 && timer_elapsed32(last_key_activity) > BATTERY_BEACON_QUIET_TIME;
}

static bool beacon_due(uint8_t pct, bool charging) {
    if (!beacon_sent) return true;

    uint32_t since = timer_elapsed32(last_beacon_time);

    if (since < BATTERY_BEACON_MIN_INTERVAL) return false;
    if (pct != last_beacon_value || charging != last_beacon_chg) return true;

    return since >= BATTERY_BEACON_REFRESH_INTERVAL;
}

/* A host that has just connected holds no value yet, so make the next
 * opportunity beacon regardless of the refresh interval. */
static void beacon_track_link(void) {
    bluetooth_state_t bt_state = bluetooth_get_state();
    if (bt_state == prev_bt_state) return;

    if (bt_state == BLUETOOTH_CONNECTED) {
        beacon_sent       = false;
        last_beacon_value = BATTERY_REPORT_PERCENT_UNKNOWN;
        beacon_dirty      = true;
    } else {
        release_pending = false;
    }
    prev_bt_state = bt_state;
}

void battery_report_task(void) {
    beacon_track_link();

    /* Release a previously sent beacon usage. */
    if (release_pending) {
        if (!timer_expired32(timer_read32(), release_due)) return;

        release_pending = false;
        if (beacon_link_ready()) beacon_send(BATTERY_BEACON_RELEASE);
        return;
    }

    if (!beacon_link_ready() || !beacon_host_awake() || !beacon_line_quiet()) return;

    uint8_t pct = battery_report_get_percentage();
    if (pct == BATTERY_REPORT_PERCENT_UNKNOWN) return;

    bool charging = usb_power_connected();
    if (!beacon_dirty && !beacon_due(pct, charging)) return;

    beacon_dirty = false;

    uint16_t base = charging ? BATTERY_BEACON_BASE_CHARGING : BATTERY_BEACON_BASE_DISCHARGING;
    beacon_send(base + pct);

    last_beacon_time  = timer_read32();
    beacon_sent       = true;
    last_beacon_value = pct;
    last_beacon_chg   = charging;
    release_due       = last_beacon_time + BATTERY_BEACON_RELEASE_DELAY;
    release_pending   = true;
}

/* Defined strongly by keyboard_control.c when that feature is compiled in.
 * The weak stub keeps this file usable on its own. */
__attribute__((weak)) void keyboard_control_task(void) {}

/* bluetooth_main.c declares this weak and calls it once per housekeeping
 * cycle, right after bluetooth_task(). No board defines it, so claiming it
 * here needs no changes to Keychron's own sources. */
void bluetooth_post_task(void) {
    battery_report_task();
    keyboard_control_task();
}
