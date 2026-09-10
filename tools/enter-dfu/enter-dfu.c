/* Reboot a Keychron K Pro / Q Pro into DFU over USB, no keycap gymnastics.
 *
 * Uses Keychron's own factory-test command 0xAB / 0x03, which takes the
 * literal string "JumpToBootloader". Keychron ships this enabled but comments
 * it out in the public source; firmware/install.sh restores it, so this only
 * works on firmware built with that patch (or on a stock Keychron build).
 *
 *   cc -o enter-dfu enter-dfu.c -framework CoreFoundation -framework IOKit
 *   ./enter-dfu
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <string.h>

#define REPORT_SIZE 32
#define FACTORY_TEST_CMD 0xAB
#define FACTORY_TEST_CMD_JUMP_TO_BL 0x03

int main(void) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    /* QMK's raw HID interface: vendor page 0xFF60, usage 0x61. */
    int vid = 0x3434, page = 0xFF60, usage = 0x61;
    CFNumberRef nv = CFNumberCreate(0, kCFNumberIntType, &vid);
    CFNumberRef np = CFNumberCreate(0, kCFNumberIntType, &page);
    CFNumberRef nu = CFNumberCreate(0, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR(kIOHIDVendorIDKey),
                           CFSTR(kIOHIDPrimaryUsagePageKey),
                           CFSTR(kIOHIDPrimaryUsageKey) };
    const void *vals[] = { nv, np, nu };
    IOHIDManagerSetDeviceMatching(manager,
        CFDictionaryCreate(0, keys, vals, 3,
                           &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks));
    IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);

    CFSetRef found = IOHIDManagerCopyDevices(manager);
    CFIndex count = found ? CFSetGetCount(found) : 0;
    if (count == 0) {
        fprintf(stderr, "no Keychron raw HID interface found - is the cable in "
                        "and the side switch not on the off position?\n");
        return 1;
    }
    IOHIDDeviceRef devices[8];
    CFSetGetValues(found, (const void **)devices);

    uint8_t packet[REPORT_SIZE] = {0};
    packet[0] = FACTORY_TEST_CMD;
    packet[1] = FACTORY_TEST_CMD_JUMP_TO_BL;
    memcpy(&packet[2], "JumpToBootloader", strlen("JumpToBootloader"));

    /* Keychron's checksum: bytes 1 .. REPORT_SIZE-4, stored little endian in
     * the last two bytes. */
    uint16_t checksum = 0;
    for (int i = 1; i < REPORT_SIZE - 3; i++) checksum += packet[i];
    packet[REPORT_SIZE - 2] = checksum & 0xFF;
    packet[REPORT_SIZE - 1] = (checksum >> 8) & 0xFF;

    IOReturn r = IOHIDDeviceSetReport(devices[0], kIOHIDReportTypeOutput, 0,
                                      packet, sizeof packet);

    /* The keyboard reboots straight away, so a write error here is normal and
     * says nothing about whether the command landed. */
    printf("sent JumpToBootloader (SetReport -> 0x%08x)\n", r);
    printf("check with: dfu-util -l\n");
    return 0;
}
