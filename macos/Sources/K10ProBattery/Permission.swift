import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Input Monitoring status.
///
/// macOS hands a process a keyboard's input reports only with this permission
/// granted. `IOHIDDeviceOpen` still succeeds without it, so a failed open is
/// not a usable signal — ask the system directly instead.
enum InputMonitoring {
    enum Status { case granted, denied, unknown }

    private typealias CheckFn = @convention(c) (Int32) -> Int32
    private typealias RequestFn = @convention(c) (Int32) -> Bool

    private static let listenEvent: Int32 = 1   // kIOHIDRequestTypeListenEvent

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    static var status: Status {
        guard let handle, let sym = dlsym(handle, "IOHIDCheckAccess") else { return .unknown }
        switch unsafeBitCast(sym, to: CheckFn.self)(listenEvent) {
        case 0:  return .granted
        case 1:  return .denied
        default: return .unknown
        }
    }

    /// Triggers the system prompt, once per app identity. Returns false when
    /// already denied, in which case the user has to go to Settings.
    @discardableResult
    static func request() -> Bool {
        guard let handle, let sym = dlsym(handle, "IOHIDRequestAccess") else { return false }
        return unsafeBitCast(sym, to: RequestFn.self)(listenEvent)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
