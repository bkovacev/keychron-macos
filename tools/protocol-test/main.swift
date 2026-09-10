// Feeds the C harness output through the real Swift decoders and asserts the
// two sides of the protocol agree.
import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok    \(what)")
    } else {
        print("  FAIL  \(what)")
        failures += 1
    }
}

func bytes(fromHex hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16)!
    }
}

// Parse `CASE <name>` / `RAWHID <hex>` / `BEACON <hex>` from stdin.
var cases: [(name: String, kind: String, payload: String)] = []
var currentCase = "?"
while let line = readLine() {
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first {
    case "CASE":   currentCase = parts[1]
    case "RAWHID": cases.append((currentCase, "RAWHID", parts[1]))
    case "BEACON":  cases.append((currentCase, "BEACON", parts[1]))
    case "UNPACED": cases.append((currentCase, "UNPACED", parts[1]))
    default:       break
    }
}

func rawHIDPacket(_ name: String) -> [UInt8]? {
    cases.first { $0.name == name && $0.kind == "RAWHID" }
         .map { bytes(fromHex: $0.payload) }
}

func rawHID(_ name: String) -> Reading? {
    rawHIDPacket(name).flatMap(KeyboardMonitor.decodeRawHID)
}

func beacons(_ name: String) -> [Int] {
    cases.filter { $0.name == name && $0.kind == "BEACON" }
         .map { Int($0.payload, radix: 16)! }
}

/// Beacons that actually carry a level. A bare release (0x0000) conveys nothing
/// and is not a broadcast.
func levelBeacons(_ name: String) -> [Int] {
    beacons(name).filter { $0 != 0 }
}

print("raw HID, no sample yet")
check(rawHIDPacket("no-sample") != nil && rawHID("no-sample") == nil,
      "firmware answers but the decoder rejects an unknown percentage")

print("raw HID, discharging over bluetooth")
if let reading = rawHID("discharging") {
    check(reading.percent == 64, "percent 64 (got \(reading.percent))")
    check(reading.millivolts == 3982, "3982 mV (got \(reading.millivolts ?? -1))")
    check(reading.charging == false, "not charging")
    check(reading.source == .usbRawHID, "source is the cable")
    check(reading.transport == .bluetooth, "transport bluetooth (got \(reading.transport?.label ?? "nil"))")
    check(reading.linkState == .connected, "link connected (got \(reading.linkState?.label ?? "nil"))")
    check(reading.sampleAgeSeconds == 7, "sample age 7s (got \(reading.sampleAgeSeconds ?? -1))")
} else {
    check(false, "discharging packet decoded"); failures += 1
}

print("raw HID, charging on host 2")
if let reading = rawHID("charging") {
    check(reading.percent == 100, "percent 100 (got \(reading.percent))")
    check(reading.charging, "charging flag set")
    check(reading.millivolts == 4142, "4142 mV (got \(reading.millivolts ?? -1))")
    check(reading.bluetoothHost == 2, "bluetooth host 2 (got \(reading.bluetoothHost ?? -1))")
} else {
    check(false, "charging packet decoded"); failures += 1
}

print("bluetooth beacon")
let charging = levelBeacons("beacon-charging")
check(charging == [0x03E4], "charging 100% encodes as 0x03E4 (got \(charging.map { String($0, radix: 16) }))")
if let usage = charging.first,
   let reading = KeyboardMonitor.decodeBeacon(reportID: 0x0A,
                                              bytes: [UInt8(usage & 0xFF), UInt8(usage >> 8)]) {
    check(reading.percent == 100 && reading.charging, "decodes back to 100% charging")
} else {
    check(false, "charging beacon decoded"); failures += 1
}

check(beacons("beacon-release") == [0x0000], "usage is released afterwards")

let discharging = levelBeacons("beacon-discharging")
check(discharging == [0x0325], "discharging 37% encodes as 0x0325 (got \(discharging.map { String($0, radix: 16) }))")
if let usage = discharging.first,
   let reading = KeyboardMonitor.decodeBeacon(reportID: 0x0A,
                                              bytes: [UInt8(usage & 0xFF), UInt8(usage >> 8)]) {
    check(reading.percent == 37 && !reading.charging, "decodes back to 37% discharging")
} else {
    check(false, "discharging beacon decoded"); failures += 1
}

check(cases.allSatisfy { $0.kind != "UNPACED" },
      "the beacon never bypasses Keychron's paced send path")

print("beacon suppression")
check(levelBeacons("beacon-suppressed-when-idle").isEmpty,
      "no level broadcast when the host has been idle (would risk waking the display)")
check(levelBeacons("beacon-suppressed-when-usb-transport").isEmpty,
      "no level broadcast when the keyboard is not on the bluetooth transport")
check(levelBeacons("beacon-suppressed-while-key-held").isEmpty,
      "no level broadcast while a key is held (this broke key repeat)")
check(levelBeacons("beacon-resumes-after-release") == [0x0323],
      "beacon resumes once the key is released (35%)")

print("report-ID layout tolerance")
check(KeyboardMonitor.decodeBeacon(reportID: 0x0A, bytes: [0x25, 0x03])?.percent == 37,
      "report ID stripped by macOS")
check(KeyboardMonitor.decodeBeacon(reportID: 0x00, bytes: [0x0A, 0x25, 0x03])?.percent == 37,
      "report ID kept in the buffer")
check(KeyboardMonitor.decodeBeacon(reportID: 0x0A, bytes: [0xE9, 0x00]) == nil,
      "a real consumer usage (Play/Pause) is not mistaken for a beacon")
check(KeyboardMonitor.decodeBeacon(reportID: 0x01, bytes: [0x00, 0x00, 0x04]) == nil,
      "a keyboard report is ignored")

print("")
if failures == 0 {
    print("all protocol checks passed")
    exit(0)
} else {
    print("\(failures) check(s) failed")
    exit(1)
}
