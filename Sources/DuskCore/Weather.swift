import Foundation

/// Outdoor light from Open-Meteo (https://open-meteo.com): free, no API key,
/// 15-minute resolution. Shortwave radiation is sunlight on the ground with the
/// clouds already accounted for, which a sun angle alone cannot know.
public actor Weather {
    public let latitude: Double
    public let longitude: Double
    private var series: [(time: Date, sample: WeatherSample)] = []
    private var fetchedAt = Date.distantPast
    public private(set) var lastError: String?

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The conditions for the 15-minute slot containing `now`, refreshing the
    /// forecast at most every 15 minutes. Stale data (over two hours) is dropped.
    public func current(now: Date = Date()) async -> WeatherSample? {
        if now.timeIntervalSince(fetchedAt) > 900 { await refresh() }
        // Open-Meteo labels each value with the end of the period it averages.
        guard let slot = series.first(where: { $0.time >= now }) ?? series.last,
              abs(slot.time.timeIntervalSince(now)) < 7200 else { return nil }
        return slot.sample
    }

    private func refresh() async {
        fetchedAt = Date()
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "minutely_15", value: "shortwave_radiation,diffuse_radiation,cloud_cover"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "past_days", value: "1"),
            .init(name: "forecast_days", value: "2"),
        ]
        do {
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                lastError = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            series = try Self.parse(data)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func parse(_ data: Data) throws -> [(time: Date, sample: WeatherSample)] {
        struct Response: Decodable {
            struct M: Decodable {
                let time: [String]
                let shortwave_radiation: [Double?]
                let diffuse_radiation: [Double?]
                let cloud_cover: [Double?]
            }
            let minutely_15: M
        }
        let r = try JSONDecoder().decode(Response.self, from: data).minutely_15
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return r.time.indices.compactMap { i in
            guard let t = f.date(from: r.time[i]), let sw = r.shortwave_radiation[i] else { return nil }
            return (t, WeatherSample(shortwave: sw, diffuse: r.diffuse_radiation[i],
                                     cloudCover: r.cloud_cover[i], validAt: t))
        }
    }
}
