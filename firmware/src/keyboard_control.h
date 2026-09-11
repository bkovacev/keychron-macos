/* Copyright 2026
 *
 * Host-driven keyboard control (backlight and lighting effects) for Keychron
 * K Pro / Q Pro (CKBT51) keyboards.
 *
 * Two transports, one action vocabulary:
 *
 *   1. Raw HID (USB)  - precise actions plus state readback.
 *   2. LED output report - the host sets individual LED output elements and
 *      the action is read out of them. This is the only host-to-keyboard
 *      channel that exists over Bluetooth, and it works because the CKBT51
 *      hands the whole LED byte to the firmware
 *      (CKBT51_EVT_HID_EVENT -> led_state -> bluetooth_keyboard_leds()).
 *
 *      Note macOS will *not* let an ordinary process write a raw output
 *      report to a keyboard - IOHIDDeviceSetReport reports success and
 *      transmits nothing - but it does honour IOHIDDeviceSetValue on the
 *      report's individual LED elements. So the action has to live in real LED
 *      usages rather than in the report's spare padding bits.
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

/* Raw HID command byte, one past the battery feature's 0xAC. */
#ifndef KEYBOARD_CONTROL_RAW_HID_CMD
#    define KEYBOARD_CONTROL_RAW_HID_CMD 0xAD
#endif

#define KEYBOARD_CONTROL_PROTOCOL_VERSION 0x01

enum keyboard_control_subcmd {
    KEYBOARD_CONTROL_SUB_GET    = 0x01, /* host -> kb: report current state   */
    KEYBOARD_CONTROL_SUB_ACTION = 0x02, /* host -> kb: perform data[2]        */
    KEYBOARD_CONTROL_SUB_SET    = 0x03, /* host -> kb: set brightness/effect  */
    KEYBOARD_CONTROL_SUB_STATE  = 0x81, /* kb -> host: state payload          */
};

/* One vocabulary for both transports so behaviour cannot drift between them.
 *
 * Only 1..7 fit the LED channel's three bits, so those seven slots go to the
 * actions worth having wirelessly. Raw HID carries a whole byte and can reach
 * anything above that, which is where the rarer actions live.
 *
 * REPORT_BATTERY earns a wireless slot because without it a host has no way to
 * ask: over Bluetooth the keyboard pushes its level and nothing can prompt it,
 * so a "refresh" button would silently do nothing. */
enum keyboard_control_action {
    KEYBOARD_ACTION_NONE             = 0,
    KEYBOARD_ACTION_BACKLIGHT_TOGGLE = 1,
    KEYBOARD_ACTION_BACKLIGHT_OFF    = 2,
    KEYBOARD_ACTION_BACKLIGHT_ON     = 3,
    KEYBOARD_ACTION_BRIGHTNESS_UP    = 4,
    KEYBOARD_ACTION_BRIGHTNESS_DOWN  = 5,
    KEYBOARD_ACTION_EFFECT_NEXT      = 6,
    KEYBOARD_ACTION_REPORT_BATTERY   = 7,  /* last slot the LED channel reaches */
    KEYBOARD_ACTION_EFFECT_PREV      = 8,  /* raw HID only */
    KEYBOARD_ACTION_MAX
};

/* Which LED bits carry the action.
 *
 * Caps Lock (0x02) is driven by the OS, and Num Lock (0x01) lights a real
 * indicator on this board via NUM_LOCK_INDEX. The remaining three light
 * nothing here - Keychron's indicator code guards every use of them behind
 * SCROLL_LOCK_INDEX / COMPOSE_LOCK_INDEX / KANA_LOCK_INDEX, none of which the
 * K10 Pro defines - so driving them has no visible or functional effect:
 *
 *   0x04  Scroll Lock  -> action bit 0
 *   0x08  Compose      -> action bit 1
 *   0x10  Kana         -> action bit 2
 *
 * They are adjacent, so one shift extracts the field. Three bits is exactly
 * enough for the seven actions below. */
#define KEYBOARD_CONTROL_LED_SHIFT 2
#define KEYBOARD_CONTROL_LED_MASK  0x1C

/* How long the action field must hold a value before it is acted on.
 *
 * A host sets LED elements one at a time, and each one becomes its own output
 * report, so the field passes through intermediate values on the way to the
 * one that was intended: setting 0b101 momentarily reads as 0b001. Waiting for
 * the value to stop changing discards those. Must comfortably exceed the time
 * for a host's writes to arrive - a few reports at the module's ~3 ms pacing -
 * while staying imperceptible. */
#ifndef KEYBOARD_CONTROL_LED_SETTLE
#    define KEYBOARD_CONTROL_LED_SETTLE 50 /* ms */
#endif

/* KEYBOARD_CONTROL_SUB_SET selectors, in data[2], value in data[3]. */
enum keyboard_control_setting {
    KEYBOARD_SETTING_BRIGHTNESS = 0x01,
    KEYBOARD_SETTING_EFFECT     = 0x02,
};

/* Lighting hardware this board actually has. */
enum keyboard_control_lighting {
    KEYBOARD_LIGHTING_NONE       = 0,
    KEYBOARD_LIGHTING_LED_MATRIX = 1, /* single-colour, e.g. white K10 Pro   */
    KEYBOARD_LIGHTING_RGB_MATRIX = 2,
};

/* KEYBOARD_CONTROL_SUB_STATE payload:
 *
 *   [0] 0xAD          command
 *   [1] 0x81          subcommand
 *   [2] version
 *   [3] enabled       0 or 1
 *   [4] brightness    0..255
 *   [5] effect        current effect index
 *   [6] effect count  number of effects, so the host can wrap
 *   [7] lighting      keyboard_control_lighting
 *   [8] led byte      last LED output report seen, raw.
 *                     Present so the host can confirm the spare bits survive
 *                     the trip through the wireless module.
 *   [9] actions       count of actions applied since boot, a liveness check
 *  [10] led seen      every LED bit ever observed, OR-ed together. Sticky, so
 *                     a brief pulse cannot be missed between polls.
 *  [11] led changes   number of times the LED byte changed since boot. Zero
 *                     means no host LED report reaches the firmware at all.
 *  [12] last action    the action value most recently acted on
 *  [13] last leds      the LED byte it was decoded from
 *  [14..RAW_EPSIZE-3] reserved, zero
 *  [RAW_EPSIZE-2..-1] checksum of bytes [1 .. RAW_EPSIZE-3], little endian
 */
enum keyboard_control_offset {
    KEYBOARD_CONTROL_OFF_CMD         = 0,
    KEYBOARD_CONTROL_OFF_SUB         = 1,
    KEYBOARD_CONTROL_OFF_VERSION     = 2,
    KEYBOARD_CONTROL_OFF_ENABLED     = 3,
    KEYBOARD_CONTROL_OFF_BRIGHTNESS  = 4,
    KEYBOARD_CONTROL_OFF_EFFECT      = 5,
    KEYBOARD_CONTROL_OFF_EFFECT_MAX  = 6,
    KEYBOARD_CONTROL_OFF_LIGHTING    = 7,
    KEYBOARD_CONTROL_OFF_LED_BYTE    = 8,
    KEYBOARD_CONTROL_OFF_ACTION_SEQ  = 9,
    KEYBOARD_CONTROL_OFF_LED_SEEN     = 10,
    KEYBOARD_CONTROL_OFF_LED_CHANGES  = 11,
    KEYBOARD_CONTROL_OFF_LAST_ACTION  = 12,
    KEYBOARD_CONTROL_OFF_LAST_LEDS    = 13,
};

/* Handle a raw HID packet whose data[0] == KEYBOARD_CONTROL_RAW_HID_CMD. */
bool keyboard_control_raw_hid_rx(uint8_t *data, uint8_t length);

/* Poll the host LED report for an encoded action. Ticked from
 * bluetooth_post_task(). */
void keyboard_control_task(void);

/* Perform an action. Exposed so a keymap can bind one to a key if wanted. */
void keyboard_control_apply(uint8_t action);
