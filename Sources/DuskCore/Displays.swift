import CoreGraphics
import Foundation

/// A connected display whose brightness macOS can drive (built-in panels,
/// Studio Display, Pro Display XDR). Third-party monitors only answer over
/// DDC/CI, which this does not speak.
public struct Display: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let isMain: Bool
    public let name: String
}

/// Brightness and auto-brightness through DisplayServices, the private
/// framework behind the brightness keys and System Settings. It has no public
/// replacement; the symbols are resolved at runtime so a future macOS that drops
/// one degrades to an error instead of a crash at launch.
public final class DisplayControl: @unchecked Sendable {
    public struct Unavailable: Error, CustomStringConvertible {
        public let description: String
    }

    private typealias GetFloat = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFloat = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBool = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SetBool = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private let getBrightness: GetFloat?
    private let setBrightness: SetFloat?
    private let canChange: Query?
    private let hasAuto: Query?
    private let autoEnabled: GetBool?
    private let enableAuto: SetBool?

    public init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                       RTLD_NOW)
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getBrightness = sym("DisplayServicesGetBrightness", GetFloat.self)
        setBrightness = sym("DisplayServicesSetBrightness", SetFloat.self)
        canChange = sym("DisplayServicesCanChangeBrightness", Query.self)
        hasAuto = sym("DisplayServicesHasAmbientLightCompensation", Query.self)
        autoEnabled = sym("DisplayServicesAmbientLightCompensationEnabled", GetBool.self)
        enableAuto = sym("DisplayServicesEnableAmbientLightCompensation", SetBool.self)
    }

    /// Online displays whose brightness can be changed.
    public func displays() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            .filter { canChange?($0) ?? false }
            .map { id in
                Display(id: id, isMain: CGDisplayIsMain(id) != 0,
                        name: Self.name(of: id))
            }
    }

    public func brightness(of id: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var b: Float = 0
        return getBrightness(id, &b) == 0 ? Double(b) : nil
    }

    public func setBrightness(_ value: Double, on id: CGDirectDisplayID) throws {
        guard let setBrightness else {
            throw Unavailable(description: "DisplayServicesSetBrightness is missing on this macOS")
        }
        let rc = setBrightness(id, Float(min(1, max(0, value))))
        if rc != 0 { throw Unavailable(description: "setting brightness on display \(id) failed (\(rc))") }
    }

    /// Ramps each display from its current level to its target together, so a
    /// change is a short fade rather than a jump.
    public func fade(_ targets: [(id: CGDirectDisplayID, to: Double)],
                     duration: TimeInterval = 0.8, steps: Int = 16) throws {
        let starts = targets.map { brightness(of: $0.id) ?? $0.to }
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            let eased = t * t * (3 - 2 * t)  // smoothstep
            for (n, target) in targets.enumerated() {
                try setBrightness(starts[n] + (target.to - starts[n]) * eased, on: target.id)
            }
            if i < steps { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }
    }

    /// Whether macOS's own auto-brightness is on, or nil if the display has none.
    public func autoBrightness(of id: CGDirectDisplayID) -> Bool? {
        guard hasAuto?(id) == true, let autoEnabled else { return nil }
        var on = false
        return autoEnabled(id, &on) == 0 ? on : nil
    }

    public func setAutoBrightness(_ on: Bool, on id: CGDirectDisplayID) throws {
        guard hasAuto?(id) == true else { return }
        guard let enableAuto else {
            throw Unavailable(description: "DisplayServicesEnableAmbientLightCompensation is missing")
        }
        let rc = enableAuto(id, on)
        if rc != 0 { throw Unavailable(description: "toggling auto-brightness on display \(id) failed (\(rc))") }
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let kind = vendor == 0x610 && model == 0xAE3A ? "Studio Display"
            : CGDisplayIsBuiltin(id) != 0 ? "Built-in" : "Display"
        return serial == 0 ? kind : "\(kind) \(String(serial, radix: 16, uppercase: true))"
    }
}
