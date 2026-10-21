import Foundation

/// One sensor's reading inside a sample.
public struct SensorSample: Codable, Sendable, Equatable {
    /// Stable per USB port: the HID location ID, e.g. "20140000".
    public var key: String
    public var lux: Double
    public var kelvin: Double?
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
}

/// Everything known at one instant. Stored as JSON, one row per minute.
public struct Sample: Codable, Sendable, Equatable {
    public var time: Date
    public var sensors: [SensorSample]
    /// Mean brightness across managed displays, 0…1. The sensors see the
    /// screens' own light, so this lets a model correct for it.
    public var screenBrightness: Double?
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

    public var medianLux: Double? { median(sensors.map(\.lux)) }

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
        if let b = median(cameras.compactMap(\.exifBrightness)) { f["camera exif brightness"] = b }
        return f
    }
}
