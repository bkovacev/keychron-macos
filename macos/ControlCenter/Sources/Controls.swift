import AppIntents
import SwiftUI
import WidgetKit

/// Control Center controls for the Keychron K10 Pro's backlight.
///
/// These are buttons rather than a toggle on purpose. A widget extension runs
/// sandboxed, so reading the keyboard's current backlight state would need a
/// shared container (App Group) and the provisioning that comes with it — and
/// over Bluetooth the keyboard cannot report state back anyway. Buttons need
/// no state, so they work identically wired and wireless.
///
/// The extension performs no HID work itself. It posts a Darwin notification
/// and the K10ProBattery agent, which already holds the devices and the Input
/// Monitoring grant, carries out the action.

/// Mirrors `ControlAction` in the agent and `keyboard_control_action` in the
/// firmware. Duplicated rather than shared because the extension is a separate
/// target and this is the whole of its contract.
private enum Action: UInt8 {
    case backlightToggle = 1
    case brightnessUp    = 4
    case brightnessDown  = 5
    case effectNext      = 6

    var notificationName: String { "io.smartowl.k10pro.action.\(rawValue)" }
}

private func post(_ action: Action) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(action.notificationName as CFString),
        nil, nil, true
    )
}

struct ToggleBacklightIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keyboard Backlight"
    static let description = IntentDescription("Turn the Keychron K10 Pro backlight on or off.")
    func perform() async throws -> some IntentResult { post(.backlightToggle); return .result() }
}

struct BrighterIntent: AppIntent {
    static let title: LocalizedStringResource = "Keyboard Backlight Brighter"
    func perform() async throws -> some IntentResult { post(.brightnessUp); return .result() }
}

struct DimmerIntent: AppIntent {
    static let title: LocalizedStringResource = "Keyboard Backlight Dimmer"
    func perform() async throws -> some IntentResult { post(.brightnessDown); return .result() }
}

struct NextEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Keyboard Backlight Effect"
    func perform() async throws -> some IntentResult { post(.effectNext); return .result() }
}

struct BacklightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.smartowl.k10pro.control.backlight") {
            ControlWidgetButton(action: ToggleBacklightIntent()) {
                Label("Backlight", systemImage: "keyboard.badge.ellipsis")
            }
        }
        .displayName("Keyboard Backlight")
        .description("Turn the Keychron K10 Pro backlight on or off.")
    }
}

struct BrighterControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.smartowl.k10pro.control.brighter") {
            ControlWidgetButton(action: BrighterIntent()) {
                Label("Brighter", systemImage: "sun.max")
            }
        }
        .displayName("Keyboard Brighter")
    }
}

struct DimmerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.smartowl.k10pro.control.dimmer") {
            ControlWidgetButton(action: DimmerIntent()) {
                Label("Dimmer", systemImage: "sun.min")
            }
        }
        .displayName("Keyboard Dimmer")
    }
}

struct EffectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.smartowl.k10pro.control.effect") {
            ControlWidgetButton(action: NextEffectIntent()) {
                Label("Effect", systemImage: "sparkles")
            }
        }
        .displayName("Keyboard Effect")
    }
}

@main
struct K10ProControlsBundle: WidgetBundle {
    var body: some Widget {
        BacklightControl()
        BrighterControl()
        DimmerControl()
        EffectControl()
    }
}
