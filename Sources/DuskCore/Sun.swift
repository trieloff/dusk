import Foundation

/// Solar position from the NOAA spreadsheet equations
/// (https://gml.noaa.gov/grad/solcalc/calcdetails.html). Accurate to about a
/// minute for sunrise and sunset, which is all a dark-mode switch needs, and
/// it needs neither the network nor the Weather app.
public struct Sun: Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Solar elevation in degrees (uncorrected for refraction) at `date`.
    public func elevation(at date: Date) -> Double {
        let p = position(julianCentury(date))
        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        var trueSolarTime = (minutesUTC + p.equationOfTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }
        let hourAngle = trueSolarTime / 4 - 180
        let lat = rad(latitude), decl = rad(p.declination)
        let cosZenith = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(rad(hourAngle))
        return 90 - deg(acos(min(1, max(-1, cosZenith))))
    }

    public func isUp(at date: Date, threshold: Double = -0.833) -> Bool {
        elevation(at: date) > threshold
    }

    /// Whether the sun is climbing (morning) rather than sinking (afternoon).
    public func isRising(at date: Date) -> Bool {
        elevation(at: date.addingTimeInterval(300)) > elevation(at: date)
    }

    /// Up or down with separate morning and evening thresholds.
    public func isUp(at date: Date, morning: Double, evening: Double) -> Bool {
        elevation(at: date) > (isRising(at: date) ? morning : evening)
    }

    /// Times today (UTC day containing `date`) when the sun crosses `threshold`
    /// rising and setting; nil during polar day or night.
    public func crossings(on date: Date, threshold: Double = -0.833) -> (rise: Date, set: Date)? {
        let dayStart = Date(timeIntervalSince1970:
            (date.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
        var noonMinutes = 720.0
        var result: (Double, Double)?
        // Two passes: the second recomputes at the first estimate of noon.
        for _ in 0..<2 {
            let p = position(julianCentury(dayStart.addingTimeInterval(noonMinutes * 60)))
            noonMinutes = 720 - 4 * longitude - p.equationOfTime
            let lat = rad(latitude), decl = rad(p.declination)
            let cosH = (cos(rad(90 - threshold)) - sin(lat) * sin(decl)) / (cos(lat) * cos(decl))
            guard (-1...1).contains(cosH) else { return nil }
            let h = deg(acos(cosH))
            result = (noonMinutes - 4 * h, noonMinutes + 4 * h)
        }
        guard let (rise, set) = result else { return nil }
        return (dayStart.addingTimeInterval(rise * 60), dayStart.addingTimeInterval(set * 60))
    }

    private struct Position { let declination: Double; let equationOfTime: Double }

    private func julianCentury(_ date: Date) -> Double {
        (date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545) / 36525
    }

    private func position(_ t: Double) -> Position {
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(rad(3 * m)) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(omega))
        let meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(obliq)) * sin(rad(appLong))))
        let y = pow(tan(rad(obliq / 2)), 2)
        let eot = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m))
            + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        return Position(declination: decl, equationOfTime: eot)
    }
}

@inline(__always) private func rad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) private func deg(_ r: Double) -> Double { r * 180 / .pi }
