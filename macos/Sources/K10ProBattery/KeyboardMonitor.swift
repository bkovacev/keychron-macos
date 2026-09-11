import Foundation
import IOKit
import IOKit.hid

/// Wire protocol shared with `firmware/src/battery_report.h`.
enum Wire {
    static let vendorID = 0x3434            // Keychron

    // Raw HID (USB)
    static let rawHIDUsagePage = 0xFF60     // QMK raw HID
    static let rawHIDUsage = 0x61
    static let reportSize = 32              // RAW_EPSIZE
    static let cmd: UInt8 = 0xAC
    static let subGet: UInt8 = 0x01
    static let subState: UInt8 = 0x81
    static let percentUnknown: UInt8 = 0xFF

    enum Offset {
        static let cmd = 0, sub = 1, version = 2, percent = 3, voltage = 4
        static let flags = 6, transport = 7, btState = 8, btHost = 9, age = 10
    }

    enum Flag {
        static let usbPower: UInt8 = 1 << 0
        static let hasSample: UInt8 = 1 << 1
        static let empty: UInt8 = 1 << 2
        static let critical: UInt8 = 1 << 3
    }

    // Bluetooth consumer-usage beacon
    static let beaconDischargingBase = 0x0300
    static let beaconChargingBase = 0x0380
    static let consumerReportID: UInt8 = 0x0A
}

/// Watches every HID interface the keyboard exposes and turns them into
/// `Reading`s.
///
/// The keyboard shows up as several independent HID interfaces. Two matter:
///
///  * the QMK raw HID interface (usage page 0xFF60) on the USB cable, which
///    answers an explicit query with the exact voltage, and
///  * the Bluetooth keyboard interface, whose consumer report carries the
///    beacon the firmware emits while the user types.
final class KeyboardMonitor {
    private(set) var state = BatteryState()
    var onUpdate: ((BatteryState) -> Void)?

    private var manager: IOHIDManager?
    private var rawHIDDevices: [IOHIDDevice] = []
    private var bluetoothDevices: [IOHIDDevice] = []

    /// Keyboard collections, the only host-to-keyboard channel over Bluetooth.
    ///
    /// The LED elements are resolved lazily rather than at discovery time:
    /// without Input Monitoring the device cannot be opened and the elements
    /// come back empty, so resolving once at start-up would leave the agent
    /// permanently unable to control the keyboard even after the grant
    /// arrives.
    private var keyboardCollections: [(device: IOHIDDevice, wireless: Bool)] = []
    private var ledElements: [ObjectIdentifier: [IOHIDElement]] = [:]

    /// The keyboard's Bluetooth address, used as a stable power-source
    /// identifier so Control Center recognises the same accessory each launch.
    private(set) var bluetoothAddress: String?

    /// Input report buffers must outlive the callback registration.
    private var buffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]

    // MARK: - Lifecycle

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Wire.vendorID] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<KeyboardMonitor>.fromOpaque(ctx).takeUnretainedValue().add(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<KeyboardMonitor>.fromOpaque(ctx).takeUnretainedValue().remove(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Ask the keyboard for its battery level.
    ///
    /// Over the cable this is a direct query. Wirelessly there is no query, so
    /// it asks the keyboard to push one - without that a refresh would silently
    /// do nothing, since the beacon is otherwise sent entirely on the
    /// keyboard's own schedule.
    func poll() {
        guard !rawHIDDevices.isEmpty else {
            _ = sendViaLEDElements(ControlAction.reportBattery.rawValue)
            return
        }

        var packet = [UInt8](repeating: 0, count: Wire.reportSize)
        packet[Wire.Offset.cmd] = Wire.cmd
        packet[Wire.Offset.sub] = Wire.subGet

        for device in rawHIDDevices {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
    }

    // MARK: - Sending commands

    /// Which channel a command would use right now, or nil if none is usable.
    var availableChannel: ControlChannel? {
        if !rawHIDDevices.isEmpty { return .rawHID }
        if ledTarget != nil { return .ledReport }
        return nil
    }

    /// True when a keyboard is present but its LED elements are out of reach,
    /// which in practice means Input Monitoring has not been granted.
    var controlBlockedByPermission: Bool {
        rawHIDDevices.isEmpty && !keyboardCollections.isEmpty && ledTarget == nil
    }

    /// Resolve the LED elements, opening the device if needed. Wireless first:
    /// that is the case this channel exists for.
    private var ledTarget: (device: IOHIDDevice, elements: [IOHIDElement])? {
        let ordered = keyboardCollections.filter(\.wireless)
                    + keyboardCollections.filter { !$0.wireless }

        for entry in ordered {
            let key = ObjectIdentifier(entry.device)
            if let cached = ledElements[key] { return (entry.device, cached) }

            // Setting an element needs the device open, and a plain keyboard
            // collection is not opened by listen().
            _ = IOHIDDeviceOpen(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            if let found = Self.commandLEDElements(of: entry.device) {
                ledElements[key] = found
                return (entry.device, found)
            }
        }
        return nil
    }

    /// LED usages 3, 4 and 5 (Scroll Lock, Compose, Kana) in that order, which
    /// is the order their bits appear in the report.
    ///
    /// Deliberately not Caps Lock, which the OS drives, nor Num Lock, which
    /// lights a real key on this board.
    private static let commandLEDUsages: [UInt32] = [3, 4, 5]

    private static func commandLEDElements(of device: IOHIDDevice) -> [IOHIDElement]? {
        guard let all = IOHIDDeviceCopyMatchingElements(device, nil,
                                                        IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else { return nil }

        let leds = all.filter {
            IOHIDElementGetType($0) == kIOHIDElementTypeOutput &&
            IOHIDElementGetUsagePage($0) == 0x08
        }

        // Keep them in usage order so bit 0 is always Scroll Lock.
        let wanted = commandLEDUsages.compactMap { usage in
            leds.first { IOHIDElementGetUsage($0) == usage }
        }
        return wanted.count == commandLEDUsages.count ? wanted : nil
    }

    /// Perform an action on the keyboard. Prefers the cable, because it is
    /// acknowledged and returns state; falls back to the LED report.
    @discardableResult
    func send(_ action: ControlAction, forceLEDReport: Bool = false) -> ControlChannel? {
        if !rawHIDDevices.isEmpty && !forceLEDReport {
            var packet = [UInt8](repeating: 0, count: Wire.reportSize)
            packet[Wire.ControlOffset.cmd] = Wire.controlCmd
            packet[Wire.ControlOffset.sub] = Wire.controlSubAction
            packet[2] = action.rawValue
            for device in rawHIDDevices {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
            }
            return .rawHID
        }
        return sendViaLEDElements(action.rawValue) ? .ledReport : nil
    }

    /// Set brightness or effect directly. Cable only — the LED report has no
    /// room for a value, so this returns false when wireless.
    @discardableResult
    func set(_ setting: UInt8, to value: UInt8) -> Bool {
        guard !rawHIDDevices.isEmpty else { return false }
        var packet = [UInt8](repeating: 0, count: Wire.reportSize)
        packet[Wire.ControlOffset.cmd] = Wire.controlCmd
        packet[Wire.ControlOffset.sub] = Wire.controlSubSet
        packet[2] = setting
        packet[3] = value
        for device in rawHIDDevices {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
        return true
    }

    /// Ask the keyboard for its lighting state. Cable only.
    func pollLighting() {
        guard !rawHIDDevices.isEmpty else { return }
        var packet = [UInt8](repeating: 0, count: Wire.reportSize)
        packet[Wire.ControlOffset.cmd] = Wire.controlCmd
        packet[Wire.ControlOffset.sub] = Wire.controlSubGet
        for device in rawHIDDevices {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
    }

    /// How long the LED bits are held before being cleared.
    ///
    /// Each element write is its own report, so the keyboard waits for the
    /// field to stop changing (KEYBOARD_CONTROL_LED_SETTLE, 50 ms) before
    /// acting. The hold has to outlast the writes arriving plus that settle
    /// window, with margin for the Bluetooth link.
    private static let ledPulseHold: TimeInterval = 0.30

    /// Drive the three command LEDs to encode the action, then clear them.
    ///
    /// The firmware triggers on the transition into a non-zero value, so the
    /// trailing clear both completes the pulse and re-arms it.
    /// Result of the last LED-element write, for diagnostics.
    private(set) var lastLEDWriteError: String?

    private func sendViaLEDElements(_ action: UInt8) -> Bool {
        guard let target = ledTarget else {
            lastLEDWriteError = keyboardCollections.isEmpty
                ? "keyboard not present"
                : "LED elements unavailable (Input Monitoring?)"
            return false
        }

        if let failure = Self.write(action, to: target.elements, on: target.device) {
            lastLEDWriteError = failure
            return false
        }
        lastLEDWriteError = nil

        let (device, elements) = (target.device, target.elements)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ledPulseHold) {
            _ = Self.write(0, to: elements, on: device)
        }
        return true
    }

    /// Bit `n` of the action goes to element `n`, which is why the elements are
    /// collected in usage order.
    /// Returns nil on success, or a description of the first failure.
    @discardableResult
    private static func write(_ action: UInt8,
                              to elements: [IOHIDElement],
                              on device: IOHIDDevice) -> String? {
        for (bit, element) in elements.enumerated() {
            let value: CFIndex = (action >> UInt8(bit)) & 1 == 1 ? 1 : 0
            let v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, value)
            let r = IOHIDDeviceSetValue(device, element, v)
            if r != kIOReturnSuccess {
                return String(format: "SetValue(usage %u, %ld) -> 0x%08x",
                              IOHIDElementGetUsage(element), value, r)
            }
        }
        return nil
    }

    /// Which interface the LED channel would drive right now.
    var ledTargetDescription: String? {
        guard ledTarget != nil else { return nil }
        let wireless = keyboardCollections.first(where: \.wireless) != nil
        return "\(wireless ? "Bluetooth" : "USB") interface, LED usages 3/4/5"
    }

    /// Re-run discovery. Used when Input Monitoring is granted after start-up:
    /// the input-report callbacks registered before the grant never deliver.
    func restartDiscovery() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for buffer in buffers.values { buffer.deallocate() }
        buffers.removeAll()
        rawHIDDevices.removeAll()
        bluetoothDevices.removeAll()
        keyboardCollections.removeAll()
        ledElements.removeAll()
        manager = nil
        start()
    }

    // MARK: - Device bookkeeping

    private func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (property(device, key) as? NSNumber)?.intValue
    }

    private func add(_ device: IOHIDDevice) {
        let usagePage = intProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = intProperty(device, kIOHIDPrimaryUsageKey)
        let transport = property(device, kIOHIDTransportKey) as? String ?? ""

        if usagePage == Wire.rawHIDUsagePage && usage == Wire.rawHIDUsage {
            rawHIDDevices.append(device)
            state.hasRawHIDInterface = true
            listen(device)
            poll()
        } else if transport.caseInsensitiveCompare("Bluetooth") == .orderedSame {
            bluetoothDevices.append(device)
            state.hasBluetoothInterface = true
            bluetoothAddress = property(device, kIOHIDSerialNumberKey) as? String
            listen(device)
        }

        if usagePage == 0x01 && usage == 0x06 {
            let wireless = transport.caseInsensitiveCompare("Bluetooth") == .orderedSame
            keyboardCollections.append((device, wireless))
        }

        publish()
    }

    private func remove(_ device: IOHIDDevice) {
        rawHIDDevices.removeAll { $0 == device }
        bluetoothDevices.removeAll { $0 == device }
        keyboardCollections.removeAll { $0.device == device }
        ledElements.removeValue(forKey: ObjectIdentifier(device))

        if let buffer = buffers.removeValue(forKey: ObjectIdentifier(device)) {
            buffer.deallocate()
        }

        state.hasRawHIDInterface = !rawHIDDevices.isEmpty
        state.hasBluetoothInterface = !bluetoothDevices.isEmpty
        publish()
    }

    private func listen(_ device: IOHIDDevice) {
        // Succeeds even without Input Monitoring; the reports are withheld
        // silently, so the permission is queried separately.
        _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        let capacity = 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        buffers[ObjectIdentifier(device)] = buffer

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, capacity,
            { ctx, _, _, _, reportID, report, length in
                guard let ctx, length > 0 else { return }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(ctx).takeUnretainedValue()
                let bytes = UnsafeBufferPointer(start: report, count: Int(length))
                monitor.handle(reportID: UInt8(truncatingIfNeeded: reportID), bytes: Array(bytes))
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    // MARK: - Decoding

    private func handle(reportID: UInt8, bytes: [UInt8]) {
        if let reading = Self.decodeRawHID(bytes) {
            record(reading)
        } else if let lighting = Self.decodeLighting(bytes) {
            state.lighting = lighting
            publish()
        } else if let reading = Self.decodeBeacon(reportID: reportID, bytes: bytes) {
            record(reading)
        }
    }

    /// Decode a `KEYBOARD_CONTROL_SUB_STATE` packet.
    static func decodeLighting(_ bytes: [UInt8]) -> LightingState? {
        guard bytes.count >= Wire.reportSize,
              bytes[Wire.ControlOffset.cmd] == Wire.controlCmd,
              bytes[Wire.ControlOffset.sub] == Wire.controlSubState
        else { return nil }

        var checksum: UInt16 = 0
        for index in 1..<(Wire.reportSize - 2) { checksum &+= UInt16(bytes[index]) }
        let expected = UInt16(bytes[Wire.reportSize - 2]) | (UInt16(bytes[Wire.reportSize - 1]) << 8)
        guard checksum == expected else { return nil }

        return LightingState(
            enabled: bytes[Wire.ControlOffset.enabled] != 0,
            brightness: Int(bytes[Wire.ControlOffset.brightness]),
            effect: Int(bytes[Wire.ControlOffset.effect]),
            effectCount: Int(bytes[Wire.ControlOffset.effectMax]) + 1,
            kind: LightingState.Kind(rawValue: bytes[Wire.ControlOffset.lighting]) ?? .none,
            lastLEDByte: bytes[Wire.ControlOffset.ledByte],
            actionCount: Int(bytes[Wire.ControlOffset.actionSeq]),
            ledSeenMask: bytes[Wire.ControlOffset.ledSeen],
            ledChanges: Int(bytes[Wire.ControlOffset.ledChanges]),
            lastAction: bytes[Wire.ControlOffset.lastAction],
            lastLEDs: bytes[Wire.ControlOffset.lastLEDs]
        )
    }

    private func record(_ reading: Reading) {
        state.latest = reading
        publish()
    }

    private func publish() {
        state.inputMonitoring = InputMonitoring.status
        onUpdate?(state)
    }

    /// Decode a `BATTERY_REPORT_SUB_STATE` packet from the raw HID interface.
    static func decodeRawHID(_ bytes: [UInt8]) -> Reading? {
        guard bytes.count >= Wire.reportSize,
              bytes[Wire.Offset.cmd] == Wire.cmd,
              bytes[Wire.Offset.sub] == Wire.subState
        else { return nil }

        // Checksum covers bytes 1 ..< reportSize-2, matching the firmware.
        var checksum: UInt16 = 0
        for index in 1..<(Wire.reportSize - 2) {
            checksum &+= UInt16(bytes[index])
        }
        let expected = UInt16(bytes[Wire.reportSize - 2]) | (UInt16(bytes[Wire.reportSize - 1]) << 8)
        guard checksum == expected else { return nil }

        let flags = bytes[Wire.Offset.flags]
        guard flags & Wire.Flag.hasSample != 0 else { return nil }

        let raw = bytes[Wire.Offset.percent]
        guard raw != Wire.percentUnknown else { return nil }

        let millivolts = Int(bytes[Wire.Offset.voltage]) | (Int(bytes[Wire.Offset.voltage + 1]) << 8)
        let age = Int(bytes[Wire.Offset.age]) | (Int(bytes[Wire.Offset.age + 1]) << 8)

        return Reading(
            date: Date(),
            percent: min(Int(raw), 100),
            charging: flags & Wire.Flag.usbPower != 0,
            source: .usbRawHID,
            millivolts: millivolts,
            transport: KeyboardTransport(rawValue: bytes[Wire.Offset.transport]),
            linkState: BluetoothLinkState(rawValue: bytes[Wire.Offset.btState]),
            bluetoothHost: Int(bytes[Wire.Offset.btHost]),
            sampleAgeSeconds: age
        )
    }

    /// Decode the consumer-usage beacon that arrives over Bluetooth.
    ///
    /// macOS is inconsistent about whether the report ID is stripped from the
    /// buffer handed to an input-report callback, so both layouts are tried and
    /// only a value inside the reserved beacon range is accepted.
    static func decodeBeacon(reportID: UInt8, bytes: [UInt8]) -> Reading? {
        var offsets: [Int] = []
        if reportID == Wire.consumerReportID { offsets.append(0) }
        if bytes.first == Wire.consumerReportID { offsets.append(1) }
        if offsets.isEmpty { return nil }

        for offset in offsets where bytes.count >= offset + 2 {
            let usage = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)

            for (base, charging) in [(Wire.beaconChargingBase, true),
                                     (Wire.beaconDischargingBase, false)] {
                let percent = usage - base
                if (0...100).contains(percent) {
                    return Reading(date: Date(), percent: percent, charging: charging,
                                   source: .bluetoothBeacon)
                }
            }
        }
        return nil
    }
}
