# Keychron K10 Pro — how battery reporting actually works, and what blocks it

Everything below was measured on the keyboard in question (ANSI, white
backlight, PID `0x02A3`, BT module firmware 1.3.2) or read out of Keychron's
QMK fork at branch `bluetooth_playground`.

## 1. The hardware split

The K10 Pro is two processors:

| Part | Role | Source available? |
|---|---|---|
| STM32L432 | QMK: matrix, backlight, USB HID, VIA | yes, Keychron's fork |
| **CKBT51** | the entire Bluetooth stack, incl. its own HID descriptor | **no** |

QMK does not speak Bluetooth. It hands key reports to the CKBT51 over UART
(`CKBT51_CMD_SEND_KB`, `…_NKRO`, `…_CONSUMER`, `…_SYSTEM`, `…_MOUSE`) and the
module presents itself to the host as the keyboard. `ckbt51.h` notes the module
is Bluetooth Classic only — `BT_MODE_LE` carries the comment
`Note: CKBT51 doesn't support BLE`.

Battery is measured **by the module**, not by QMK: `battery_measure()` issues
`ckbt51_read_state_reg(0x05, 0x02)` and the answer comes back as
`CKBT51_EVT_BATTERY` (`0xB5`), which QMK converts to millivolts in the board's
`battery_calculte_voltage()`.

## 2. Why macOS shows nothing today

### 2a. The over-the-air HID descriptor has no battery field

The descriptor macOS receives over Bluetooth, read back from `IORegistry`
(`IOHIDUserDevice`, `Transport = Bluetooth`, with the keyboard's Bluetooth
address as `SerialNumber`),
is 242 bytes and declares exactly five top-level collections:

| Report ID | Contents |
|---|---|
| `0x01` | boot keyboard: 8 modifier bits, 6 keycodes, 5 LED bits |
| `0x0C` | NKRO: 8 modifier bits + a 152-bit keycode bitmap |
| `0x0A` | Consumer: 3 × 16-bit usages, Usage Min 0x0000 / **Usage Max 0x03FF** |
| `0x04` | System Control: one System Sleep bit + 7 constant bits |
| `0x0B` | Mouse: 5 buttons, 16-bit X/Y, wheel, AC Pan |

Usage pages present: `0x01`, `0x07`, `0x08`, `0x09`, `0x0C`. Notably **absent**:

- `0x06` Generic Device Controls — where `Battery Strength` (`0x20`) lives
- `0x84` Power Device
- `0x85` Battery System

That descriptor lives in the closed CKBT51 firmware and is published through
SDP at pairing time. QMK cannot change a byte of it. So the standard HID
battery mechanism — the one Windows and Linux `upower` use — has nothing to
read.

### 2b. macOS has no generic HID battery path anyway

Even with a correct descriptor, macOS would ignore it:

- `IOHIDEventDriver.cpp` (Apple's open-source HID event driver) has parsers for
  digitizers, game controllers, sensors, biometrics and more, and **no battery
  parser at all**.
- `IOHIDPowerSource.kext` does translate HID usages into battery properties —
  including `CurrentCapacity`, `Voltage`, `IsCharging` — but its matching
  dictionary is `PrimaryUsagePage 0xFF00`, `PrimaryUsage 0x58`, **`VendorID 1452`**.
  Apple's own silicon only.
- `AppleDeviceManagementHIDFilter.plugin` matches `DeviceUsagePage 0xFF00` /
  `DeviceUsage 0x0B` with no vendor restriction, which looked promising — but
  its symbols (`PalmspringCrashlogManager`, `/Library/Logs/hidfw-crashlogs`)
  show it extracts crash logs, not battery.
- The string `BatteryPercent` appears in exactly one place on the system:
  `/usr/sbin/bluetoothd`, alongside `BatteryServiceNotification`,
  `batteryInfoLeft/Right/Case` and `BatteryLevelPrimary/Secondary` — i.e. the
  BLE GATT Battery Service and Apple's own accessory protocol.

That is confirmed on this Mac: the MX Master 3S reports `Battery Level: 100%`
and its `Services` field reads `< BLE >`, while the K10 Pro's reads
`< HID ACL >` — Bluetooth Classic — and carries no battery line.

**Conclusion:** battery *as a Bluetooth property* is doubly blocked — the
module's descriptor cannot carry it, and macOS would not read it if it did.

### 2d. But the power-source registry is writable

The Batteries section of Control Center does not render Bluetooth devices. It
renders **accessory power sources**, the list `pmset -g accps` prints. On this
Mac that list held the mouse (via BLE GATT) and the AirPods and their case (via
Apple's accessory protocol) — `bluetoothd` translates both into power sources,
which is what its log line `Accessory power source create with battery level:
%d` is doing.

That registry is not privileged. `IOPSCreatePowerSource`,
`IOPSSetPowerSourceDetails` and `IOPSReleasePowerSource` are IOKit SPI — absent
from the public headers but exported and callable, and verified here to work
from an unsigned, unentitled, non-root process:

```
IOPSCreatePowerSource     -> 0x00000000 (SUCCESS)
IOPSSetPowerSourceDetails -> 0x00000000 (SUCCESS)

$ pmset -g accps
 -Keychron K10 Pro (id=1877939207)	67%; discharging
```

The schema was taken from the existing entries: `Type = "Accessory Source"`,
`Accessory Category = "Keyboard"`, a stable `Accessory Identifier` (the
keyboard's Bluetooth address), `Current Capacity`, `Max Capacity`,
`Power Source State`, `Is Charging`, `Low Warn Level`, and optionally
`Time to Empty` in minutes.

Two traps, both found the hard way:

- `IOPSPowerSourceID` is an opaque handle, **not** a CoreFoundation object.
  Declaring it as `CFTypeRef` in Swift makes ARC retain it and segfault in
  `swift_unknownObjectRetain`. It has to be held as a raw pointer. C code does
  not notice, which makes this easy to get wrong.
- `Is Charging` and `Is Present` are specified as `CFBoolean` in `IOPSKeys.h`,
  not `CFNumber`. Passing `1`/`0` is accepted silently and the entry appears,
  but the charging state is then never reflected — `pmset -g accps` reads
  `AC attached; not charging` no matter what. With real booleans it reads
  `charging present: true`, matching how a genuine accessory renders.

So the honest picture is: the Bluetooth battery surfaces are closed to this
keyboard, and the Control Center surface is open.

### 2c. Stock firmware exposes no battery over raw HID either

`ENABLE_FACTORY_TEST` is on for the K10 Pro, so the stock firmware does answer
raw HID command `0xAB`. Its command table is backlight test, OS-switch
reporting, jump-to-bootloader, INT-pin test, `GET_TRANSPORT` and
`RADIO_CARRIER`. The one battery-adjacent command, `FACTORY_TEST_CMD_CHARGING_ADC`,
is compiled out — it sits behind `BATTERY_CHARGE_DONE_DETECT_ADC`, which the
K10 Pro never defines. And it reads the charger pin, not the cell.

So there is no way to get a battery number off an unmodified K10 Pro. A
firmware change is mandatory.

## 3. What the firmware already has, unused

- `CKBT51_CMD_UPDATE_BAT_LVL = 0x32` is declared in `ckbt51.c` and **never
  called anywhere in the tree**. It is presumably how a host-visible level was
  meant to reach the module. It is deliberately left alone here: the payload
  format is undocumented, and since the module's HID descriptor has no battery
  field, no value of it can produce host-visible battery.
- `battery.c` defines a weak `battery_calculate_voltage()`, but every caller and
  every board uses `battery_calculte_voltage()` — a typo in the name that has
  been copied across all 26 boards. The correctly-spelled weak fallback is dead
  code; a board that forgot to define the misspelled one fails at link time
  rather than degrading gracefully.
- `battery_get_percentage()` is only ever used to drive the on-keyboard LED
  level animation.
- `voltage` initialises to `FULL_VOLTAGE_VALUE`, so `battery_get_percentage()`
  reports a confident **100%** before any measurement has happened. The feature
  in this repo tracks whether a real sample exists and reports "unknown"
  instead.
- `battery_task()` only samples while `get_transport() == TRANSPORT_BLUETOOTH`
  **and** the link is connected. In pure USB mode nothing is ever measured.

## 4. The two channels this project uses

### Cable: QMK raw HID

The K10 Pro's `config.h` defines `KEEP_USB_CONNECTION_IN_BLUETOOTH_MODE`, and
`transport.c` only calls `usb_start()`/`usb_power_connect()` when that macro is
**absent**. So the USB device stays enumerated permanently, and `raw_hid_send()`
writes straight to the USB endpoint rather than through `host_get_driver()`.

That means the raw HID interface is alive **even while the keyboard is typing
over Bluetooth** — so with the cable in, the agent gets exact voltage and
percentage regardless of which mode the switch is on. This is the high-fidelity
channel.

### Wireless: an unassigned Consumer usage

With no cable there is exactly one path to the Mac: the HID reports the CKBT51
relays. Of the five, the Consumer report is the only one whose payload QMK
controls verbatim — `ckbt51_send_consumer()` copies the 16-bit value straight
into the packet, and the other two array slots are left zero ("QMK doesn't send
multiple consumer reports, just skip 2nd and 3rd").

Consumer-page usages above `0x02A0` are unassigned in the HID Usage Tables, and
the module's descriptor permits up to `0x03FF`. So the level is encoded as

    0x0300 + percent   (discharging)
    0x0380 + percent   (charging)

The host maps these to no action — no keystroke, no media command — while the
raw input report is still delivered to a userspace `IOHIDManager` client. The
usage is released (`0x0000`) 20 ms later, since the field is an array and the
host otherwise considers it held.

**Why it only fires while you type.** Any unsolicited HID input report risks
waking a sleeping display. The beacon is therefore gated on real key activity
within the last 60 s, rate-limited to once a minute, and re-sent at least every
5 minutes. It rides along with typing and never wakes anything on its own.

## 5. Sources

- [Keychron/qmk_firmware, branch `bluetooth_playground`](https://github.com/Keychron/qmk_firmware/tree/bluetooth_playground/keyboards/keychron/k10_pro)
- [Apple IOHIDFamily — `IOHIDEventDriver.cpp`](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventDriver.cpp)
- [QMK Raw HID](https://docs.qmk.fm/features/rawhid)
- [QMK `usb_descriptor.c`](https://github.com/qmk/qmk_firmware/blob/master/tmk_core/protocol/usb_descriptor.c)
- [Magic Keyboard HID descriptor dump](https://gist.github.com/xloc/9f1ecca90ca29a9039c2a2468af70763)
- [HID: apple — report Magic Keyboard 2021 battery over USB](https://lore.kernel.org/all/20220208185009.49100-1-jose.exposito89@gmail.com/T/)
- [Linux patches for Apple Magic battery over Bluetooth (Phoronix)](https://www.phoronix.com/news/Apple-Magic-Bluetooth-Battery)
- [Keychron K firmware & JSON files](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)


## 6. Controlling the keyboard from macOS

Reading battery is one direction; sending the keyboard a command is the other,
and it is much more constrained.

### There was no control channel to begin with

`quantum/via.c` in this fork only services a lighting channel under
`#if defined(RGB_MATRIX_ENABLE)`:

```c
#if defined(RGB_MATRIX_ENABLE)
    if (*channel_id == id_qmk_rgb_matrix_channel) { ... }
#endif
```

The white K10 Pro is `LED_MATRIX_ENABLE`, and this VIA version has no
LED-matrix channel at all — the `via_json` advertises a `qmk_rgb_matrix` menu
the firmware cannot answer. That is why backlight on this board is Fn-key only.
So a firmware command had to be added; `keyboard_control.c` is it.

### Over the cable: raw HID, works

Command `0xAD` carries an action plus a state readback (enabled, brightness,
effect, effect count, lighting kind). Verified on hardware: six actions applied
in sequence, with the firmware's own `actions_applied` counter incrementing
1→6, brightness stepping 100→94→87→94%, and effect 1→2.

### Wirelessly: it works, but only through the LED *elements*

With no cable, the only host-to-keyboard path is the keyboard's **LED output
report**. The CKBT51 hands the whole LED byte to QMK
(`CKBT51_EVT_HID_EVENT` → `led_state` → `bluetooth_keyboard_leds()`), so
whatever a host writes there is readable in firmware.

Two dead ends came first, and both are worth recording.

**Writing a raw output report does nothing.** The obvious approach — put a
command in the report's three constant padding bits and write the byte — is
silently discarded:

```
IOHIDDeviceSetReport(bluetooth keyboard, output, id 1, 0xE0) -> 0x00000000
  ... led_changes stays 0
```

macOS returns success and transmits nothing. An ordinary process may not write
output reports to a keyboard.

**But setting the LED elements individually does work.** `IOHIDDeviceSetValue`
on the report's LED output elements is honoured, and all five reach the
keyboard over Bluetooth. Instrumenting the firmware with a sticky
`led_seen_mask` and a change counter:

```
before:                   led_changes=0   led_seen_mask=0x00
caps lock on/off:         led_changes=2   led_seen_mask=0x02
SetValue on all 5 LEDs:   led_changes=11  led_seen_mask=0x1f
```

So the command has to live in real LED usages rather than padding bits. Of the
five, two are unusable: Caps Lock is driven by the OS, and Num Lock lights a
real key on this board (`NUM_LOCK_INDEX`). The other three light nothing —
Keychron guards every use of them behind `SCROLL_LOCK_INDEX`,
`COMPOSE_LOCK_INDEX` and `KANA_LOCK_INDEX`, none of which the K10 Pro defines:

| LED bit | usage | carries |
|---|---|---|
| `0x04` | Scroll Lock | action bit 0 |
| `0x08` | Compose | action bit 1 |
| `0x10` | Kana | action bit 2 |

Three bits is exactly the seven actions needed. They are adjacent, so
`(leds & 0x1C) >> 2` extracts the field.

**One wrinkle: each element write is its own report.** Setting `0b101` passes
through `0b001` on the way, and the firmware fired that as a command — a
"dim" that toggled the backlight instead. The firmware therefore waits for the
field to stop changing (`KEYBOARD_CONTROL_LED_SETTLE`, 50 ms) before acting,
and the host holds the value for 300 ms before clearing it. Verified for every
action:

```
sent       want       decoded  from
OK toggle  1 (0x04)   1        0x04
OK off     2 (0x08)   2        0x08
OK on      3 (0x0c)   3        0x0c
OK up      4 (0x10)   4        0x10
OK down    5 (0x14)   5        0x14
OK effect  6 (0x18)   6        0x18
```

**So brightness and effects are controllable over Bluetooth.** The cable is
needed only to *read* state back, which the menu uses for labelling.

## 7. Control Center controls

macOS 26 supports third-party Controls — `ControlWidgetToggle` and
`ControlWidgetButton` are in the macOS WidgetKit interface with no
`@available(macOS, unavailable)` marker, and compile for
`arm64-apple-macos26.0`.

They must live in a WidgetKit **app extension**, and a hand-assembled bundle
was never registered by `pluginkit` — ad-hoc signed, then with a real Apple
Development identity, in `~/Applications`, with `lsregister -f -R` and an
explicit `pluginkit -a`, and no rejection logged anywhere. A generated Xcode
project builds one that registers immediately.

The bug worth recording was in the generator, not in Xcode. Setting

```
INFOPLIST_KEY_NSExtensionPointIdentifier = com.apple.widgetkit-extension
```

produces an `Info.plist` with **no `NSExtension` dict at all**. `INFOPLIST_KEY_*`
only covers a fixed list of flat keys and cannot express a nested one, and it
fails silently: the extension builds, embeds, passes
`ValidateEmbeddedBinary`, installs — and is never registered. A real
`Controls-Info.plist` fixes it:

```
io.smartowl.k10pro-battery.controls(1.0)
   Path = ~/Applications/K10ProBattery.app/Contents/PlugIns/K10ProControls.appex
   SDK  = com.apple.widgetkit-extension
```

The controls are **buttons, not a toggle**. A widget extension is sandboxed, so
reading the keyboard's backlight state would need an App Group and its
provisioning, and over Bluetooth the keyboard cannot report state back anyway.
Buttons need no state and behave identically wired and wireless.

The extension does no HID work. It posts a Darwin notification — permitted in
the sandbox, no entitlement — and the agent, which already holds the devices
and the Input Monitoring grant, performs the action. Verified end to end:

```
$ notifyutil -p io.smartowl.k10pro.action.6
  effect 11 -> 12
$ notifyutil -p io.smartowl.k10pro.action.5
  brightness 87% -> 81%
```

## 8. A key-repeat regression, and its cause

Holding an arrow key or Backspace would stop repeating after a while. The cause
was the battery beacon: it called `ckbt51_send_consumer()` **directly**, which
jumps the queue that Keychron's `bluetooth_send_consumer()` maintains:

```c
if (report_buffer_is_empty() && report_buffer_next_inverval()) { ...send... }
else { report_buffer_enqueue(&report_buffer); }
```

That path enforces a minimum interval (`DEFAULT_REPORT_INVERVAL_MS`, 3 ms) and
buffers when a report is already in flight. Bypassing it puts a consumer packet
on the module's UART mid-keystroke, and a keyboard report is lost — after which
the host has no held key to repeat.

Three changes: the beacon now goes through `bluetooth_send_consumer()`; it
tracks how many keys are physically down and stays off the air unless that is
zero (a held key is invisible in the event stream, because the repeat is
generated by the host); and it waits `BATTERY_BEACON_QUIET_TIME` (400 ms) after
the last key event.


## 9. Menus that stay open, and asking for a reading

Two things surfaced once the controls were in real use.

**Every click closed the menu.** Two causes. An `NSMenuItem` action dismisses
the menu by design, so cycling backlight effects meant reopening it each time.
And `render()` rebuilt the whole menu on every state update, which tore down
the menu the user was clicking in — a state update arrives right after each
action, because the action triggers a lighting poll.

The fix for the first is a menu item hosting a custom view: dismissal is then
the view's decision, and `ControlStripView` never asks for it. The drawing and
hit-testing are hand-rolled because a menu runs its own event loop and embedded
`NSButton`s do not track the mouse reliably inside one. The fix for the second
is `NSMenuDelegate`: rebuild in `menuWillOpen`, and while open update only the
two lines whose text changes.

**Refresh did nothing wirelessly.** Both poll paths are raw HID, which is
USB-only, so the button was inert with no cable — and the beacon is sent
entirely on the keyboard's schedule, with nothing able to prompt it.

`KEYBOARD_ACTION_REPORT_BATTERY` fixes that, and it had to take the last slot
the LED channel can reach. Three bits means values 1-7, all of which were
already spoken for, so previous-effect moved to 8 and became cable-only: raw
HID carries a whole byte, the LED channel does not. A forced beacon skips the
rate limit and the wakefulness test - a host that just sent a command is
awake - while keeping the held-key guard, which exists to protect the
keyboard's own report stream rather than to gate on activity.
