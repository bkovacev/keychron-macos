import AppKit

/// The menu bar item and its dropdown.
final class MenuBarController: NSObject {
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

    /// Last reading from a previous run, shown until a live one arrives.
    private var seeded: Reading?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    func start() {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.menu = NSMenu()

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
            self.monitor.send(action)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.monitor.pollLighting()
            }
        }

        monitor.start()
        render(monitor.state)

        // The cable channel is request/response, so it needs polling. The
        // Bluetooth beacon pushes on its own and is unaffected by this.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.monitor.poll()
            self?.monitor.pollLighting()
        }
        monitor.poll()
        monitor.pollLighting()
    }

    /// Mirror the reading into the system power-source registry, which is what
    /// puts the keyboard in Control Center's Batteries section.
    private func publishPowerSource(_ reading: Reading, cablePresent: Bool) {
        // The reading can outlive the cable. Charging is only possible while
        // the cable is attached, and that is known live, so trust it over a
        // stale flag rather than claiming the keyboard is still charging.
        let charging = reading.charging && cablePresent

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
        rebuildMenu(state)
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
            let headline = reading.charging
                ? "\(reading.percent)% — charging"
                : "\(reading.percent)%"
            menu.addItem(disabled(headline, bold: true))

            menu.addItem(disabled("Updated \(relativeFormatter.localizedString(for: reading.date, relativeTo: Date()))"
                                  + (stale ? " (last known)" : "")))

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

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
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
            menu.addItem(disabled(state.hasBluetoothInterface
                ? "Needs the cable — macOS blocks writing"
                : "Keyboard not reachable"))
            if state.hasBluetoothInterface {
                menu.addItem(disabled("to a wireless keyboard."))
            }
            return
        }

        // Over the cable the keyboard tells us whether the backlight is on, so
        // the toggle can be labelled accurately. Wireless is write-only, so it
        // stays a plain toggle.
        let known = channel == .rawHID ? state.lighting : nil

        let toggle: ControlAction
        let toggleTitle: String
        if let known {
            toggle = known.enabled ? .backlightOff : .backlightOn
            toggleTitle = known.enabled ? "Turn Off" : "Turn On"
        } else {
            toggle = .backlightToggle
            toggleTitle = "Toggle"
        }
        menu.addItem(action(toggle, title: toggleTitle, key: "b"))

        menu.addItem(action(.brightnessUp, title: "Brighter", key: "]"))
        menu.addItem(action(.brightnessDown, title: "Dimmer", key: "["))
        menu.addItem(action(.effectNext, title: "Next Effect", key: "e"))

        if let known {
            let percent = Int((Double(known.brightness) / 255 * 100).rounded())
            menu.addItem(disabled("Brightness  \(percent)%  ·  effect \(known.effect + 1)/\(known.effectCount)"))
        }
        menu.addItem(disabled("Sent over  \(channel == .rawHID ? "the cable" : "Bluetooth")"))
    }

    private func action(_ act: ControlAction, title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = act.rawValue
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UInt8,
              let act = ControlAction(rawValue: raw) else { return }
        monitor.send(act)

        // Give the firmware a moment, then read back the real state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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
