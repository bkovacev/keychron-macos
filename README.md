# Keychron K10 Pro battery on macOS

Your K10 Pro never tells macOS how much battery it has left. This makes it.

The short version of why it doesn't: the Bluetooth side of the keyboard is a
separate, closed chip (CKBT51) whose HID descriptor — which I read back off the
live connection — contains no battery field at all, and macOS has no generic
HID-battery path even if it did. Both halves of the normal mechanism are
missing. [`docs/RESEARCH.md`](docs/RESEARCH.md) has the full evidence.

So this project adds the missing plumbing on both ends:

- **firmware** — a small QMK feature that publishes the battery level over two
  channels the keyboard actually has
- **macos** — an agent that reads them, shows the level in the menu bar,
  registers the keyboard as a system accessory power source so it appears in
  Control Center alongside your other devices, and controls the backlight —
  including over Bluetooth

```
┌──────────────────────── keyboard ─────────────────────────┐
│  STM32L432 (QMK)                       CKBT51 (closed)    │
│                                                           │
│  battery_report.c    ── raw HID 0xAC ──┐  USB cable        │
│    battery level     ── consumer usage ┼─▶ BT report 0x0A  │
│                         0x0300+pct     │                   │
│  keyboard_control.c  ◀─ raw HID 0xAD ──┤  USB cable        │
│    backlight/effects ◀─ LED usages 3/4/5 ◀ BT LED report   │
└────────────────────────────────────────┼───────────────────┘
                                         ▼
                            K10ProBattery.app
                              ├── menu bar item + controls
                              ├── IOPSCreatePowerSource
                              │     └── Control Center · Batteries
                              └── Darwin notifications
                                    └── K10ProControls.appex
                                          └── Control Center · Controls
```

| | cable in | wireless |
|---|---|---|
| **channel** | raw HID query/response | consumer-usage beacon |
| **fidelity** | percentage **and** millivolts | percentage only |
| **cadence** | polled every 60 s | piggybacks on typing, ≤1×/min |
| **needs Input Monitoring** | no | yes |

The wireless beacon rides along with real key activity on purpose — an
unsolicited HID report would risk waking your display.

## Quick start

### 1. Build and flash the firmware

Already built and waiting for you:

```
firmware/build/k10_pro_ansi_white_via_BATTERY.bin          49,948 bytes  ← flash this
firmware/build/k10_pro_ansi_white_via_STOCK_ROLLBACK.bin   49,776 bytes  ← if you change your mind
```

To rebuild from scratch:

```sh
cd firmware
./install.sh          # clone Keychron's fork, patch it, cross-compile
```

`install.sh` needs `arm-none-eabi-gcc`; everything else it bootstraps itself
(a private venv with QMK's Python deps and a `qmk` CLI shim — see
[Build notes](#build-notes) for why). Re-running is safe: every edit is skipped
if already applied.

The default target is `keychron/k10_pro/ansi/white:via` — PID `0x02A3`, which is
what your keyboard reports. Other variants:

| PID | target |
|---|---|
| `0x02A0` | `keychron/k10_pro/ansi/rgb:via` |
| `0x02A1` | `keychron/k10_pro/iso/rgb:via` |
| `0x02A2` | `keychron/k10_pro/jis/rgb:via` |
| `0x02A3` | `keychron/k10_pro/ansi/white:via` |
| `0x02A4` | `keychron/k10_pro/iso/white:via` |
| `0x02A5` | `keychron/k10_pro/jis/white:via` |

Pass `--target` to pick another, `--repo` to patch a checkout you already have,
or `--no-build` to patch only.

#### Flashing

The feature only lives in the **STM32** firmware. Nothing here touches the
CKBT51 Bluetooth module, so its firmware and your pairings are untouched.

1. Slide the side switch to **Cable** and plug the keyboard in.
2. Enter DFU: hold **Esc** while connecting the cable, or press the reset hole
   on the underside.
3. Flash with [Keychron Launcher](https://launcher.keychron.com) (pick the
   `.bin` above), or:

```sh
dfu-util -a 0 -s 0x08000000:leave \
  -D firmware/build/k10_pro_ansi_white_via_BATTERY.bin
```

Afterwards put the switch back to **Bluetooth** — that is the mode where the
module samples the cell, so it is where readings come from.

### 2. Run the agent

```sh
cd macos
make install      # builds and installs ~/Applications/K10ProBattery.app
make login        # and start it at login
open ~/Applications/K10ProBattery.app
```

The agent asks for **Input Monitoring** on first launch — grant it. macOS only
hands a keyboard's input reports to a process that has it, and the same grant
is needed to open the keyboard for backlight control, so without it the
wireless half of everything fails silently.

`make xcode` signs with your Apple Development certificate when one exists,
which matters more than it sounds: an ad-hoc signature gets a fresh code hash
on every build, macOS cannot match the rebuilt app to the grant, and Input
Monitoring is silently dropped each time you rebuild. Set `K10PRO_TEAM_ID=` to
force ad-hoc if you would rather not sign. Without it the cable channel still works, but the wireless
beacon never arrives — macOS won't hand a keyboard's input reports to an
unprivileged process. The menu offers a shortcut to the right pane when it
detects this.

### 3. See it in Control Center

Once a reading arrives, the keyboard shows up in Control Center's Batteries
section next to your mouse and AirPods. To check that half of the integration
*before* flashing anything:

```sh
cd macos && ./.build/release/K10ProBattery --demo 67
```

That registers a fake 67% and holds it until you press Ctrl-C. Confirm with
`pmset -g accps`, which is precisely the list Control Center renders.

Check the keyboard itself from the terminal any time:

```sh
cd macos && make once
```

```json
{
  "bluetooth_paired" : true,
  "cable_connected" : true,
  "charging" : false,
  "input_monitoring_denied" : false,
  "link_state" : "connected",
  "millivolts" : 3982,
  "percent" : 64,
  "source" : "usb",
  "transport" : "Bluetooth"
}
```

## Verifying without a keyboard

`tools/protocol-test` compiles the **real** firmware source on the host, drives
it through known battery states, and decodes its output with the **real** Swift
decoders — so the two ends of the wire protocol are checked against each other
rather than against a hand-written copy of the layout.

```sh
cd tools/protocol-test && ./run.sh         # uses firmware/qmk for the headers
```

```
raw HID, discharging over bluetooth
  ok    percent 64 (got 64)
  ok    3982 mV (got 3982)
  ...
beacon suppression
  ok    no level broadcast when the host has been idle
  ok    no level broadcast when the keyboard is not on the bluetooth transport

all protocol checks passed
```

## Build notes

Two things about Keychron's fork are worth knowing if you build it yourself,
both handled automatically by `install.sh`:

- **It ships no `bin/qmk`.** The Makefile shells out to a `qmk` CLI that this
  fork does not contain. `install.sh` writes a small shim that puts
  `lib/python` on `sys.path`, sets `ORIG_CWD` and chdirs to the repo root —
  which is what upstream's wrapper does.
- **It does not work with `milc` 2.x.** Its CLI uses `cli._subcommand`, which
  milc 2 removed; the failure surfaces as an opaque `make: *** Error 1` with no
  compiler output, because the build wraps everything in `SILENT=true`. The
  bootstrap pins `milc<2` (verified on 1.9.1).

### Installing the toolchain without sudo

`brew install --cask gcc-arm-embedded` runs a `.pkg` and needs your password.
If you would rather not, Homebrew has already downloaded the payload and it can
be unpacked as your own user:

```sh
brew fetch --cask gcc-arm-embedded
PKG=$(find "$(brew --cache)" -name '*arm-none-eabi*.pkg' | head -1)
pkgutil --expand "$PKG" /tmp/armpkg
mkdir -p ~/.local/opt/arm-gnu-toolchain
cd ~/.local/opt/arm-gnu-toolchain && gunzip -dc /tmp/armpkg/Payload | cpio -i
```

`install.sh` looks in `~/.local/opt/arm-gnu-toolchain/bin` automatically.

### Result

The build is reproducible: two independent clean runs produced byte-identical
output.

## What the firmware change touches

Two new translation units plus a handful of lines across five existing files,
applied by `wire.py` as twelve independent idempotent edits:

```
 keyboards/keychron/bluetooth/bluetooth.mk    |  2 +   compile both units
 keyboards/keychron/bluetooth/bluetooth.h     |  1 +   declare the host-index accessor
 keyboards/keychron/bluetooth/bluetooth.c     |  4 +   define it (host_index is static)
 keyboards/keychron/bluetooth/factory_test.c  |  2 +-  re-enable software DFU entry
 keyboards/keychron/k10_pro/config.h          |  2 +-  raw HID range 0xAB -> 0xAD
 keyboards/keychron/k10_pro/k10_pro.c         | 14 ++  hooks and command dispatch
```

Costs about 750 bytes of flash over Keychron's shipped firmware.

It claims exactly one weak hook, `bluetooth_post_task()`, which no board
defines — deliberately not the `bluetooth_enter_*_kb()` connection hooks, since
boards do claim those (the K10 Pro defines
`bluetooth_enter_disconnected_kb`). Link state is tracked by polling instead.
No new timers or threads. Keychron's sampling logic, LED indicators and
low-battery shutdown are untouched.

The wire protocol is documented in
[`firmware/src/battery_report.h`](firmware/src/battery_report.h).

## Backlight control

Toggle the backlight, step brightness and cycle effects — from the menu bar,
from Control Center, or from the command line. **This works over Bluetooth**,
not just on the cable.

```sh
cd macos
./.build/release/K10ProBattery --backlight toggle   # or on off up down effect
./.build/release/K10ProBattery --lighting           # read state (cable only)
```

There was no control channel in the firmware to begin with — this VIA version
only services `qmk_rgb_matrix` and your white board is `LED_MATRIX` — so
`keyboard_control.c` adds one, over two transports:

| | cable | wireless |
|---|---|---|
| **channel** | raw HID command `0xAD` | LED output *elements* |
| **actions** | all of them | all but previous-effect |
| **reads state back** | yes | no |

The wireless channel is the interesting one. macOS refuses to let an ordinary
process write a raw output report to a keyboard — `IOHIDDeviceSetReport`
returns success and transmits nothing — but it *does* honour
`IOHIDDeviceSetValue` on the report's individual LED elements. So the command
rides in three LED usages that light nothing on this board (Scroll Lock,
Compose, Kana), leaving Caps Lock and Num Lock alone. Each element write is
its own report, so the firmware waits for the field to settle before acting.
`docs/RESEARCH.md` §6 has the measurements.

## Polling, and what "refresh" means

Over the cable the agent queries the keyboard directly, every 60 seconds and
whenever the menu opens.

Wirelessly there is no query: the keyboard pushes its level on its own
schedule — at most once a minute, only within 60 s of typing, only while no key
is held, and only when the level changed or five minutes have passed. That
keeps it off the air while you type and stops it waking a sleeping display.

The consequence is that a plain "refresh" has nothing to send. So the control
channel carries a `REPORT_BATTERY` action: the menu item becomes **Ask Keyboard
to Report**, which asks for a level rather than pretending to fetch one. A
forced beacon skips the rate limit and the "has the host been typing" test —
the host just spoke, so it is demonstrably awake — but still waits for no key
to be held.

## Control Center

`make xcode` builds the agent through a generated Xcode project that also
produces a WidgetKit extension, giving you four Control Center buttons:
Backlight, Brighter, Dimmer, Effect.

```sh
cd macos
make xcode      # generate project, build, install to ~/Applications
make login      # start at login
```

Control Center is the two-toggle-switches icon in the menu bar, to the left of
the clock. Open it, scroll to the bottom, click **Edit Controls**, and the four
K10 Pro buttons are in the gallery that appears — drag them where you want.
They also work as menu bar items and can be bound to a Touch Bar or hotkey via
Shortcuts, since each one is an App Intent.

Xcode is required rather than a hand-built bundle — `pluginkit` would not
register one, and the reason turned out to be that Xcode's
`INFOPLIST_KEY_NSExtensionPointIdentifier` silently produces an `Info.plist`
with no `NSExtension` dict at all, because that setting cannot express nested
keys. See `docs/RESEARCH.md` §7.

The extension does no HID work: it posts a Darwin notification and the agent
performs the action. That keeps the sandboxed extension free of permissions and
means the controls behave the same wired or wireless.

## Known limits

- **In pure USB mode the level is unknown.** Keychron's `battery_task()` only
  samples while the Bluetooth link is up, and the sampling is done by the
  CKBT51 module, not by QMK. With the mode switch on *cable* the module is idle
  and there is nothing to read. Put the switch on Bluetooth and plug the cable
  in and you get both exact readings and charging status. This is a deliberate
  choice not to poke a module Keychron leaves asleep.
- **It will not appear as a *Bluetooth* battery.** The row under System
  Settings → Bluetooth, and the level in the Bluetooth menu, come from
  `bluetoothd` reading a BLE GATT Battery Service or Apple's own accessory
  protocol. The K10 Pro's Bluetooth Classic HID link offers neither, and that
  cannot be changed from the QMK side.

  It *does* appear in Control Center's Batteries section and in System
  Settings' battery list, because the agent registers the keyboard as an
  accessory power source directly. Different surface, different mechanism.
- **Reported percentage is a voltage curve, not a gas gauge.** Keychron
  interpolates 3300–3500–4100 mV, with a fudge factor added for backlight draw.
  Expect a few points of jitter as the backlight changes.
- **The wireless channel has seven slots.** Three LED bits, so values 1-7.
  Previous-effect lives above that and is cable-only; everything else fits.
- **Reading lighting state needs the cable.** Commands go both ways, but the
  keyboard can only report brightness/effect back over raw HID, so the menu
  shows a plain "Toggle" when wireless instead of "Turn On"/"Turn Off".
- **The wireless channel borrows three LED usages.** Safe on the K10 Pro
  because it defines no indicator index for Scroll Lock, Compose or Kana — a
  board that does would light them. `keyboard_control.h` documents the mapping.
- **The beacon is a squatted usage.** It relies on Consumer usages above
  `0x02A0` being unassigned. That is true today and is very unlikely to change,
  but it is a convention, not a guarantee.

## Licence

GPL-2.0-or-later, the whole repository. The firmware sources are compiled into
QMK and are a derivative work of it; the macOS side is licensed the same way
for simplicity rather than necessity.

## Layout

```
firmware/
  install.sh                  clone + patch + bootstrap + build, idempotent
  src/battery_report.{c,h}    battery reporting and its wire protocol
  src/keyboard_control.{c,h}  backlight control, both transports
  wire.py                     the source-level wiring, idempotent
  build/*.bin                 flashable firmware + stock rollback
macos/
  Makefile                    build / app bundle / Xcode / LaunchAgent
  ControlCenter/
    generate-project.py       writes the Xcode project
    Controls-Info.plist       the appex Info.plist that makes it register
    Sources/Controls.swift    the four Control Center buttons
  Sources/K10ProBattery/
    KeyboardMonitor.swift     IOHIDManager, both decoders
    BatteryStore.swift        history + drain estimate
    MenuBarController.swift   the menu bar item
    Control.swift             action vocabulary shared with the firmware
    Permission.swift          Input Monitoring status and request
    PowerSource.swift         the Control Center battery entry
    RemoteActions.swift       Darwin-notification bridge for the extension
    SingleInstance.swift      one agent at a time
    Notifier.swift            low-battery alerts
    BatteryState.swift        model
    main.swift                menu bar / --once
tools/
  enter-dfu/                  reboot the keyboard into DFU over USB
  protocol-test/
    run.sh                    cross-language protocol test
    harness.c                 drives the real firmware source on the host
    main.swift                asserts the Swift decoders agree
docs/RESEARCH.md              why it doesn't work out of the box
```
