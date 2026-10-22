import Foundation
import Testing
@testable import DuskCore

private func sensors(_ lux: [Double]) -> [SensorSample] {
    lux.enumerated().map { SensorSample(key: "s\($0.offset)", lux: $0.element, kelvin: nil) }
}

private func appearanceProbe(_ t: Double, to: Appearance, b: Double, before: [Double], after: [Double]) -> Probe {
    Probe(time: Date(timeIntervalSince1970: t), kind: .appearance,
          fromAppearance: to == .dark ? .light : .dark, toAppearance: to,
          fromBrightness: b, toBrightness: b, before: sensors(before), after: sensors(after),
          settleSeconds: 1.5)
}

private func brightnessProbe(_ t: Double, in a: Appearance, from: Double, to: Double,
                             before: [Double], after: [Double]) -> Probe {
    Probe(time: Date(timeIntervalSince1970: t), kind: .brightness, fromAppearance: a, toAppearance: a,
          fromBrightness: from, toBrightness: to, before: sensors(before), after: sensors(after),
          settleSeconds: 1.5)
}

// The real 17:43 switch: light→dark at 90%, then dark 90%→46%.
private let evening = appearanceProbe(0, to: .dark, b: 0.9, before: [11.2, 9.7], after: [3.7, 1.9])
private let dimming = brightnessProbe(60, in: .dark, from: 0.9, to: 0.46, before: [3.7, 1.9], after: [3.0, 1.0])

@Test func appearanceProbeIsLightMinusDarkPerUnitBrightness() throws {
    #expect(abs(try #require(evening.perUnitBrightness("s0")) - 7.5 / 0.9) < 1e-9)
    // The same difference measured switching the other way gives the same sign.
    let morning = appearanceProbe(0, to: .light, b: 0.44, before: [2.4], after: [6.1])
    #expect(abs(try #require(morning.perUnitBrightness("s0")) - 3.7 / 0.44) < 1e-9)
}

@Test func brightnessProbeIsTheSlope() throws {
    #expect(abs(try #require(dimming.perUnitBrightness("s1")) - (-0.9 / -0.44)) < 1e-9)
}

@Test func probesThatChangedTwoThingsAreUnusable() {
    var p = evening
    p.toBrightness = 0.5  // brightness moved during an appearance switch
    #expect(p.perUnitBrightness("s0") == nil)
    var q = dimming
    q.toBrightness = 0.85  // too small a step to read a slope from
    #expect(q.perUnitBrightness("s0") == nil)
}

@Test func estimatesDeriveTheMissingGain() throws {
    let est = ScreenLight.estimate([evening, dimming])
    let s1 = try #require(est.first { $0.key == "s1" })
    let delta = 7.8 / 0.9, dark = 0.9 / 0.44
    #expect(abs(try #require(s1.delta) - delta) < 1e-9)
    #expect(abs(try #require(s1.darkGain) - dark) < 1e-9)
    #expect(abs(try #require(s1.lightGain) - (dark + delta)) < 1e-9)  // derived
    #expect(s1.probes == 2)
}

@Test func estimatesUseTheMedianOfRecentProbes() throws {
    let odd = appearanceProbe(-100, to: .dark, b: 0.9, before: [50], after: [3.7])  // a lamp went out too
    let ok1 = appearanceProbe(-50, to: .dark, b: 0.9, before: [11.2], after: [3.7])
    let est = ScreenLight.estimate([odd, ok1, evening])
    #expect(abs(try #require(est.first?.delta) - 7.5 / 0.9) < 1e-9)
}

@Test func roomLuxSubtractsTheScreens() throws {
    var s = Sample(time: .now, sensors: sensors([11.2, 9.7]), screenBrightness: 0.9, appearance: .light)
    s.screenLight = ScreenLight.estimate([evening, dimming])
    let room = s.roomLux
    // s1 in light mode at 90%: 9.7 − (2.05 + 8.67) × 0.9 = 0.05 lx. The evening room really was dark.
    #expect(try #require(room["s1"]) < 0.5)
    let f = s.features
    #expect(f["log room lux s1"] != nil)
    #expect(f["screen delta s0"] != nil)
    #expect(try #require(f["light screen share median"]) > 0.8)
    #expect(f.keys.allSatisfy { !$0.contains("gain") })  // would reveal the appearance
}

@Test func roomLuxAgreesAcrossTheSwitch() throws {
    let est = ScreenLight.estimate([evening, dimming])
    var before = Sample(time: .now, sensors: sensors([11.2, 9.7]), screenBrightness: 0.9, appearance: .light)
    var after = Sample(time: .now, sensors: sensors([3.7, 1.9]), screenBrightness: 0.9, appearance: .dark)
    before.screenLight = est
    after.screenLight = est
    // The point of the correction: the room did not change when the screens did.
    #expect(abs(try #require(before.roomLux["s0"]) - after.roomLux["s0"]!) < 0.01)
}

@Test func backfillFindsCleanSwitchesInMinuteSamples() {
    func s(_ t: Double, _ a: Appearance, _ b: Double, _ lux: [Double]) -> Sample {
        Sample(time: Date(timeIntervalSince1970: t), sensors: sensors(lux), screenBrightness: b, appearance: a)
    }
    let samples = [
        s(0, .light, 0.90, [11.2]), s(60, .dark, 0.90, [3.7]),   // appearance only: probe
        s(180, .dark, 0.46, [3.0]),                             // brightness only, 120 s: probe
        s(240, .light, 0.80, [12]),                             // both changed: no probe
        s(1000, .light, 0.40, [5]),                             // too long after: no probe
    ]
    let p = ScreenLight.backfill(samples)
    #expect(p.map(\.kind) == [.appearance, .brightness])
    #expect(p.allSatisfy { $0.source == "backfill" && $0.settleSeconds == nil })
}

@Test func probesRoundTripThroughJSON() throws {
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
    let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
    #expect(try d.decode(Probe.self, from: e.encode(evening)) == evening)
}

@Test func liveProbesReplaceBackfilledOnes() throws {
    var old = appearanceProbe(-100, to: .dark, b: 0.9, before: [30], after: [3])
    old.source = "backfill"
    #expect(abs(try #require(ScreenLight.estimate([old]).first?.delta) - 27 / 0.9) < 1e-9)
    #expect(abs(try #require(ScreenLight.estimate([old, evening]).first?.delta) - 7.5 / 0.9) < 1e-9)
}
