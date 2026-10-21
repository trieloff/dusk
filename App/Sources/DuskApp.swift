import AppKit
import DuskCore
import ServiceManagement

/// The one engine, shared by the menu bar item and the App Intents (which the
/// system may run before the app has finished launching).
@MainActor
enum Host {
    static let engine: Engine = {
        let config: Config
        do { config = try Config.load() } catch {
            Log.write("config: \(error); using defaults")
            config = Config()
        }
        let e = Engine(config: config, log: Log.write)
        e.automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true
        return e
    }()
}

/// Appends to the same log the command-line agent used.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/dusk.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ s: String) {
        let line = "\(formatter.string(from: Date()))  \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var engine: Engine { Host.engine }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        retireLaunchAgent()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        engine.onChange = { [weak self] in self?.refreshIcon() }
        Log.write("Dusk.app \(Bundle.main.shortVersion) started"
                  + (engine.model.map { "; model: \($0.summary)" } ?? ""))
        engine.start()
        refreshIcon()
        // It replaces a launch agent that ran at login, so it should too —
        // once; after that the menu's "Open at Login" is the user's to change.
        if !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            do {
                try SMAppService.mainApp.register()
                Log.write("registered to open at login")
            } catch { Log.write("open at login: \(error)") }
        }
    }

    /// The command-line agent and the app would fight over the same displays.
    private func retireLaunchAgent() {
        let label = "com.trieloff.dusk"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)
        Log.write("retired the launch agent \(label); Dusk.app runs dusk now")
    }

    // MARK: click handling

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true {
            showMenu()
        } else {
            Task { await engine.toggle(source: "menu bar") }
        }
    }

    private func showMenu() {
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { item.menu = nil }

    // MARK: icon

    private func refreshIcon() {
        guard let button = item?.button else { return }
        let dark = SystemAppearance.current == .dark
        let learning = engine.pendingCorrection != nil
        let name = dark ? (learning ? "moon" : "moon.fill") : (learning ? "sun.max" : "sun.max.fill")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: dark ? "Dark mode" : "Light mode")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = engine.automatic ? 1 : 0.5
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        var lines = ["Click: switch to \(SystemAppearance.current == .dark ? "light" : "dark") mode",
                     "Right-click: details"]
        if let c = engine.pendingCorrection {
            let left = max(0, 300 - Date().timeIntervalSince(c.time))
            lines.append("Learning \(c.to) in \(Int(left / 60)):\(String(format: "%02d", Int(left) % 60)) unless you switch back")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: menu

    private func info(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func action(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let s = engine.lastSample
        m.addItem(info("\(SystemAppearance.current == .dark ? "Dark" : "Light") mode — click the icon to switch"))
        if let c = engine.pendingCorrection {
            let left = max(0, 300 - Date().timeIntervalSince(c.time))
            m.addItem(info("Learning “\(c.to)” in \(Int(left / 60)):\(String(format: "%02d", Int(left) % 60)) unless you switch back"))
        }
        m.addItem(.separator())
        if let s {
            let each = s.sensors.map { fmt($0.lux) }.joined(separator: " · ")
            m.addItem(info("Room \(fmt(s.medianLux)) lx" + (s.sensors.count > 1 ? "  (\(each))" : "")))
            var sky: [String] = []
            if let e = s.sunElevation { sky.append(String(format: "Sun %.1f°, %@", e, s.sunRising == true ? "rising" : "setting")) }
            if let w = s.weather {
                sky.append(String(format: "outdoors %.0f W/m²", w.shortwave) + (w.cloudCover.map { String(format: ", %.0f%% cloud", $0) } ?? ""))
            }
            if !sky.isEmpty { m.addItem(info(sky.joined(separator: " · "))) }
            if let b = s.screenBrightness { m.addItem(info("Screens at \(Int((b * 100).rounded()))%")) }
        }
        m.addItem(.separator())
        if let model = engine.model {
            m.addItem(info("Learned: \(model.summary)"))
            m.addItem(info(String(format: "From %d correction(s), %.0f%% right in cross-validation",
                                  model.corrections, model.correctionAccuracy * 100)))
            if let p = engine.lastDecider.probability {
                m.addItem(info(String(format: "Chance it should be dark now: %.0f%%", p * 100)))
            }
        } else {
            m.addItem(info("Nothing learned yet — using the rules (\(engine.config.source.rawValue))"))
            m.addItem(info("Switch by hand when it feels wrong; dusk learns from it"))
        }
        if engine.training { m.addItem(info("Training…")) }
        m.addItem(.separator())
        m.addItem(toggle("Switch Automatically", engine.automatic, #selector(toggleAutomatic)))
        m.addItem(toggle("Photograph the Room When I Switch", engine.config.cameraOnCorrection, #selector(toggleCamera)))
        m.addItem(action("Retrain Now", #selector(retrain)))
        m.addItem(action("Show History in Finder", #selector(showHistory)))
        m.addItem(action("Open Log", #selector(openLog)))
        m.addItem(.separator())
        m.addItem(toggle("Open at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        m.addItem(action("Quit Dusk", #selector(quit), key: "q"))
        return m
    }

    @objc private func toggleAutomatic() {
        engine.automatic.toggle()
        UserDefaults.standard.set(engine.automatic, forKey: "automatic")
        Log.write("automatic switching \(engine.automatic ? "on" : "off")")
        refreshIcon()
    }

    @objc private func toggleCamera() {
        engine.config.cameraOnCorrection.toggle()
        var c = (try? Config.load()) ?? Config()
        c.cameraOnCorrection = engine.config.cameraOnCorrection
        try? c.save()
    }

    @objc private func retrain() { Task { await engine.retrain() } }

    @objc private func showHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.defaultDirectory])
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("open at login: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}
