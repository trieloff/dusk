import Foundation
import Testing
@testable import DuskCore

private func sample(_ t: Double, lux: Double, sun: Double = 10, rising: Bool = false,
                    brightness: Double = 0.8, appearance: Appearance = .light) -> Sample {
    Sample(time: Date(timeIntervalSince1970: t),
           sensors: [SensorSample(key: "a", lux: lux, kelvin: 4500),
                     SensorSample(key: "b", lux: lux * 0.8, kelvin: 4600)],
           screenBrightness: brightness, appearance: appearance,
           sunElevation: sun, sunRising: rising)
}

private func correction(_ t: Double, to: Appearance, lux: Double = 10, sun: Double = 10) -> Correction {
    Correction(time: Date(timeIntervalSince1970: t), from: to == .dark ? .light : .dark, to: to,
               source: "test", sample: sample(t, lux: lux, sun: sun))
}

// MARK: corrections

@Test func aCorrectionIsConfirmedAfterFiveMinutes() {
    var t = CorrectionTracker(window: 300)
    #expect(t.record(correction(0, to: .dark)) == nil)
    #expect(t.tick(now: Date(timeIntervalSince1970: 299)) == nil)
    guard case .confirmed(let c) = t.tick(now: Date(timeIntervalSince1970: 300)) else {
        Issue.record("not confirmed"); return
    }
    #expect(c.to == .dark)
    #expect(t.pending == nil)
}

@Test func undoingWithinFiveMinutesDropsBoth() {
    var t = CorrectionTracker(window: 300)
    _ = t.record(correction(0, to: .dark))
    guard case .reverted = t.record(correction(120, to: .light)) else {
        Issue.record("not reverted"); return
    }
    #expect(t.pending == nil)
    #expect(t.tick(now: Date(timeIntervalSince1970: 1000)) == nil)
}

@Test func aLateSecondSwitchSettlesTheFirst() {
    var t = CorrectionTracker(window: 300)
    _ = t.record(correction(0, to: .dark))
    guard case .confirmed(let c) = t.record(correction(400, to: .light)) else {
        Issue.record("first not confirmed"); return
    }
    #expect(c.to == .dark)
    #expect(t.pending?.to == .light)
}

// MARK: features

@Test func featuresAreLogLuxPerSensorAndNeverTheAppearance() {
    let f = sample(0, lux: 9.9, appearance: .dark).features
    #expect(abs(f["log lux a"]! - 1) < 1e-9)
    #expect(f["log lux median"] != nil)
    #expect(f["screen brightness"] == 0.8)
    #expect(f["sun rising"] == 0)
    #expect(!f.keys.contains { $0.contains("appearance") })
}

@Test func samplesRoundTripThroughJSON() throws {
    var s = sample(1_800_000_000, lux: 12)
    s.weather = WeatherSample(shortwave: 61, diffuse: 50, cloudCover: 86, validAt: s.time)
    s.cameras = [CameraSample(device: "cam", luma: 0.3, exifBrightness: nil, photo: "x.jpg", takenAt: s.time)]
    s.displays = [DisplaySample(key: "EC3A8BD7", brightness: 0.47)]
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
    let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
    #expect(try d.decode(Sample.self, from: e.encode(s)) == s)
}

@Test func samplesWithoutTheNewFieldsStillDecode() throws {
    let old = #"{"time":1800000000,"sensors":[{"key":"a","lux":3}],"appearance":"dark","cameras":[]}"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
    let s = try d.decode(Sample.self, from: Data(old.utf8))
    #expect(s.displays.isEmpty && s.medianLux == 3)
}

@Test func eachCameraIsItsOwnFeature() {
    var s = sample(0, lux: 5)
    s.cameras = [CameraSample(device: "Studio Display Camera", luma: 0.2, exifBrightness: nil, photo: nil, takenAt: nil),
                 CameraSample(device: "Studio Display Camera #2", luma: 0.4, exifBrightness: nil, photo: nil, takenAt: nil)]
    let f = s.features
    #expect(f["camera luma Studio Display Camera #2"] == 0.4)
    #expect(abs(f["camera luma"]! - 0.3) < 1e-9)
}

// MARK: learning

@Test func noModelWithoutACorrection() {
    let ex = [Example(time: .now, features: ["x": 1], dark: true, weight: 0.15),
              Example(time: .now, features: ["x": 5], dark: false, weight: 0.15)]
    #expect(Trainer.train(ex) == nil)
}

@Test func findsTheFeatureThatSeparatesTheChoices() throws {
    // Dark whenever the sun is below 7°, whatever the (noisy) room light says.
    var ex: [Example] = []
    for i in 0..<40 {
        let sun = Double(i) - 10  // -10…29
        let noise = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let f: [String: Double] = ["sun elevation": sun, "log lux median": 1 + noise]
        ex.append(Example(time: .now, features: f, dark: sun < 7, weight: i % 5 == 0 ? 1 : 0.15))
    }
    let m = try #require(Trainer.train(ex))
    #expect(m.features.first == "sun elevation")
    let t = try #require(m.threshold)
    #expect(abs(t - 7) < 3, "threshold \(t)")
    #expect(m.probabilityDark(["sun elevation": -5, "log lux median": 1.5])! > 0.9)
    #expect(m.probabilityDark(["sun elevation": 20, "log lux median": 1.5])! < 0.1)
    #expect(m.summary.hasPrefix("dark when sun elevation <"))
}

@Test func aPairOnlyWinsWhenItIsNeeded() throws {
    // Dark when the room is dim *and* the sun is setting — neither alone works.
    var ex: [Example] = []
    for lux in stride(from: 0.0, through: 2, by: 0.25) {
        for rising in [0.0, 1.0] {
            let dark = lux < 1 && rising == 0
            ex.append(Example(time: .now, features: ["log lux median": lux, "sun rising": rising],
                              dark: dark, weight: 1))
        }
    }
    let m = try #require(Trainer.train(ex))
    #expect(Set(m.features) == ["log lux median", "sun rising"])
    #expect(m.correctionAccuracy > 0.8)
}

@Test func acceptedExamplesSkipHoursNearACorrection() {
    let c = correction(10_000, to: .dark)
    let samples = (0..<10).map { sample(Double($0) * 3600, lux: 20) }  // hourly, t = 0…32400
    let ex = examples(corrections: [c], samples: samples)
    #expect(ex.filter(\.isCorrection).count == 1)
    // 10 hours, minus the ones within an hour of t = 10000 (7200 and 10800).
    #expect(ex.filter { !$0.isCorrection }.count == 8)
    #expect(ex.filter { !$0.isCorrection }.allSatisfy { !$0.dark && $0.weight < 1 })
}

@Test func linearSolve() throws {
    let x = try #require(Trainer.solve([[2, 1], [1, 3]], [3, 5]))
    #expect(abs(x[0] - 0.8) < 1e-9 && abs(x[1] - 1.4) < 1e-9)
    #expect(Trainer.solve([[1, 2], [2, 4]], [1, 2]) == nil)
}

// MARK: weather

@Test func parsesOpenMeteo() throws {
    let json = #"{"minutely_15":{"time":["2026-10-21T15:00","2026-10-21T15:15"],"shortwave_radiation":[61.0,null],"diffuse_radiation":[50.0,40.0],"cloud_cover":[86,89]}}"#
    let s = try Weather.parse(Data(json.utf8))
    #expect(s.count == 1)
    #expect(s[0].sample.shortwave == 61)
    #expect(s[0].sample.cloudCover == 86)
    #expect(s[0].time == ISO8601DateFormatter().date(from: "2026-10-21T15:00:00Z"))
}
