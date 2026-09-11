/* Copyright 2026
 *
 * Host-driven keyboard control. See keyboard_control.h for the protocol.
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
#include "keyboard_control.h"
#include "battery_report.h"

#if defined(LED_MATRIX_ENABLE)
#    include "led_matrix.h"
#elif defined(RGB_MATRIX_ENABLE)
#    include "rgb_matrix.h"
#endif

/* ------------------------------------------------------------------ */
/* Lighting abstraction                                               */
/* ------------------------------------------------------------------ */

/* One shim per operation so the action handling below reads the same
 * regardless of which matrix the board was built with. */

#if defined(LED_MATRIX_ENABLE)

#    define LIGHTING_KIND        KEYBOARD_LIGHTING_LED_MATRIX
#    define lighting_is_enabled  led_matrix_is_enabled
#    define lighting_enable      led_matrix_enable
#    define lighting_disable     led_matrix_disable
#    define lighting_toggle      led_matrix_toggle
#    define lighting_get_val     led_matrix_get_val
#    define lighting_set_val     led_matrix_set_val
#    define lighting_increase    led_matrix_increase_val
#    define lighting_decrease    led_matrix_decrease_val
#    define lighting_get_mode    led_matrix_get_mode
#    define lighting_set_mode    led_matrix_mode
#    define lighting_step        led_matrix_step
#    define lighting_step_back   led_matrix_step_reverse
#    define LIGHTING_EFFECT_MAX  LED_MATRIX_EFFECT_MAX

#elif defined(RGB_MATRIX_ENABLE)

#    define LIGHTING_KIND        KEYBOARD_LIGHTING_RGB_MATRIX
#    define lighting_is_enabled  rgb_matrix_is_enabled
#    define lighting_enable      rgb_matrix_enable
#    define lighting_disable     rgb_matrix_disable
#    define lighting_toggle      rgb_matrix_toggle
#    define lighting_get_val     rgb_matrix_get_val
#    define lighting_set_val     rgb_matrix_set_val
#    define lighting_increase    rgb_matrix_increase_val
#    define lighting_decrease    rgb_matrix_decrease_val
#    define lighting_get_mode    rgb_matrix_get_mode
#    define lighting_set_mode    rgb_matrix_mode
#    define lighting_step        rgb_matrix_step
#    define lighting_step_back   rgb_matrix_step_reverse
#    define LIGHTING_EFFECT_MAX  RGB_MATRIX_EFFECT_MAX

#endif

/* ------------------------------------------------------------------ */
/* State                                                              */
/* ------------------------------------------------------------------ */

/* The action field as last read, with the time it took that value. Used to
 * tell a settled value from one still being assembled. */
static uint8_t  observed_action = KEYBOARD_ACTION_NONE;
static uint32_t observed_since  = 0;

/* Last value that stayed put long enough to be believed. A new settled value
 * triggers once; the host clearing the field settles zero and re-arms. */
static uint8_t  stable_action   = KEYBOARD_ACTION_NONE;

/* Raw LED byte as last received, echoed back to the host so it can confirm
 * the spare bits survive the wireless module. */
static uint8_t last_led_byte = 0;

/* Every LED bit ever observed, OR-ed. Sticky, because last_led_byte alone is
 * overwritten on the next poll and cannot show a brief pulse. */
static uint8_t led_seen_mask = 0;

/* How many times the LED byte changed. Zero proves no host LED report reaches
 * the firmware, which separates "the module drops it" from "the spare bits
 * get stripped". */
static uint8_t led_change_count = 0;

/* Incremented on every applied action, letting the host tell "nothing
 * happened" apart from "it happened and changed nothing". */
static uint8_t action_seq = 0;

/* The last action acted on and the LED byte it came from, so a host can see
 * what the keyboard actually decoded rather than what was intended. */
static uint8_t last_applied_action = 0;
static uint8_t last_applied_leds   = 0;

/* ------------------------------------------------------------------ */
/* Actions                                                            */
/* ------------------------------------------------------------------ */

void keyboard_control_apply(uint8_t action) {
    /* Not a lighting action, and wanted even on a board with no backlight. */
    if (action == KEYBOARD_ACTION_REPORT_BATTERY) {
        battery_report_force_beacon();
        action_seq++;
        return;
    }

#if defined(LIGHTING_KIND)
    switch (action) {
        case KEYBOARD_ACTION_BACKLIGHT_TOGGLE:
            lighting_toggle();
            break;
        case KEYBOARD_ACTION_BACKLIGHT_OFF:
            lighting_disable();
            break;
        case KEYBOARD_ACTION_BACKLIGHT_ON:
            lighting_enable();
            break;
        case KEYBOARD_ACTION_BRIGHTNESS_UP:
            /* Raising brightness on a disabled backlight would do nothing
             * visible, so treat it as "turn it on". */
            if (!lighting_is_enabled()) {
                lighting_enable();
            } else {
                lighting_increase();
            }
            break;
        case KEYBOARD_ACTION_BRIGHTNESS_DOWN:
            lighting_decrease();
            break;
        case KEYBOARD_ACTION_EFFECT_NEXT:
            lighting_step();
            break;
        case KEYBOARD_ACTION_EFFECT_PREV:
            lighting_step_back();
            break;
        default:
            return;
    }
    action_seq++;
#else
    (void)action;
#endif
}

/* ------------------------------------------------------------------ */
/* LED output report channel (works on USB and Bluetooth)             */
/* ------------------------------------------------------------------ */

void keyboard_control_task(void) {
    uint8_t leds   = host_keyboard_leds();
    uint8_t action = (leds & KEYBOARD_CONTROL_LED_MASK) >> KEYBOARD_CONTROL_LED_SHIFT;

    if (leds != last_led_byte) {
        last_led_byte = leds;
        led_seen_mask |= leds;
        led_change_count++;
    }

    /* Still moving: restart the settle window and wait. */
    if (action != observed_action) {
        observed_action = action;
        observed_since  = timer_read32();
        return;
    }

    if (action == stable_action) return;                                  /* nothing new  */
    if (timer_elapsed32(observed_since) < KEYBOARD_CONTROL_LED_SETTLE) return;

    stable_action = action;

    /* Zero is the idle state, which only re-arms. */
    if (action != KEYBOARD_ACTION_NONE) {
        last_applied_action = action;
        last_applied_leds   = leds;
        keyboard_control_apply(action);
    }
}

/* ------------------------------------------------------------------ */
/* Raw HID channel (USB)                                              */
/* ------------------------------------------------------------------ */

static void keyboard_control_send_state(void) {
    uint8_t data[RAW_EPSIZE] = {0};

    data[KEYBOARD_CONTROL_OFF_CMD]        = KEYBOARD_CONTROL_RAW_HID_CMD;
    data[KEYBOARD_CONTROL_OFF_SUB]        = KEYBOARD_CONTROL_SUB_STATE;
    data[KEYBOARD_CONTROL_OFF_VERSION]    = KEYBOARD_CONTROL_PROTOCOL_VERSION;
#if defined(LIGHTING_KIND)
    data[KEYBOARD_CONTROL_OFF_ENABLED]    = lighting_is_enabled() ? 1 : 0;
    data[KEYBOARD_CONTROL_OFF_BRIGHTNESS] = lighting_get_val();
    data[KEYBOARD_CONTROL_OFF_EFFECT]     = lighting_get_mode();
    data[KEYBOARD_CONTROL_OFF_EFFECT_MAX] = LIGHTING_EFFECT_MAX - 1;
    data[KEYBOARD_CONTROL_OFF_LIGHTING]   = LIGHTING_KIND;
#else
    data[KEYBOARD_CONTROL_OFF_LIGHTING]   = KEYBOARD_LIGHTING_NONE;
#endif
    data[KEYBOARD_CONTROL_OFF_LED_BYTE]   = last_led_byte;
    data[KEYBOARD_CONTROL_OFF_ACTION_SEQ] = action_seq;
    data[KEYBOARD_CONTROL_OFF_LED_SEEN]    = led_seen_mask;
    data[KEYBOARD_CONTROL_OFF_LED_CHANGES] = led_change_count;
    data[KEYBOARD_CONTROL_OFF_LAST_ACTION] = last_applied_action;
    data[KEYBOARD_CONTROL_OFF_LAST_LEDS]   = last_applied_leds;

    uint16_t checksum = 0;
    for (uint8_t i = 1; i < RAW_EPSIZE - 2; i++) checksum += data[i];

    data[RAW_EPSIZE - 2] = checksum & 0xFF;
    data[RAW_EPSIZE - 1] = (checksum >> 8) & 0xFF;

    raw_hid_send(data, RAW_EPSIZE);
}

bool keyboard_control_raw_hid_rx(uint8_t *data, uint8_t length) {
    if (length < 2 || data[KEYBOARD_CONTROL_OFF_CMD] != KEYBOARD_CONTROL_RAW_HID_CMD) return false;

    switch (data[KEYBOARD_CONTROL_OFF_SUB]) {
        case KEYBOARD_CONTROL_SUB_GET:
            keyboard_control_send_state();
            return true;

        case KEYBOARD_CONTROL_SUB_ACTION:
            if (length < 3) return false;
            keyboard_control_apply(data[2]);
            keyboard_control_send_state();
            return true;

        case KEYBOARD_CONTROL_SUB_SET:
            if (length < 4) return false;
#if defined(LIGHTING_KIND)
            switch (data[2]) {
                case KEYBOARD_SETTING_BRIGHTNESS:
                    lighting_set_val(data[3]);
                    action_seq++;
                    break;
                case KEYBOARD_SETTING_EFFECT:
                    if (data[3] < LIGHTING_EFFECT_MAX) {
                        lighting_set_mode(data[3]);
                        action_seq++;
                    }
                    break;
                default:
                    return false;
            }
#endif
            keyboard_control_send_state();
            return true;

        default:
            return false;
    }
}
