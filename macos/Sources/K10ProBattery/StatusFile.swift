import Foundation

/// Writes what the agent currently believes to a small JSON file.
///
/// The agent is a background process with no window and no log, so when it
/// appears "stuck" there is otherwise no way to tell a missing permission from
/// an absent keyboard from a reading that simply has not arrived. This makes
/// that visible without attaching a debugger.
enum StatusFile {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("K10ProBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("status.json")
    }()

    /// Last action received from the Control Center extension, and whether it
    /// reached the keyboard. Lets the extension-to-agent bridge be verified on
    /// its own, separately from whether the keyboard link is usable.
    static var lastRemoteAction: (action: ControlAction, delivered: Bool, at: Date)?

    static func write(_ state: BatteryState, channel: ControlChannel?, seeded: Reading?) {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "written": formatter.string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "input_monitoring": String(describing: state.inputMonitoring),
            "cable_connected": state.hasRawHIDInterface,
            "bluetooth_paired": state.hasBluetoothInterface,
            "control_channel": channel?.rawValue ?? "none",
        ]

        if let reading = state.latest ?? seeded {
            payload["percent"] = reading.percent
            payload["source"] = reading.source.rawValue
            payload["reading_taken"] = formatter.string(from: reading.date)
            payload["reading_age_seconds"] = Int(Date().timeIntervalSince(reading.date))
        }
        if let lighting = state.lighting {
            payload["backlight"] = lighting.enabled ? "on" : "off"
            payload["effect"] = lighting.effect
        }

        if let remote = lastRemoteAction {
            payload["last_remote_action"] = remote.action.label
            payload["last_remote_delivered"] = remote.delivered
            payload["last_remote_at"] = formatter.string(from: remote.at)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
