import Foundation

/// What decides between light and dark.
public enum Source: String, Codable, Sendable, CaseIterable {
    /// The room's light, from the displays' ambient light sensors. Falls back to
    /// the sun when no sensor answers.
    case ambient
    /// Sunrise and sunset at the configured location, like the old shortcut.
    case sun
    /// Dark when the sun is down *or* the room is dark; light only when both
    /// agree it is day.
    case either
}

public enum BrightnessMode: String, Codable, Sendable, CaseIterable {
    /// Map room lux onto a brightness curve.
    case curve
    /// The shortcut's behaviour: one level for light mode, one for dark mode.
    case fixed
    /// Leave brightness to macOS (and its own auto-brightness) entirely.
    case system
}

public struct BrightnessConfig: Codable, Sendable, Equatable {
    public var mode: BrightnessMode = .curve
    /// Below this the curve sits at `minimum`.
    public var minLux: Double = 1
    /// At and above this the curve sits at `maximum`.
    public var maxLux: Double = 20
    public var minimum: Double = 0.4
    public var maximum: Double = 1.0
    /// `fixed` mode levels.
    public var light: Double = 1.0
    public var dark: Double = 0.5
    /// Changes smaller than this are not applied, so sensor noise never shows.
    public var deadband: Double = 0.03

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrightnessConfig()
        mode = try c.decodeIfPresent(BrightnessMode.self, forKey: .mode) ?? d.mode
        minLux = try c.decodeIfPresent(Double.self, forKey: .minLux) ?? d.minLux
        maxLux = try c.decodeIfPresent(Double.self, forKey: .maxLux) ?? d.maxLux
        minimum = try c.decodeIfPresent(Double.self, forKey: .minimum) ?? d.minimum
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum) ?? d.maximum
        light = try c.decodeIfPresent(Double.self, forKey: .light) ?? d.light
        dark = try c.decodeIfPresent(Double.self, forKey: .dark) ?? d.dark
        deadband = try c.decodeIfPresent(Double.self, forKey: .deadband) ?? d.deadband
    }

    public var curve: BrightnessCurve {
        BrightnessCurve(minLux: minLux, maxLux: maxLux, minimum: minimum, maximum: maximum)
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var source: Source = .ambient
    /// Switch to dark once the room stays below this…
    public var darkBelowLux: Double = 8
    /// …and back to light once it stays above this. The gap is the hysteresis band.
    public var lightAboveLux: Double = 15
    /// How long a new verdict must hold before the appearance flips, so a
    /// passing cloud or someone leaning over the desk does not toggle it.
    public var holdSeconds: Double = 180
    /// Location for the sun fallback. Without one, `sun` is unavailable.
    public var latitude: Double?
    public var longitude: Double?
    /// Solar elevation that counts as "down": -0.833° is sunset proper, -6° civil dusk.
    public var sunElevation: Double = -0.833
    public var manageAppearance: Bool = true
    public var brightness = BrightnessConfig()
    /// Sensor poll interval for `dusk watch`.
    public var intervalSeconds: Double = 15
    /// Weight of each new reading in the moving average (0…1).
    public var smoothing: Double = 0.3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? d.source
        darkBelowLux = try c.decodeIfPresent(Double.self, forKey: .darkBelowLux) ?? d.darkBelowLux
        lightAboveLux = try c.decodeIfPresent(Double.self, forKey: .lightAboveLux) ?? d.lightAboveLux
        holdSeconds = try c.decodeIfPresent(Double.self, forKey: .holdSeconds) ?? d.holdSeconds
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        sunElevation = try c.decodeIfPresent(Double.self, forKey: .sunElevation) ?? d.sunElevation
        manageAppearance = try c.decodeIfPresent(Bool.self, forKey: .manageAppearance) ?? d.manageAppearance
        brightness = try c.decodeIfPresent(BrightnessConfig.self, forKey: .brightness) ?? d.brightness
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? d.intervalSeconds
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
    }

    public static var defaultURL: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("dusk/config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dusk/config.json")
    }

    /// Loads the config, or the defaults when the file does not exist.
    public static func load(from url: URL = defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public func validate() throws {
        func fail(_ s: String) throws -> Never { throw Invalid(description: s) }
        if darkBelowLux >= lightAboveLux { try fail("darkBelowLux must be below lightAboveLux") }
        if let lat = latitude, !(-90...90).contains(lat) { try fail("latitude out of range") }
        if let lon = longitude, !(-180...180).contains(lon) { try fail("longitude out of range") }
        if (latitude == nil) != (longitude == nil) { try fail("set both latitude and longitude, or neither") }
        let b = brightness
        for (name, v) in [("minimum", b.minimum), ("maximum", b.maximum), ("light", b.light), ("dark", b.dark)]
        where !(0...1).contains(v) {
            try fail("brightness.\(name) must be within 0…1")
        }
        if b.minimum > b.maximum { try fail("brightness.minimum must not exceed brightness.maximum") }
        if b.minLux <= 0 || b.minLux >= b.maxLux { try fail("brightness needs 0 < minLux < maxLux") }
        if intervalSeconds < 1 { try fail("intervalSeconds must be at least 1") }
        if !(0...1).contains(smoothing) || smoothing == 0 { try fail("smoothing must be within (0, 1]") }
    }
}
