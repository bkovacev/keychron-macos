import AppKit

/// The menu bar item and its dropdown.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = KeyboardMonitor()
    private let store = BatteryStore()
    private let notifier = Notifier()
    private let powerSource = PowerSourcePublisher()
    private var pollTimer: Timer?

    /// Date of the last reading actually written to history. Device
    /// add/remove republishes the same reading, and appending it again would
    /// stamp an old measurement with a new timestamp and skew the drain rate.
    private var lastRecordedDate: Date?

    /// Live references to the two lines that change while the menu is open, so
    /// they can be updated in place. Rebuilding the menu underneath an open
    /// one tears it down mid-click.
    private var headlineItem: NSMenuItem?
    private var lightingItem: NSMenuItem?
    private var menuIsOpen = false

    /// Last seen permission state, to notice the moment it is granted.
    private var lastPermission: InputMonitoring.Status = .unknown

    /// How long a reading's charging flag is believed.
    ///
    /// The keyboard measures USB power at the source, so its flag is the
    /// authority - including when it is charging from a wall socket while
    /// typing wirelessly, which this Mac cannot see at all. What cannot be
    /// believed is an *old* flag: a reading taken on the cable outlives the
    /// cable being pulled. The beacon refreshes at least every five minutes
    /// while the keyboard is in use, so anything older than this is treated as
    /// no longer speaking for the present.
    private let chargingFlagTrustWindow: TimeInterval = 10 * 60

    /// Last reading from a previous run, shown until a live one arrives.
    private var seeded: Reading?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    func start() {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self          // rebuild on open, never while open
        statusItem.menu = menu

        monitor.onUpdate = { [weak self] state in
            guard let self else { return }
            if let reading = state.latest {
                if reading.date != self.lastRecordedDate {
                    self.lastRecordedDate = reading.date
                    self.store.append(reading)
                    self.notifier.consider(percent: reading.percent, charging: reading.charging)
                }
                self.publishPowerSource(reading, cablePresent: state.hasRawHIDInterface)
            }
            self.render(state)
        }

        // Seed from persisted history so the menu bar and the Control Center
        // entry survive a restart, or a stretch with no cable and no typing,
        // instead of going blank until the next reading arrives.
        if let last = store.readings.last {
            lastRecordedDate = last.date
            seeded = last
            publishPowerSource(last, cablePresent: false)
        }

        // The Control Center extension signals through here rather than
        // touching HID itself.
        RemoteActions.listen { [weak self] action in
            guard let self else { return }
            let channel = self.monitor.send(action)
            StatusFile.lastRemoteAction = (action, channel != nil, Date())
            self.render(self.monitor.state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.monitor.pollLighting()
            }
        }

        // Deliberately does not request here. This is a background agent with
        // no window, so a request it cannot present is recorded by macOS as a
        // denial with no prompt shown - which burns the permission, since only
        // System Settings can undo a denial. The menu asks instead, where the
        // request is user-initiated.
        lastPermission = InputMonitoring.status

        monitor.start()
        render(monitor.state)

        // The cable channel is request/response, so it needs polling. The
        // Bluetooth beacon pushes on its own and is unaffected by this.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkPermissionChange()
            self?.render(self?.monitor.state ?? BatteryState())
            self?.monitor.poll()
            self?.monitor.pollLighting()
        }
        monitor.poll()
        monitor.pollLighting()
    }

    /// Mirror the reading into the system power-source registry, which is what
    /// puts the keyboard in Control Center's Batteries section.
    private func publishPowerSource(_ reading: Reading, cablePresent: Bool) {
        let charging = isCharging(reading, cablePresent: cablePresent)

        powerSource.publish(
            name: "Keychron K10 Pro",
            identifier: monitor.bluetoothAddress ?? "keychron-k10-pro",
            percent: reading.percent,
            charging: charging,
            minutesRemaining: charging ? nil : store.minutesRemaining(from: reading.percent)
        )
    }

    // MARK: - Rendering

    private func render(_ rawState: BatteryState) {
        var state = rawState
        if state.latest == nil { state.latest = seeded }
        statusItem.button?.title = title(for: state)
        statusItem.button?.toolTip = "Keychron K10 Pro battery"

        // While the menu is up, touch only the lines whose text changed.
        // Rebuilding would dismiss it, which is what made every click close
        // the menu.
        if menuIsOpen {
            if let reading = state.latest { headlineItem?.title = headline(for: reading) }
            lightingItem?.title = lightingSummary(state)
        }

        StatusFile.write(state, channel: monitor.availableChannel, seeded: seeded)
    }

    /// Input Monitoring can be granted long after start-up, and the input
    /// report callbacks registered beforehand never deliver, so discovery has
    /// to be redone once it lands.
    private func checkPermissionChange() {
        let now = InputMonitoring.status
        defer { lastPermission = now }
        guard now == .granted, lastPermission != .granted else { return }
        monitor.restartDiscovery()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        checkPermissionChange()
        var state = monitor.state
        if state.latest == nil { state.latest = seeded }
        rebuildMenu(state)

        // Refresh on open: over the cable this queries directly, wirelessly it
        // asks the keyboard to push a level.
        monitor.poll()
        monitor.pollLighting()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        headlineItem = nil
        lightingItem = nil
    }

    /// Whether to present the keyboard as charging.
    ///
    /// Trust the keyboard's own flag while the reading is recent, since it is
    /// measuring the charger directly. Fall back to this Mac's view of the
    /// cable only once the reading is too old to speak for the present -
    /// otherwise a reading taken on the cable keeps claiming "charging" long
    /// after the cable was pulled.
    private func isCharging(_ reading: Reading, cablePresent: Bool) -> Bool {
        guard reading.charging else { return false }
        if Date().timeIntervalSince(reading.date) <= chargingFlagTrustWindow { return true }
        return cablePresent
    }

    private func headline(for reading: Reading) -> String {
        let charging = isCharging(reading, cablePresent: monitor.state.hasRawHIDInterface)
        return charging ? "\(reading.percent)% — charging" : "\(reading.percent)%"
    }

    private func title(for state: BatteryState) -> String {
        guard let reading = state.latest else {
            return state.hasRawHIDInterface || state.hasBluetoothInterface ? "⌨ ?" : "⌨ –"
        }
        return "⌨ \(reading.percent)%" + (reading.charging ? " ⚡" : "")
    }

    private func rebuildMenu(_ state: BatteryState) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if let reading = state.latest {
            let stale = reading.date == seeded?.date && !state.hasRawHIDInterface
            let item = disabled(headline(for: reading), bold: true)
            headlineItem = item
            menu.addItem(item)

            let age = Date().timeIntervalSince(reading.date)
            var updated = "Updated \(relativeFormatter.localizedString(for: reading.date, relativeTo: Date()))"
            if stale || age > 900 { updated += " — may be out of date" }
            menu.addItem(disabled(updated))

            if let millivolts = reading.millivolts {
                let volts = String(format: "%.2f V", Double(millivolts) / 1000)
                menu.addItem(disabled("Cell voltage  \(volts)"))
            }

            if !reading.charging, let remaining = store.timeRemaining(from: reading.percent) {
                menu.addItem(disabled("Estimated  \(format(duration: remaining)) left"))
            }
            if let rate = store.drainPercentPerHour {
                menu.addItem(disabled(String(format: "Drain rate  %.2f%%/hour", rate)))
            }

            menu.addItem(.separator())

            let via = reading.source == .usbRawHID ? "USB cable (exact)" : "Bluetooth beacon"
            menu.addItem(disabled("Read via  \(via)"))

            if let transport = reading.transport {
                var line = "Keyboard mode  \(transport.label)"
                if transport == .bluetooth, let host = reading.bluetoothHost, host > 0 {
                    line += " · host \(host)"
                }
                menu.addItem(disabled(line))
            }
            if let link = reading.linkState, reading.transport == .bluetooth {
                menu.addItem(disabled("Link  \(link.label)"))
            }
            if let age = reading.sampleAgeSeconds, age > 15 {
                menu.addItem(disabled("Firmware sample age  \(age)s"))
            }
        } else {
            menu.addItem(disabled("No reading yet", bold: true))
            menu.addItem(disabled(waitingExplanation(state)))
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Cable: \(state.hasRawHIDInterface ? "connected" : "not connected")"))
        menu.addItem(disabled("Bluetooth: \(state.hasBluetoothInterface ? "paired" : "not visible")"))

        if powerSource.isPublishing {
            menu.addItem(disabled("Shown in Control Center ✓"))
        } else if let error = powerSource.lastError {
            menu.addItem(disabled("Control Center: \(error)"))
        }

        switch state.inputMonitoring {
        case .granted:
            break
        case .denied, .unknown:
            menu.addItem(.separator())
            menu.addItem(disabled("Wireless readings need Input Monitoring."))
            let item = NSMenuItem(title: state.inputMonitoring == .denied
                                      ? "Open Privacy & Security…"
                                      : "Grant Input Monitoring…",
                                  action: #selector(fixInputMonitoring), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        addControls(to: menu, state: state)

        menu.addItem(.separator())

        let refreshTitle = monitor.availableChannel == .rawHID
            ? "Refresh Now"
            : "Ask Keyboard to Report"
        let refresh = NSMenuItem(title: refreshTitle, action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addControls(to menu: NSMenu, state: BatteryState) {
        menu.addItem(.separator())
        menu.addItem(disabled("Backlight", bold: true))

        guard let channel = monitor.availableChannel else {
            if monitor.controlBlockedByPermission {
                menu.addItem(disabled("Needs Input Monitoring — see above"))
            } else {
                menu.addItem(disabled(state.hasBluetoothInterface
                    ? "Keyboard not reachable" : "Keyboard not found"))
            }
            return
        }

        // Over the cable the keyboard reports whether the backlight is on, so
        // the first button can say which way it will go. Wirelessly there is
        // no readback, so it stays a plain toggle.
        let known = channel == .rawHID ? state.lighting : nil
        let wired = channel == .rawHID

        var segments: [ControlStripView.Segment] = [
            .init(symbol: known?.enabled == false ? "lightbulb" : "lightbulb.slash",
                  title: known.map { $0.enabled ? "Off" : "On" } ?? "Toggle",
                  enabled: true,
                  perform: { [weak self] in
                      self?.run(known.map { $0.enabled ? .backlightOff : .backlightOn }
                                ?? .backlightToggle)
                  }),
            .init(symbol: "sun.min", title: "Dimmer", enabled: true,
                  perform: { [weak self] in self?.run(.brightnessDown) }),
            .init(symbol: "sun.max", title: "Brighter", enabled: true,
                  perform: { [weak self] in self?.run(.brightnessUp) }),
            .init(symbol: "sparkles", title: "Effect", enabled: true,
                  perform: { [weak self] in self?.run(.effectNext) }),
        ]

        // Previous-effect does not fit the wireless channel's three bits.
        if wired {
            segments.append(.init(symbol: "arrow.uturn.backward", title: "Back",
                                  enabled: true,
                                  perform: { [weak self] in self?.run(.effectPrev) }))
        }

        let strip = NSMenuItem()
        strip.view = ControlStripView(width: 280, segments: segments)
        menu.addItem(strip)

        let summary = disabled(lightingSummary(state))
        lightingItem = summary
        menu.addItem(summary)
    }

    private func lightingSummary(_ state: BatteryState) -> String {
        guard let channel = monitor.availableChannel else { return "" }
        guard channel == .rawHID, let known = state.lighting else {
            return "Sent over Bluetooth · keyboard cannot report back"
        }
        let percent = Int((Double(known.brightness) / 255 * 100).rounded())
        return "Brightness \(percent)%  ·  effect \(known.effect + 1)/\(known.effectCount)"
    }

    /// Perform an action and refresh, without disturbing the open menu.
    private func run(_ action: ControlAction) {
        monitor.send(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.monitor.pollLighting()
        }
    }

    private func waitingExplanation(_ state: BatteryState) -> String {
        if state.hasRawHIDInterface {
            return "Cable is connected but the firmware has no sample yet."
        }
        if state.hasBluetoothInterface {
            return "Type a few keys — the beacon rides along with typing."
        }
        return "Keyboard not found."
    }

    private func disabled(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        return item
    }

    private func format(duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    // MARK: - Actions

    @objc private func refresh() {
        monitor.poll()
        monitor.pollLighting()
    }

    @objc private func fixInputMonitoring() {
        // request() shows the system prompt the first time; once denied only
        // Settings can change it.
        if !InputMonitoring.request() {
            InputMonitoring.openSettings()
        }
    }

    @objc private func quit() {
        powerSource.unpublish()
        NSApp.terminate(nil)
    }
}
