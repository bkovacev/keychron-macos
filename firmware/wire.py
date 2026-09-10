#!/usr/bin/env python3
"""Apply the source-level wiring for the battery and keyboard-control features.

Driven by install.sh, which sets REPO and BOARD_C. Every edit is idempotent:
re-running is a no-op, so this can be pointed at a checkout that is already
partly patched.
"""

import os
import re
import sys
import pathlib

repo = pathlib.Path(os.environ["REPO"])
board_c = pathlib.Path(os.environ["BOARD_C"])
bt = repo / "keyboards/keychron/bluetooth"
changed = []


def edit(path, anchor, addition, *, label, present=None):
    """Insert `addition` after the unique `anchor`, unless already present.

    `present` overrides the "already applied?" test. Needed where a later edit
    inserts text *inside* an earlier edit's block: testing for the whole block
    would then fail and the earlier edit would apply a second time.
    """
    text = path.read_text()
    if (present if present is not None else addition.strip()) in text:
        print(f"    skip (already present): {label}")
        return
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"anchor found {n} times in {path.name}, expected once:\n{anchor}")
    path.write_text(text.replace(anchor, anchor + addition))
    changed.append(path)
    print(f"    added: {label}")


def uncomment(path, commented, *, label):
    """Strip the leading // from a single, unique commented-out line."""
    text = path.read_text()
    if commented not in text:
        print(f"    skip (already active): {label}")
        return
    if text.count(commented) != 1:
        sys.exit(f"expected exactly one commented line in {path.name}")
    path.write_text(text.replace(commented, commented.replace("// ", "", 1)))
    changed.append(path)
    print(f"    uncommented: {label}")


def set_raw_hid_top(path, top, *, label):
    """Widen the RAW_HID_CMD case range to `top`, whatever it is now."""
    text = path.read_text()
    target = f"#    define RAW_HID_CMD 0xAA ... {top}"
    if target in text:
        print(f"    skip (already present): {label}")
        return
    text, n = re.subn(r"#    define RAW_HID_CMD 0xAA \.\.\. 0x[0-9A-Fa-f]{2}", target, text)
    if n != 1:
        sys.exit(f"expected exactly one RAW_HID_CMD range in {path.name}")
    path.write_text(text)
    changed.append(path)
    print(f"    changed: {label}")


# 1-2. build: compile the new translation units
edit(bt / "bluetooth.mk",
     "     $(BLUETOOTH_DIR)/battery.c \\\n",
     "     $(BLUETOOTH_DIR)/battery_report.c \\\n",
     label="bluetooth.mk: SRC += battery_report.c")
edit(bt / "bluetooth.mk",
     "     $(BLUETOOTH_DIR)/battery_report.c \\\n",
     "     $(BLUETOOTH_DIR)/keyboard_control.c \\\n",
     label="bluetooth.mk: SRC += keyboard_control.c")

# 3-4. bluetooth stack: expose the connected host index, which bluetooth.c keeps
#      private. Every bluetooth_enter_*_kb() hook is already claimed by some
#      board, so an accessor is the portable way to read it.
edit(bt / "bluetooth.h",
     "bluetooth_state_t bluetooth_get_state(void);\n",
     "uint8_t           bluetooth_get_host_index(void);\n",
     label="bluetooth.h: declare bluetooth_get_host_index()")
edit(bt / "bluetooth.c",
     "bluetooth_state_t bluetooth_get_state(void) {\n    return bt_state;\n};\n",
     "\nuint8_t bluetooth_get_host_index(void) {\n    return host_index;\n}\n",
     label="bluetooth.c: define bluetooth_get_host_index()")

# 5-6. board: include the feature headers
edit(board_c,
     '#    include "battery.h"\n',
     '#    include "battery_report.h"\n',
     label=f"{board_c.name}: #include battery_report.h")
edit(board_c,
     '#    include "battery_report.h"\n',
     '#    include "keyboard_control.h"\n',
     label=f"{board_c.name}: #include keyboard_control.h")

# 7. board: mark every fresh voltage sample
edit(board_c,
     "    battery_set_voltage(voltage);\n",
     "    battery_report_notify_sample();\n",
     label=f"{board_c.name}: battery_report_notify_sample()")

# 8. board: let the beacon piggyback on real typing
edit(board_c,
     "    static uint8_t host_idx = 0;\n",
     "\n#ifdef KC_BLUETOOTH_ENABLE\n"
     "    battery_report_notify_key_activity(record->event.pressed);\n"
     "#endif\n",
     label=f"{board_c.name}: battery_report_notify_key_activity()",
     present="battery_report_notify_key_activity(")

# 9-10. board: dispatch the two raw HID commands
edit(board_c,
     "#ifdef ENABLE_FACTORY_TEST\n"
     "        case 0xAB:\n"
     "            factory_test_rx(data, length);\n"
     "            break;\n"
     "#endif\n",
     "#ifdef KC_BLUETOOTH_ENABLE\n"
     "        case BATTERY_REPORT_RAW_HID_CMD:\n"
     "            return battery_report_raw_hid_rx(data, length);\n"
     "#endif\n",
     label=f"{board_c.name}: via_command_kb case 0xAC (battery)",
     present="case BATTERY_REPORT_RAW_HID_CMD:")
edit(board_c,
     "        case BATTERY_REPORT_RAW_HID_CMD:\n"
     "            return battery_report_raw_hid_rx(data, length);\n",
     "        case KEYBOARD_CONTROL_RAW_HID_CMD:\n"
     "            return keyboard_control_raw_hid_rx(data, length);\n",
     label=f"{board_c.name}: via_command_kb case 0xAD (control)",
     present="case KEYBOARD_CONTROL_RAW_HID_CMD:")

# 11. board config: widen the raw HID command range for non-VIA builds
set_raw_hid_top(board_c.parent / "config.h", "0xAD",
                label="config.h: RAW_HID_CMD range -> 0xAD")

# 12. Restore software entry into DFU. Keychron's shipped firmware has this
#     enabled - the string "JumpToBootloader" is present in a dump of a stock
#     keyboard's flash - but the public source comments it out, so building from
#     source silently removes the ability of Keychron Launcher or dfu-util to
#     reboot the keyboard into DFU over USB, leaving only the physical
#     hold-Esc-while-plugging-in method.
uncomment(bt / "factory_test.c",
          '                // if (memcmp(&data[2], "JumpToBootloader", strlen("JumpToBootloader")) == 0) bootloader_jump();',
          label="factory_test.c: re-enable software DFU entry")

print(f"    {len(set(changed))} file(s) modified")
