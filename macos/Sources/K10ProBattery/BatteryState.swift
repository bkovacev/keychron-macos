import Foundation

/// Where a reading came from. Each channel has different fidelity, so the UI
/// shows which one produced the number on screen.
enum ReadingSource: String, Codable {
    /// Raw HID over the USB cable: exact percentage and millivolts.
    case usbRawHID = "usb"
    /// Consumer-usage beacon over Bluetooth: percentage only, arrives while typing.
    case bluetoothBeacon = "bluetooth"
}

/// Transport the keyboard itself reports, mirroring QMK's `transport_t`.
enum KeyboardTransport: UInt8, Codable {
    case none = 0
    case usb = 1
    case bluetooth = 2

    var label: String {
        switch self {
        case .none: return "none"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        }
    }
}

/// Mirrors `bluetooth_state_t` in Keychron's firmware.
enum BluetoothLinkState: UInt8, Codable {
    case reset = 0, initialized, disconnected, connected, pairing, reconnecting, suspend

    var label: String {
        switch self {
        case .reset: return "reset"
        case .initialized: return "initialised"
        case .disconnected: return "disconnected"
        case .connected: return "connected"
        case .pairing: return "pairing"
        case .reconnecting: return "reconnecting"
        case .suspend: return "suspended"
        }
    }
}

/// One battery reading.
struct Reading: Codable {
    var date: Date
    var percent: Int
    var charging: Bool
    var source: ReadingSource

    /// Millivolts. Only the USB raw-HID channel carries this.
    var millivolts: Int?

    var transport: KeyboardTransport?
    var linkState: BluetoothLinkState?
    var bluetoothHost: Int?

    /// Firmware-reported age of the underlying voltage sample. The keyboard only
    /// samples every few seconds while the wireless link is up, so a reading can
    /// be fresh while the sample behind it is not.
    var sampleAgeSeconds: Int?
}

/// The full picture the menu bar renders.
struct BatteryState {
    var latest: Reading?
    var hasRawHIDInterface = false
    var hasBluetoothInterface = false
    /// Whether macOS will deliver the Bluetooth keyboard's input reports to us.
    /// Without this the wireless beacon never arrives and the level freezes at
    /// whatever the cable last reported.
    var inputMonitoring: InputMonitoring.Status = .unknown

    /// Lighting state as last reported by the keyboard. Only the cable can
    /// supply this, so it goes stale when wireless.
    var lighting: LightingState?
}
