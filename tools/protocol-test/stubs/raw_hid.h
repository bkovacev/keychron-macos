#pragma once
#include <stdint.h>
#define RAW_EPSIZE 32
void raw_hid_send(uint8_t *data, uint8_t length);
