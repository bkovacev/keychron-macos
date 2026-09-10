import Foundation

/// Lets other processes ask the agent to perform a keyboard action.
///
/// Used by the Control Center extension. Darwin notifications are deliberate:
/// a widget extension runs sandboxed, and this needs no entitlement, no App
/// Group and no shared container. There is no payload, so each action gets its
/// own notification name.
///
/// The agent is the only process holding the HID devices and the Input
/// Monitoring grant, so it does the work; the extension only signals.
enum RemoteActions {
    static let prefix = "io.smartowl.k10pro.action"

    static func name(for action: ControlAction) -> String {
        "\(prefix).\(action.rawValue)"
    }

    /// Post an action request. Called from the Control Center extension.
    static func post(_ action: ControlAction) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name(for: action) as CFString),
            nil, nil, true
        )
    }

    private static var handler: ((ControlAction) -> Void)?

    /// Listen for action requests. Called once by the agent at start-up.
    static func listen(_ callback: @escaping (ControlAction) -> Void) {
        handler = callback
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        for action in ControlAction.allCases {
            CFNotificationCenterAddObserver(
                center,
                UnsafeRawPointer(bitPattern: UInt(action.rawValue)),
                { _, observer, _, _, _ in
                    guard let observer,
                          let action = ControlAction(rawValue: UInt8(UInt(bitPattern: observer)))
                    else { return }
                    DispatchQueue.main.async { RemoteActions.handler?(action) }
                },
                name(for: action) as CFString,
                nil,
                .deliverImmediately
            )
        }
    }
}
