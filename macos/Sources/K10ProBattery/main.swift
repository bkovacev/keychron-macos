import AppKit
import Foundation

/// `--once` prints one reading as JSON and exits; useful for scripts, status
/// bars and for checking the firmware is answering at all.
private func runOnce(timeout: TimeInterval) -> Int32 {
    let monitor = KeyboardMonitor()
    var result: BatteryState?

    monitor.onUpdate = { state in
        if state.latest != nil { result = state; CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
    monitor.start()
    monitor.poll()

    // Re-poll shortly after start: the first query can land before the raw HID
    // interface has finished opening.
    let retry = Timer(timeInterval: 0.4, repeats: true) { _ in monitor.poll() }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), retry, .defaultMode)

    CFRunLoopRunInMode(.defaultMode, timeout, false)
    retry.invalidate()

    let state = result ?? monitor.state
    var payload: [String: Any] = [
        "cable_connected": state.hasRawHIDInterface,
        "bluetooth_paired": state.hasBluetoothInterface,
        "input_monitoring": String(describing: state.inputMonitoring),
    ]

    if let reading = state.latest {
        payload["percent"] = reading.percent
        payload["charging"] = reading.charging
        payload["source"] = reading.source.rawValue
        payload["millivolts"] = reading.millivolts
        payload["transport"] = reading.transport?.label
        payload["link_state"] = reading.linkState?.label
        payload["bluetooth_host"] = reading.bluetoothHost
        payload["sample_age_seconds"] = reading.sampleAgeSeconds
    }

    let data = try! JSONSerialization.data(withJSONObject: payload,
                                           options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))

    return state.latest == nil ? 1 : 0
}

/// Register a fixed level and hold it, so the Control Center entry can be seen
/// before the firmware is flashed.
private func runDemo(percent: Int, charging: Bool) -> Int32 {
    let publisher = PowerSourcePublisher()
    let monitor = KeyboardMonitor()
    monitor.start()
    CFRunLoopRunInMode(.defaultMode, 1.0, false)   // let device matching settle

    let ok = publisher.publish(name: "Keychron K10 Pro",
                               identifier: monitor.bluetoothAddress ?? "keychron-k10-pro",
                               percent: percent,
                               charging: charging)
    guard ok else {
        print("failed to publish: \(publisher.lastError ?? "unknown error")")
        return 1
    }

    print("""
    Published "Keychron K10 Pro" at \(percent)%\(charging ? " (charging)" : "").
    Open Control Center and look under Battery. Verify from the terminal with:

        pmset -g accps

    Ctrl-C to remove it.
    """)

    // stdout is block-buffered when piped, and this function never returns.
    fflush(stdout)

    signal(SIGINT) { _ in exit(0) }
    CFRunLoopRun()
    return 0
}

/// Send one action and print the resulting lighting state. Also the quickest
/// way to check both control channels by hand.
private func runControl(_ action: ControlAction?, timeout: TimeInterval,
                        forceLEDReport: Bool = false) -> Int32 {
    let monitor = KeyboardMonitor()
    var lighting: LightingState?

    monitor.onUpdate = { state in
        if let l = state.lighting { lighting = l; CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
    monitor.start()
    CFRunLoopRunInMode(.defaultMode, 0.6, false)   // let device matching settle

    var channel: ControlChannel?
    if let action {
        channel = monitor.send(action, forceLEDReport: forceLEDReport)
        guard channel != nil else {
            print("no channel available - keyboard not reachable")
            return 1
        }
    }

    // Read state back. Cable only; wireless has nothing to answer with.
    monitor.pollLighting()
    let retry = Timer(timeInterval: 0.3, repeats: true) { _ in monitor.pollLighting() }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), retry, .defaultMode)
    CFRunLoopRunInMode(.defaultMode, timeout, false)
    retry.invalidate()

    var payload: [String: Any] = [
        "channel": channel?.rawValue ?? monitor.availableChannel?.rawValue ?? "none",
    ]
    if let action { payload["action"] = action.label }
    if let t = monitor.ledTargetDescription { payload["led_target"] = t }
    if let e = monitor.lastLEDWriteError { payload["led_write_error"] = e }
    if let l = lighting {
        payload["backlight"] = l.enabled ? "on" : "off"
        payload["brightness"] = l.brightness
        payload["brightness_percent"] = Int((Double(l.brightness) / 255 * 100).rounded())
        payload["effect"] = l.effect
        payload["effect_count"] = l.effectCount
        payload["lighting"] = String(describing: l.kind)
        payload["last_led_byte"] = String(format: "0x%02x", l.lastLEDByte)
        payload["actions_applied"] = l.actionCount
        payload["led_seen_mask"] = String(format: "0x%02x", l.ledSeenMask)
        payload["led_changes"] = l.ledChanges
        payload["decoded_action"] = l.lastAction
        payload["decoded_from_leds"] = String(format: "0x%02x", l.lastLEDs)
    } else {
        payload["state"] = "unavailable (wireless is write-only)"
    }

    let data = try! JSONSerialization.data(withJSONObject: payload,
                                           options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    return 0
}

private let controlNames: [String: ControlAction] = [
    "toggle": .backlightToggle, "off": .backlightOff, "on": .backlightOn,
    "up": .brightnessUp, "down": .brightnessDown,
    "effect": .effectNext, "effect-prev": .effectPrev,
]

let argumentList = Array(CommandLine.arguments.dropFirst())
let arguments = Set(argumentList)

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    k10pro-battery — Keychron K10 Pro battery for macOS

      k10pro-battery            run as a menu bar item
      k10pro-battery --once     print one reading as JSON and exit
      k10pro-battery --demo N   register a fake N% level in Control Center and
                                hold it, to check the integration before
                                flashing firmware
      k10pro-battery --lighting        print backlight state (needs the cable)
      k10pro-battery --backlight ACT   ACT is one of:
                                       toggle on off up down effect effect-prev
                                       Needs the cable: macOS discards output
                                       reports written to a wireless keyboard.
      k10pro-battery --help            this message

    Requires the battery-reporting firmware from this repository. Reading the
    Bluetooth beacon additionally needs Input Monitoring permission.
    """)
    exit(0)
}

if arguments.contains("--once") {
    exit(runOnce(timeout: 3.0))
}

if arguments.contains("--lighting") {
    exit(runControl(nil, timeout: 2.0))
}

if let index = argumentList.firstIndex(of: "--backlight") {
    let name = argumentList.count > index + 1 ? argumentList[index + 1] : ""
    guard let action = controlNames[name] else {
        print("unknown action \(name.isEmpty ? "(missing)" : name); expected one of: "
              + controlNames.keys.sorted().joined(separator: " "))
        exit(2)
    }
    // --via led forces the LED-report channel even when the cable is present,
    // which is how the two channels get tested independently.
    let forceLED = argumentList.contains("led")
    exit(runControl(action, timeout: 2.0, forceLEDReport: forceLED))
}

if let index = argumentList.firstIndex(of: "--demo") {
    let percent = Int(argumentList.count > index + 1 ? argumentList[index + 1] : "") ?? 42
    exit(runDemo(percent: percent, charging: arguments.contains("--charging")))
}

guard SingleInstance.acquire() else {
    // A second copy would publish a second accessory power source, so the
    // keyboard would appear twice in Control Center.
    FileHandle.standardError.write(Data("K10ProBattery is already running\n".utf8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

let controller = MenuBarController()

/// Held so the controller and its callbacks stay alive for the process lifetime.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: MenuBarController
    init(controller: MenuBarController) { self.controller = controller }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

let delegate = AppDelegate(controller: controller)
app.delegate = delegate
app.run()
