/* Minimal stand-ins for the QMK core headers, so battery_report.c can be
 * compiled on the host against the *real* Keychron headers. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include "action.h"
typedef struct { int dummy; } event_listener_t;
uint32_t timer_read32(void);
uint32_t timer_elapsed32(uint32_t last);
#define timer_expired32(current, future) ((uint32_t)((current) - (future)) < UINT32_MAX / 2)
