import Foundation
import IOKit.hid

/// One ambient light sensor's reading.
public struct LightReading: Sendable, Equatable {
    /// IOKit location ID of the sensor's device; each Studio Display has its own.
    public let locationID: Int
    public let product: String
    public let lux: Double
    /// Correlated colour temperature, when the sensor reports one.
    public let kelvin: Double?
}

/// Ambient light sensors that present as HID sensor-page devices — the Studio
/// Display has one (the True Tone / auto-brightness sensor), and so do some
/// other displays. Public IOKit API: no private frameworks, no entitlements.
public final class AmbientLightSensors: @unchecked Sendable {
    // HID Usage Tables, Sensors page (0x20).
    static let sensorPage: UInt32 = 0x20
    static let ambientLight: UInt32 = 0x41
    static let illuminance: UInt32 = 0x4D1
    static let colorTemperature: UInt32 = 0x4D2
    // IOHIDDevice.h: issue a GET_REPORT so the value is fresh, not cached.
    static let getValueWithUpdate: IOOptionBits = 0x0002_0000

    private let manager: IOHIDManager
    private let opened: Bool

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDPrimaryUsagePageKey: Self.sensorPage,
            kIOHIDPrimaryUsageKey: Self.ambientLight,
        ] as CFDictionary)
        opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    deinit {
        if opened { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    /// Reads every sensor once. Sensors that fail to answer are skipped.
    public func read() -> [LightReading] {
        guard opened, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return devices.compactMap(read).sorted { $0.locationID < $1.locationID }
    }

    private func read(_ device: IOHIDDevice) -> LightReading? {
        let elements = IOHIDDeviceCopyMatchingElements(device, nil,
                                                       IOOptionBits(kIOHIDOptionsTypeNone))
            as? [IOHIDElement] ?? []
        func value(_ usage: UInt32) -> Double? {
            guard let e = elements.first(where: {
                IOHIDElementGetUsagePage($0) == Self.sensorPage
                    && IOHIDElementGetUsage($0) == usage
                    && IOHIDElementGetType($0) == kIOHIDElementTypeInput_Misc
            }) else { return nil }
            var v = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(nil, e, 0, 0))
            guard IOHIDDeviceGetValueWithOptions(device, e, &v, Self.getValueWithUpdate)
                    == kIOReturnSuccess else { return nil }
            let raw = Double(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))
            return raw * pow(10, Double(Self.unitExponent(IOHIDElementGetUnitExponent(e))))
        }
        guard let lux = value(Self.illuminance) else { return nil }
        let loc = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        return LightReading(locationID: loc, product: product, lux: lux,
                            kelvin: value(Self.colorTemperature))
    }

    /// HID unit exponents are a 4-bit two's-complement nibble: 0xD means 10⁻³.
    static func unitExponent(_ nibble: UInt32) -> Int {
        let n = Int(nibble & 0xF)
        return n > 7 ? n - 16 : n
    }
}
