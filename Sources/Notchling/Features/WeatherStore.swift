import Foundation

/// Weather from Open-Meteo (free, no API key, no account).
///
/// Avoids the Location Services permission: you pick a city in Settings. Until
/// you do, the city is guessed from your Mac's time zone (e.g. America/New_York
/// → New York). Only the city's coordinates are sent to Open-Meteo.
@MainActor
final class WeatherStore: ObservableObject {
    struct Place: Codable, Equatable, Identifiable {
        var name: String
        var region: String?
        var country: String?
        var latitude: Double
        var longitude: Double
        var id: String { "\(latitude),\(longitude)" }
        var subtitle: String { [region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    struct Hour: Identifiable, Equatable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var id: Date { time }
    }

    struct Report: Equatable {
        let temperature: Double
        let feelsLike: Double
        let code: Int
        let isDay: Bool
        let high: Double
        let low: Double
        let hours: [Hour]
        let fetched: Date
    }

    @Published private(set) var place: Place?
    @Published private(set) var report: Report?
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private let settings: AppSettings
    private var timer: Timer?
    private let placeKey = "weatherPlace"

    init(settings: AppSettings) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: placeKey),
           let saved = try? JSONDecoder().decode(Place.self, from: data) {
            place = saved
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
    }

    var usesFahrenheit: Bool {
        switch settings.temperatureUnit {
        case "f": return true
        case "c": return false
        default: return Locale.current.measurementSystem == .us
        }
    }

    func format(_ temperature: Double) -> String { "\(Int(temperature.rounded()))°" }

    /// Refreshes if the last report is older than 10 minutes (e.g. when the screen locks).
    func refreshIfStale() {
        guard !isLoading else { return }
        if let report, Date().timeIntervalSince(report.fetched) < 600 { return }
        Task { await refresh() }
    }

    func setPlace(_ newPlace: Place) {
        place = newPlace
        if let data = try? JSONEncoder().encode(newPlace) { UserDefaults.standard.set(data, forKey: placeKey) }
        report = nil
        Task { await refresh() }
    }

    func unitsChanged() {
        report = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if place == nil, let guess = Self.cityFromTimeZone() {
                place = try await Self.search(guess).first
            }
            guard let place else { lastError = "Pick a city in Settings → Lock Screen."; return }
            report = try await Self.forecast(for: place, fahrenheit: usesFahrenheit)
            lastError = nil
        } catch {
            lastError = "Weather unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: Open-Meteo

    static func search(_ query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: trimmed),
            .init(name: "count", value: "8"),
            .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let admin1: String?
                let country: String?
            }
            let results: [Result]?
        }
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.results ?? []).map {
            Place(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func forecast(for place: Place, fahrenheit: Bool) async throws -> Report {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", place.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let weather_code: Int
                let is_day: Int
            }
            struct Hourly: Decodable {
                let time: [TimeInterval]
                let temperature_2m: [Double?]
                let weather_code: [Int?]
                let is_day: [Int?]
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
            }
            let current: Current
            let hourly: Hourly
            let daily: Daily
        }
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let r = try JSONDecoder().decode(Response.self, from: data)

        let now = Date()
        var hours: [Hour] = []
        for i in r.hourly.time.indices {
            let time = Date(timeIntervalSince1970: r.hourly.time[i])
            guard time > now, let t = r.hourly.temperature_2m[i], let c = r.hourly.weather_code[i] else { continue }
            hours.append(Hour(time: time, temperature: t, code: c, isDay: (r.hourly.is_day[i] ?? 1) == 1))
            if hours.count == 5 { break }
        }
        return Report(temperature: r.current.temperature_2m,
                      feelsLike: r.current.apparent_temperature,
                      code: r.current.weather_code,
                      isDay: r.current.is_day == 1,
                      high: r.daily.temperature_2m_max.first.flatMap { $0 } ?? r.current.temperature_2m,
                      low: r.daily.temperature_2m_min.first.flatMap { $0 } ?? r.current.temperature_2m,
                      hours: hours,
                      fetched: now)
    }

    /// "America/New_York" → "New York". No permission, no network call.
    private static func cityFromTimeZone() -> String? {
        let id = TimeZone.current.identifier
        guard id.contains("/"), let last = id.split(separator: "/").last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: WMO weather codes

    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.rain.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61, 80: return "Light rain"
        case 63, 81: return "Rain"
        case 65, 82: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 85: return "Light snow"
        case 73, 75, 86: return "Snow"
        case 77: return "Snow grains"
        case 95: return "Thunderstorms"
        case 96, 99: return "Storms with hail"
        default: return "—"
        }
    }
}
