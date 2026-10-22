import Foundation

/// One sensor's reading inside a sample.
public struct SensorSample: Codable, Sendable, Equatable {
    /// Stable per USB port: the HID location ID, e.g. "20140000".
    public var key: String
    public var lux: Double
    public var kelvin: Double?
}

/// One display's brightness at the time of a sample.
public struct DisplaySample: Codable, Sendable, Equatable {
    public var key: String
    public var brightness: Double
}

/// Outdoor conditions, from a weather model (Open-Meteo), for the location.
public struct WeatherSample: Codable, Sendable, Equatable {
    /// Global horizontal irradiance, W/m² — sunlight on the ground, clouds included.
    public var shortwave: Double
    public var diffuse: Double?
    public var cloudCover: Double?
    /// When the weather model's value applies (start of its 15-minute slot).
    public var validAt: Date
}

/// What one camera saw.
public struct CameraSample: Codable, Sendable, Equatable {
    public var device: String
    /// Mean luma of the frame, 0…1. Auto-exposure makes this a weak signal on
    /// its own; it is kept because the model search decides what is useful.
    public var luma: Double
    /// EXIF BrightnessValue (APEX) when the camera reports one.
    public var exifBrightness: Double?
    public var photo: String?
    /// When the frame was taken. Readings are carried into later samples
    /// until the next capture, so the model can use them between photos.
    public var takenAt: Date?
}

/// Everything known at one instant. Stored as JSON, one row per minute.
public struct Sample: Codable, Sendable, Equatable {
    public var time: Date
    public var sensors: [SensorSample]
    /// Mean brightness across managed displays, 0…1. The sensors see the
    /// screens' own light, so this lets a model correct for it.
    public var screenBrightness: Double?
    /// Each display's brightness. Dusk sets them alike, so as features they
    /// would only repeat the mean; kept for when one is changed by hand.
    public var displays: [DisplaySample] = []
    /// What each sensor is currently estimated to see of the screens, from the
    /// probes so far (see Probes.swift). Copied into every sample so features
    /// can be computed from the sample alone.
    public var screenLight: [ScreenSensorEstimate] = []
    public var appearance: Appearance
    public var sunElevation: Double?
    public var sunRising: Bool?
    /// Minutes until today's sunset (negative after it).
    public var minutesToSunset: Double?
    public var minutesSinceSunrise: Double?
    public var weather: WeatherSample?
    public var cameras: [CameraSample] = []

    public init(time: Date, sensors: [SensorSample], screenBrightness: Double?,
                appearance: Appearance, sunElevation: Double? = nil, sunRising: Bool? = nil,
                minutesToSunset: Double? = nil, minutesSinceSunrise: Double? = nil,
                weather: WeatherSample? = nil, cameras: [CameraSample] = []) {
        self.time = time
        self.sensors = sensors
        self.screenBrightness = screenBrightness
        self.appearance = appearance
        self.sunElevation = sunElevation
        self.sunRising = sunRising
        self.minutesToSunset = minutesToSunset
        self.minutesSinceSunrise = minutesSinceSunrise
        self.weather = weather
        self.cameras = cameras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        sensors = try c.decode([SensorSample].self, forKey: .sensors)
        screenBrightness = try c.decodeIfPresent(Double.self, forKey: .screenBrightness)
        displays = try c.decodeIfPresent([DisplaySample].self, forKey: .displays) ?? []
        screenLight = try c.decodeIfPresent([ScreenSensorEstimate].self, forKey: .screenLight) ?? []
        appearance = try c.decode(Appearance.self, forKey: .appearance)
        sunElevation = try c.decodeIfPresent(Double.self, forKey: .sunElevation)
        sunRising = try c.decodeIfPresent(Bool.self, forKey: .sunRising)
        minutesToSunset = try c.decodeIfPresent(Double.self, forKey: .minutesToSunset)
        minutesSinceSunrise = try c.decodeIfPresent(Double.self, forKey: .minutesSinceSunrise)
        weather = try c.decodeIfPresent(WeatherSample.self, forKey: .weather)
        cameras = try c.decodeIfPresent([CameraSample].self, forKey: .cameras) ?? []
    }

    public var medianLux: Double? { median(sensors.map(\.lux)) }

    /// Each sensor's reading minus what the screens are estimated to add in
    /// the current appearance and brightness; only for sensors with an estimate.
    public var roomLux: [String: Double] {
        guard let b = screenBrightness else { return [:] }
        let est = Dictionary(screenLight.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Double] = [:]
        for s in sensors {
            if let g = est[s.key]?.gain(appearance) { out[s.key] = max(0, s.lux - g * b) }
        }
        return out
    }

    public var medianRoomLux: Double? { median(Array(roomLux.values)) }

    /// Named numeric features for the model search. Light quantities are on a
    /// log scale, because both perception and the useful thresholds are.
    /// The current appearance is deliberately not a feature: it is the answer.
    public var features: [String: Double] {
        var f: [String: Double] = [:]
        func log(_ x: Double) -> Double { log10(max(x, 0) + 0.1) }
        for s in sensors {
            f["log lux \(s.key)"] = log(s.lux)
            if let k = s.kelvin { f["kelvin \(s.key)"] = k }
        }
        if !sensors.isEmpty {
            let lux = sensors.map(\.lux)
            f["log lux median"] = log(median(lux)!)
            f["log lux min"] = log(lux.min()!)
            f["log lux max"] = log(lux.max()!)
            let ks = sensors.compactMap(\.kelvin)
            if let k = median(ks) { f["kelvin median"] = k }
        }
        if let b = screenBrightness { f["screen brightness"] = b }
        // Screen-light features. Only appearance-independent ones: the gain in
        // the current mode would tell the model which mode it is in.
        let est = Dictionary(screenLight.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let room = roomLux
        var shares: [Double] = []
        for s in sensors {
            guard let e = est[s.key] else { continue }
            if let d = e.delta { f["screen delta \(s.key)"] = d }
            if let r = room[s.key] {
                f["log room lux \(s.key)"] = log(r)
                if let lg = e.lightGain, let b = screenBrightness {
                    let c = lg * b
                    let share = c / (r + c + 0.01)
                    f["light screen share \(s.key)"] = share
                    shares.append(share)
                }
            }
        }
        if let r = median(Array(room.values)) { f["log room lux median"] = log(r) }
        if let d = median(screenLight.compactMap(\.delta)) { f["screen delta median"] = d }
        if let sh = median(shares) { f["light screen share median"] = sh }
        if let e = sunElevation { f["sun elevation"] = e }
        if let r = sunRising { f["sun rising"] = r ? 1 : 0 }
        if let m = minutesToSunset { f["minutes to sunset"] = m }
        if let m = minutesSinceSunrise { f["minutes since sunrise"] = m }
        if let w = weather {
            f["log irradiance"] = log(w.shortwave)
            if let d = w.diffuse { f["log diffuse"] = log(d) }
            if let c = w.cloudCover { f["cloud cover"] = c }
        }
        let lumas = cameras.map(\.luma)
        if let l = median(lumas) { f["camera luma"] = l }
        if cameras.count > 1 { for c in cameras { f["camera luma \(c.device)"] = c.luma } }
        if let b = median(cameras.compactMap(\.exifBrightness)) { f["camera exif brightness"] = b }
        return f
    }
}
