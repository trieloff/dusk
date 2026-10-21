import Foundation

/// The system-wide light/dark appearance.
///
/// Reads and writes go through SkyLight's `SLS…AppearanceThemeLegacy`, which is
/// what System Settings' own toggle ends up calling. Unlike scripting System
/// Events, it needs no Automation permission and never prompts. If the symbols
/// disappear in some future macOS, it falls back to System Events.
public enum SystemAppearance {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void
    private typealias GetAuto = @convention(c) () -> Bool

    nonisolated(unsafe) private static let skylight =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let skylight, let p = dlsym(skylight, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    public static var current: Appearance {
        if let get = sym("SLSGetAppearanceThemeLegacy", Get.self) {
            return get() ? .dark : .light
        }
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"]
        return (style as? String) == "Dark" ? .dark : .light
    }

    /// Whether System Settings' own "Auto" appearance is on, which would fight us.
    public static var switchesAutomatically: Bool {
        sym("SLSGetAppearanceThemeSwitchesAutomatically", GetAuto.self)?() ?? false
    }

    public static func set(_ appearance: Appearance) throws {
        if let set = sym("SLSSetAppearanceThemeLegacy", Set.self) {
            set(appearance == .dark)
            return
        }
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(appearance == .dark)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw DisplayControl.Unavailable(description: "osascript failed to set dark mode")
        }
    }
}
