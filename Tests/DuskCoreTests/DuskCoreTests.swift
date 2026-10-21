import Foundation
import Testing
@testable import DuskCore

// MARK: verdicts

@Test func ambientThresholdsWithHysteresisBand() {
    func v(_ lux: Double?) -> Appearance? {
        verdict(source: .ambient, lux: lux, sunUp: true, darkBelow: 8, lightAbove: 15)
    }
    #expect(v(3) == .dark)
    #expect(v(30) == .light)
    #expect(v(10) == nil)  // inside the band: keep
    #expect(v(nil) == .light)  // no sensor: the sun decides
}

@Test func sunSourceIgnoresTheRoom() {
    #expect(verdict(source: .sun, lux: 2, sunUp: true, darkBelow: 8, lightAbove: 15) == .light)
    #expect(verdict(source: .sun, lux: 500, sunUp: false, darkBelow: 8, lightAbove: 15) == .dark)
    #expect(verdict(source: .sun, lux: 500, sunUp: nil, darkBelow: 8, lightAbove: 15) == nil)
}

@Test func eitherIsDarkWhenTheSunIsDownOrTheRoomIsDark() {
    #expect(verdict(source: .either, lux: 500, sunUp: false, darkBelow: 8, lightAbove: 15) == .dark)
    #expect(verdict(source: .either, lux: 2, sunUp: true, darkBelow: 8, lightAbove: 15) == .dark)
    #expect(verdict(source: .either, lux: 30, sunUp: true, darkBelow: 8, lightAbove: 15) == .light)
}

// MARK: decider

@Test func firstDecisionIsImmediate() {
    var d = AppearanceDecider(hold: 180)
    #expect(d.update(.dark, now: Date(timeIntervalSince1970: 0)) == .dark)
}

@Test func aNewVerdictMustHoldBeforeItWins() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = AppearanceDecider(current: .light, hold: 180)
    #expect(d.update(.dark, now: t0) == nil)
    #expect(d.update(.dark, now: t0 + 179) == nil)
    #expect(d.update(.dark, now: t0 + 180) == .dark)
    #expect(d.current == .dark)
}

@Test func aBriefDipResetsTheHold() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = AppearanceDecider(current: .light, hold: 180)
    _ = d.update(.dark, now: t0)
    _ = d.update(.light, now: t0 + 100)  // someone moved out of the way
    #expect(d.update(.dark, now: t0 + 200) == nil)  // the clock restarted at 200
    #expect(d.update(.dark, now: t0 + 380) == .dark)
}

@Test func theBandKeepsThePendingSwitch() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = AppearanceDecider(current: .light, hold: 180)
    _ = d.update(.dark, now: t0)
    _ = d.update(nil, now: t0 + 60)
    #expect(d.pending == nil)
}

@Test func aManualSwitchStandsUntilTheVerdictChanges() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = AppearanceDecider(hold: 0)
    #expect(d.update(.light, now: t0) == .light)
    d.observe(.dark)  // the user picked dark mode at noon
    #expect(d.update(.light, now: t0 + 600) == nil)
    #expect(d.update(.light, now: t0 + 6000) == nil)
    // Evening: the verdict moves to dark, which is already in effect.
    #expect(d.update(.dark, now: t0 + 30000) == nil)
    // Next morning dusk is back in charge.
    #expect(d.update(.light, now: t0 + 80000) == .light)
}

// MARK: brightness

@Test func curveIsLogarithmicAndClamped() {
    let c = BrightnessCurve(minLux: 1, maxLux: 100, minimum: 0.4, maximum: 1)
    #expect(c.brightness(forLux: 0.2) == 0.4)
    #expect(c.brightness(forLux: 500) == 1)
    #expect(abs(c.brightness(forLux: 10) - 0.7) < 1e-9)  // halfway in log space
}

@Test func darkModeLowersTheCurveCeiling() {
    var b = BrightnessConfig()
    b.darkMaximum = 0.6
    #expect(b.curve(for: .light).brightness(forLux: 100) == 1.0)
    #expect(b.curve(for: .dark).brightness(forLux: 100) == 0.6)
    #expect(b.curve(for: .dark).brightness(forLux: 0.1) == b.minimum)
    b.darkMaximum = nil
    #expect(b.curve(for: .dark).brightness(forLux: 100) == 1.0)
}

@Test func smootherStartsAtTheFirstSample() {
    var s = Smoother(alpha: 0.5)
    #expect(s.add(10) == 10)
    #expect(s.add(20) == 15)
}

@Test func medianOfEvenAndOdd() {
    #expect(median([3, 1, 2]) == 2)
    #expect(median([4, 1, 3, 2]) == 2.5)
    #expect(median([]) == nil)
}

@Test func hidUnitExponentNibble() {
    #expect(AmbientLightSensors.unitExponent(0xD) == -3)
    #expect(AmbientLightSensors.unitExponent(0x8) == -8)
    #expect(AmbientLightSensors.unitExponent(0x2) == 2)
}

// MARK: sun

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private let potsdam = Sun(latitude: 52.3893, longitude: 13.1229)

/// Reference times from an independent implementation (the USNO "Almanac for
/// Computers" sunrise algorithm), rounded to the minute.
@Test(arguments: [
    ("2026-06-21T12:00:00Z", "2026-06-21T02:45:00Z", "2026-06-21T19:34:00Z"),
    ("2026-12-21T12:00:00Z", "2026-12-21T07:15:00Z", "2026-12-21T14:56:00Z"),
    ("2026-03-20T12:00:00Z", "2026-03-20T05:11:00Z", "2026-03-20T17:20:00Z"),
])
func sunriseAndSunsetWithinThreeMinutes(day: String, rise: String, set: String) throws {
    let c = try #require(potsdam.crossings(on: utc(day)))
    #expect(abs(c.rise.timeIntervalSince(utc(rise))) < 180, "rise \(c.rise)")
    #expect(abs(c.set.timeIntervalSince(utc(set))) < 180, "set \(c.set)")
}

@Test func elevationAgreesWithCrossings() throws {
    let c = try #require(potsdam.crossings(on: utc("2026-10-21T12:00:00Z")))
    #expect(abs(potsdam.elevation(at: c.rise) - -0.833) < 0.1)
    #expect(potsdam.isUp(at: utc("2026-10-21T11:00:00Z")))
    #expect(!potsdam.isUp(at: utc("2026-10-21T21:00:00Z")))
}

@Test func eveningCanStartBeforeSunset() {
    // 21 Oct: the sun is at about 7° around 15:00 UTC and sets near 16:00 UTC.
    let afternoon = utc("2026-10-21T15:05:00Z"), morning = utc("2026-10-21T06:15:00Z")
    #expect(!potsdam.isRising(at: afternoon))
    #expect(potsdam.isRising(at: morning))
    #expect(!potsdam.isUp(at: afternoon, morning: -0.833, evening: 8))
    #expect(potsdam.isUp(at: afternoon, morning: -0.833, evening: -0.833))
    // Morning at the same height counts as day: only the evening moved.
    let am = potsdam.elevation(at: morning)
    #expect(am > -0.833 && am < 8)
    #expect(potsdam.isUp(at: morning, morning: -0.833, evening: 8))
}

@Test func sunThresholdsFallBackToSunElevation() {
    var c = Config()
    c.sunElevation = -6
    #expect(c.sunThreshold(rising: true) == -6)
    c.eveningSunElevation = 8
    #expect(c.sunThreshold(rising: false) == 8)
    #expect(c.sunThreshold(rising: true) == -6)
}

@Test func polarNightHasNoCrossings() {
    let tromsø = Sun(latitude: 69.65, longitude: 18.96)
    #expect(tromsø.crossings(on: utc("2026-12-21T12:00:00Z")) == nil)
}

// MARK: config

@Test func partialConfigKeepsDefaults() throws {
    let c = try JSONDecoder().decode(Config.self, from: Data(#"{"darkBelowLux": 5, "brightness": {"mode": "fixed"}}"#.utf8))
    #expect(c.darkBelowLux == 5)
    #expect(c.lightAboveLux == Config().lightAboveLux)
    #expect(c.brightness.mode == .fixed)
    #expect(c.brightness.light == 1.0)
}

@Test func invalidConfigIsRejected() {
    var c = Config()
    c.darkBelowLux = 20
    c.lightAboveLux = 10
    #expect(throws: Config.Invalid.self) { try c.validate() }
    c = Config()
    c.latitude = 52
    #expect(throws: Config.Invalid.self) { try c.validate() }
}
