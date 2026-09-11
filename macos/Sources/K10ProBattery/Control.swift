import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Actions the keyboard understands. Mirrors `keyboard_control_action` in
/// `firmware/src/keyboard_control.h`; values must stay in 1...7 because they
/// have to fit the three spare bits of the LED output report.
enum ControlAction: UInt8, CaseIterable {
    case backlightToggle = 1
    case backlightOff    = 2
    case backlightOn     = 3
    case brightnessUp    = 4
    case brightnessDown  = 5
    case effectNext      = 6
    case reportBattery   = 7
    case effectPrev      = 8

    var label: String {
        switch self {
        case .backlightToggle: return "Toggle Backlight"
        case .backlightOff:    return "Backlight Off"
        case .backlightOn:     return "Backlight On"
        case .brightnessUp:    return "Brighter"
        case .brightnessDown:  return "Dimmer"
        case .effectNext:      return "Next Effect"
        case .effectPrev:      return "Previous Effect"
        case .reportBattery:   return "Report Battery"
        }
    }

    /// Only 1...7 fit the three LED bits the wireless channel uses.
    var worksWirelessly: Bool { rawValue <= 7 }
}

/// Which channel carried a command.
enum ControlChannel: String {
    /// Raw HID over the cable. Exact, and the keyboard reports its state back.
    case rawHID = "cable"
    /// The LED output report's spare bits. The only channel over Bluetooth,
    /// and it is write-only: no state comes back.
    case ledReport = "wireless"
}

/// Lighting state, only obtainable over the cable.
struct LightingState {
    enum Kind: UInt8 { case none = 0, ledMatrix = 1, rgbMatrix = 2 }

    var enabled: Bool
    var brightness: Int
    var effect: Int
    var effectCount: Int
    var kind: Kind

    /// The raw LED report byte the firmware last saw. Used to confirm the
    /// spare bits survive the trip through the wireless module.
    var lastLEDByte: UInt8
    /// Actions the firmware has applied since boot.
    var actionCount: Int
    /// Every LED bit the firmware has ever observed, OR-ed together.
    var ledSeenMask: UInt8
    /// How many times the LED byte changed. Zero means no host LED report
    /// reaches the firmware at all.
    var ledChanges: Int
    /// The action the firmware last decoded, and the LED byte it came from.
    var lastAction: UInt8
    var lastLEDs: UInt8
}

extension Wire {
    // Raw HID control command, one past the battery command.
    static let controlCmd: UInt8 = 0xAD
    static let controlSubGet: UInt8 = 0x01
    static let controlSubAction: UInt8 = 0x02
    static let controlSubSet: UInt8 = 0x03
    static let controlSubState: UInt8 = 0x81

    static let settingBrightness: UInt8 = 0x01
    static let settingEffect: UInt8 = 0x02

    /// Where the action sits inside the LED output report byte.
    static let ledActionShift: UInt8 = 5

    enum ControlOffset {
        static let cmd = 0, sub = 1, version = 2, enabled = 3, brightness = 4
        static let effect = 5, effectMax = 6, lighting = 7, ledByte = 8, actionSeq = 9
        static let ledSeen = 10, ledChanges = 11, lastAction = 12, lastLEDs = 13
    }
}

/// Current lock-key LED bits, so writing the report does not disturb the
/// Caps Lock indicator. Bit order comes from the descriptor's LED usages:
/// Num Lock, Caps Lock, Scroll Lock.
func currentLockLEDBits() -> UInt8 {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    return flags.contains(.maskAlphaShift) ? 0x02 : 0x00
}
