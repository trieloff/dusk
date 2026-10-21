import AppIntents
import DuskCore

enum AppearanceOption: String, AppEnum {
    case light, dark

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [AppearanceOption: DisplayRepresentation] = [
        .light: "Light", .dark: "Dark",
    ]

    init(_ a: Appearance) { self = a == .dark ? .dark : .light }
    var appearance: Appearance { self == .dark ? .dark : .light }
}

struct ToggleAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dark Mode"
    static let description = IntentDescription(
        "Switches between light and dark mode. Unless you turn off Teach Dusk, the switch counts as a correction once it has stood for five minutes.")

    @Parameter(title: "Teach Dusk", default: true)
    var learn: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AppearanceOption> {
        await Host.engine.toggle(source: "shortcut", learn: learn)
        return .result(value: AppearanceOption(SystemAppearance.current))
    }
}

struct SetAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Appearance"
    static let description = IntentDescription(
        "Sets light or dark mode. Teach Dusk is off by default, so automations do not train the model; turn it on when you run this by hand.")

    @Parameter(title: "Appearance")
    var appearance: AppearanceOption

    @Parameter(title: "Teach Dusk", default: false)
    var learn: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set appearance to \(\.$appearance)") { \.$learn }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await Host.engine.set(appearance.appearance, source: "shortcut", learn: learn)
        return .result()
    }
}

struct GetAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Appearance"
    static let description = IntentDescription("Whether the Mac is in light or dark mode.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AppearanceOption> {
        .result(value: AppearanceOption(SystemAppearance.current))
    }
}

struct GetRoomLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Room Light"
    static let description = IntentDescription(
        "The room's illuminance in lux, the median of the displays' ambient light sensors.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let lux = Host.engine.sensors.read().map(\.lux).sorted()
        guard !lux.isEmpty else { throw DuskIntentError.noSensor }
        let mid = lux.count / 2
        return .result(value: lux.count % 2 == 1 ? lux[mid] : (lux[mid - 1] + lux[mid]) / 2)
    }
}

struct GetDarkChanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Chance of Dark Mode"
    static let description = IntentDescription(
        "How likely the learned model thinks you want dark mode right now, from 0 to 1.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let e = Host.engine
        guard let model = e.model else { throw DuskIntentError.noModel }
        let s = await e.sample()
        guard let p = model.probabilityDark(s.features) else { throw DuskIntentError.noModel }
        return .result(value: p)
    }
}

struct SetAutomaticIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Automatic Switching"
    static let description = IntentDescription(
        "Turns Dusk's automatic switching on or off. It keeps recording and learning either way.")

    @Parameter(title: "Automatic", default: true)
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        Host.engine.automatic = enabled
        UserDefaults.standard.set(enabled, forKey: "automatic")
        return .result()
    }
}

enum DuskIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noSensor, noModel

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noSensor: "No ambient light sensor is connected."
        case .noModel: "Dusk has not learned anything yet. Switch appearance by hand a few times first."
        }
    }
}

struct DuskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleAppearanceIntent(),
                    phrases: ["Toggle dark mode with \(.applicationName)",
                              "Switch appearance with \(.applicationName)"],
                    shortTitle: "Toggle Dark Mode", systemImageName: "circle.lefthalf.filled")
        AppShortcut(intent: GetRoomLightIntent(),
                    phrases: ["How bright is the room in \(.applicationName)"],
                    shortTitle: "Room Light", systemImageName: "light.max")
    }
}
