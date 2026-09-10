import Foundation
import IOKit

/// Publishes the keyboard as a macOS *accessory power source*, which is what
/// populates the Batteries section of Control Center and the battery list in
/// System Settings.
///
/// This is deliberately not the Bluetooth battery path. `bluetoothd` learns an
/// accessory's level from a BLE GATT Battery Service or from Apple's own
/// accessory protocol, and the K10 Pro's Bluetooth Classic HID link offers
/// neither. But the power-source registry those readings ultimately land in is
/// writable by any process — `IOPSCreatePowerSource` needs no entitlement and
/// no root — so the agent registers the keyboard itself.
///
/// The registration lives and dies with this process: quit the agent and the
/// entry disappears.
final class PowerSourcePublisher {
    // IOPSPowerSourceID is an opaque handle, not a CoreFoundation object.
    // Typing it as CFTypeRef makes ARC retain it and crash, so it is kept as a
    // raw pointer and never memory-managed.
    private typealias CreateFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias SetDetailsFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    /// These are IOKit SPI: exported and callable, but absent from the public
    /// headers, so they are resolved by name.
    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private lazy var create = Self.symbol("IOPSCreatePowerSource", as: CreateFn.self)
    private lazy var setDetails = Self.symbol("IOPSSetPowerSourceDetails", as: SetDetailsFn.self)
    private lazy var releasePS = Self.symbol("IOPSReleasePowerSource", as: ReleaseFn.self)

    private var source: UnsafeMutableRawPointer?

    /// Nil until a publish is attempted; then whether the registry accepted it.
    private(set) var lastError: String?

    var isPublishing: Bool { source != nil }

    deinit { unpublish() }

    /// Create or update the entry. `identifier` should be stable across
    /// launches — the keyboard's Bluetooth address is ideal — so Control Center
    /// treats it as the same accessory.
    @discardableResult
    func publish(name: String,
                 identifier: String,
                 percent: Int,
                 charging: Bool,
                 minutesRemaining: Int? = nil) -> Bool {
        guard let create, let setDetails else {
            lastError = "IOPSCreatePowerSource unavailable"
            return false
        }

        if source == nil {
            var created: UnsafeMutableRawPointer?
            let result = create(&created)
            guard result == kIOReturnSuccess, let created else {
                lastError = String(format: "IOPSCreatePowerSource failed (0x%08x)", result)
                return false
            }
            source = created
        }
        guard let source else { return false }

        var details: [String: Any] = [
            "Type": "Accessory Source",
            "Accessory Category": "Keyboard",
            "Accessory Identifier": identifier,
            "Name": name,
            "Transport Type": "Bluetooth",
            "Power Source State": charging ? "AC Power" : "Battery Power",
            "Current Capacity": max(0, min(percent, 100)),
            "Max Capacity": 100,
            "Low Warn Level": 20,
            // IOPSKeys.h specifies CFBoolean for these two, not a number.
            "Is Present": true,
            "Is Charging": charging,
            "Vendor ID": Wire.vendorID,
        ]

        // Only meaningful while discharging, and only when the estimate exists.
        if !charging, let minutes = minutesRemaining, minutes > 0 {
            details["Time to Empty"] = min(minutes, 60 * 24 * 14)
        }

        let result = setDetails(source, details as CFDictionary)
        if result != kIOReturnSuccess {
            lastError = String(format: "IOPSSetPowerSourceDetails failed (0x%08x)", result)
            return false
        }

        lastError = nil
        return true
    }

    /// Remove the entry. Called on quit; without it the source would linger
    /// until the process dies anyway.
    func unpublish() {
        guard let source else { return }
        _ = releasePS?(source)
        self.source = nil
    }
}
