/* Copyright 2026
 *
 * Battery reporting for Keychron K Pro / Q Pro (CKBT51) keyboards.
 *
 * The CKBT51 wireless module owns the Bluetooth HID report descriptor and it
 * contains no battery usage (verified by dumping the descriptor macOS receives
 * over the air), so a host can never learn the battery level through the normal
 * HID battery mechanism. This module adds two channels instead:
 *
 *   1. Raw HID (USB)  - exact voltage + percentage on request. Stays available
 *                       while the keyboard is in Bluetooth mode, because the
 *                       K10 Pro defines KEEP_USB_CONNECTION_IN_BLUETOOTH_MODE.
 *   2. Consumer beacon - the level encoded in an unassigned HID Consumer-page
 *      (Bluetooth)      usage, which hosts map to no action but a userspace HID
 *                       client can still read from the raw input report.
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

#pragma once

#include <stdint.h>
#include <stdbool.h>

/* ------------------------------------------------------------------ */
/* Raw HID protocol (USB)                                             */
/* ------------------------------------------------------------------ */

/* Command byte. Sits just past Keychron's own 0xAA (BT DFU) and 0xAB
 * (factory test) so it cannot collide with the Launcher. */
#ifndef BATTERY_REPORT_RAW_HID_CMD
#    define BATTERY_REPORT_RAW_HID_CMD 0xAC
#endif

/* Wire format version, bumped if the payload layout below ever changes. */
#define BATTERY_REPORT_PROTOCOL_VERSION 0x01

enum battery_report_subcmd {
    BATTERY_REPORT_SUB_GET   = 0x01, /* host -> keyboard: send me the state */
    BATTERY_REPORT_SUB_STATE = 0x81, /* keyboard -> host: state payload     */
};

/* Byte offsets inside a BATTERY_REPORT_SUB_STATE packet.
 *
 *   [0] 0xAC          command
 *   [1] 0x81          subcommand
 *   [2] version
 *   [3] percentage    0..100, or 0xFF when no sample has been taken yet
 *   [4] voltage lo    millivolts, little endian
 *   [5] voltage hi
 *   [6] flags         see battery_report_flags
 *   [7] transport     transport_t (0 none, 1 usb, 2 bluetooth)
 *   [8] bt state      bluetooth_state_t
 *   [9] bt host index 1..HOST_DEVICES_COUNT, 0 when unknown
 *  [10] age lo        seconds since the sample was taken, little endian
 *  [11] age hi
 *  [12..RAW_EPSIZE-3] reserved, zero
 *  [RAW_EPSIZE-2] checksum lo   sum of bytes [1 .. RAW_EPSIZE-3]
 *  [RAW_EPSIZE-1] checksum hi
 */
enum battery_report_offset {
    BATTERY_REPORT_OFF_CMD       = 0,
    BATTERY_REPORT_OFF_SUB       = 1,
    BATTERY_REPORT_OFF_VERSION   = 2,
    BATTERY_REPORT_OFF_PERCENT   = 3,
    BATTERY_REPORT_OFF_VOLTAGE   = 4,
    BATTERY_REPORT_OFF_FLAGS     = 6,
    BATTERY_REPORT_OFF_TRANSPORT = 7,
    BATTERY_REPORT_OFF_BT_STATE  = 8,
    BATTERY_REPORT_OFF_BT_HOST   = 9,
    BATTERY_REPORT_OFF_AGE       = 10,
};

enum battery_report_flags {
    BATTERY_REPORT_FLAG_USB_POWER    = 1 << 0, /* charger present            */
    BATTERY_REPORT_FLAG_HAS_SAMPLE   = 1 << 1, /* percentage is real         */
    BATTERY_REPORT_FLAG_EMPTY        = 1 << 2, /* battery_is_empty()         */
    BATTERY_REPORT_FLAG_CRITICAL     = 1 << 3, /* battery_is_critical_low()  */
};

#define BATTERY_REPORT_PERCENT_UNKNOWN 0xFF

/* ------------------------------------------------------------------ */
/* Bluetooth beacon                                                   */
/* ------------------------------------------------------------------ */

/* HID Consumer page usages 0x0300..0x03FF are unassigned in the HID Usage
 * Tables, and the CKBT51's consumer report declares Usage Minimum 0x0000 /
 * Usage Maximum 0x03FF, so these values travel intact and land on no host
 * action. Percentage is added to one of the two bases below. */
#define BATTERY_BEACON_BASE_DISCHARGING 0x0300
#define BATTERY_BEACON_BASE_CHARGING    0x0380
#define BATTERY_BEACON_RELEASE          0x0000

/* Only beacon while the host is demonstrably awake, i.e. shortly after real
 * key activity. Sending an unsolicited HID report to an idle host risks waking
 * its display, so the beacon always rides along with typing. */
#ifndef BATTERY_BEACON_ACTIVITY_WINDOW
#    define BATTERY_BEACON_ACTIVITY_WINDOW 60000 /* ms */
#endif

/* Never beacon more often than this, even if the level keeps changing. */
#ifndef BATTERY_BEACON_MIN_INTERVAL
#    define BATTERY_BEACON_MIN_INTERVAL 60000 /* ms */
#endif

/* Re-send an unchanged level at least this often, so a host that started
 * listening late still gets a value. */
#ifndef BATTERY_BEACON_REFRESH_INTERVAL
#    define BATTERY_BEACON_REFRESH_INTERVAL 300000 /* ms */
#endif

/* Stay off the air for this long after the last key event, so the beacon
 * never lands in the middle of a burst of typing. */
#ifndef BATTERY_BEACON_QUIET_TIME
#    define BATTERY_BEACON_QUIET_TIME 400 /* ms */
#endif

/* Delay between the beacon usage and its release. The consumer field is an
 * array, so the host expects the usage to be let go of again. */
#ifndef BATTERY_BEACON_RELEASE_DELAY
#    define BATTERY_BEACON_RELEASE_DELAY 20 /* ms */
#endif

/* ------------------------------------------------------------------ */
/* API                                                                */
/* ------------------------------------------------------------------ */

/* Handle a raw HID packet whose data[0] == BATTERY_REPORT_RAW_HID_CMD.
 * Returns true when the packet was consumed. */
bool battery_report_raw_hid_rx(uint8_t *data, uint8_t length);

/* Call when a fresh voltage sample has been stored, i.e. at the end of the
 * board's battery_calculte_voltage(). */
void battery_report_notify_sample(void);

/* Call on every key event so the beacon can piggyback on real activity.
 * `pressed` is tracked so the beacon can stay off the air while a key is
 * physically held: a held key is invisible in the event stream, because the
 * repeat is generated by the host, and interleaving a report mid-hold is what
 * disturbs it. */
void battery_report_notify_key_activity(bool pressed);

/* Send a level at the next safe opportunity, ignoring the rate limit and the
 * "has the host been typing" test. Used when a host explicitly asks, which is
 * itself proof it is awake. The guards that protect the keyboard's own report
 * stream still apply. */
void battery_report_force_beacon(void);

/* Beacon scheduler. Installed as bluetooth_post_task(), so boards that do not
 * define that hook get it for free. */
void battery_report_task(void);

/* Percentage as it would be reported, or BATTERY_REPORT_PERCENT_UNKNOWN when
 * no measurement has happened since boot. */
uint8_t battery_report_get_percentage(void);
