import Foundation

/// Low-battery notifications.
///
/// Delivered through `osascript` on purpose: `UNUserNotificationCenter` needs a
/// signed application bundle, and this tool is meant to run as a plain binary
/// or an ad-hoc bundle.
final class Notifier {
    private let thresholds = [20, 10, 5]
    private var notified: Set<Int> = []

    func consider(percent: Int, charging: Bool) {
        if charging {
            notified.removeAll()   // re-arm once the cable comes out again
            return
        }

        for threshold in thresholds where percent <= threshold && !notified.contains(threshold) {
            notified.insert(threshold)
            post(title: "Keychron K10 Pro battery low",
                 body: "\(percent)% remaining. Time to plug it in.")
            return
        }

        // Recovered well above the lowest threshold, so allow warnings again.
        if let highest = thresholds.first, percent > highest {
            notified.removeAll()
        }
    }

    private func post(title: String, body: String) {
        let script = "display notification \(quote(body)) with title \(quote(title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
