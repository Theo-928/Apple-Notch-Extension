import Foundation
import ServiceManagement

/// User preferences. Everything here lives in UserDefaults; no secrets.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// Clipboard history is opt-in: on recent macOS versions reading the
    /// pasteboard in the background can trigger the "paste from other apps"
    /// privacy prompt, so we never touch it unless the user asks.
    @Published var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: "clipboardHistoryEnabled") }
    }
    /// Opt-in: Now Playing from any app via the bundled MediaRemote helper.
    @Published var extendedNowPlaying: Bool {
        didSet { defaults.set(extendedNowPlaying, forKey: "extendedNowPlaying") }
    }
    /// Require Touch ID (or the login password) to open Clipboard and Terminal.
    @Published var lockSensitiveTabs: Bool {
        didSet { defaults.set(lockSensitiveTabs, forKey: "lockSensitiveTabs") }
    }
    /// Widgets (weather, Now Playing, battery, …) on the lock screen.
    @Published var lockScreenWidgets: Bool {
        didSet { defaults.set(lockScreenWidgets, forKey: "lockScreenWidgets") }
    }
    @Published var lockScreenWeather: Bool {
        didSet { defaults.set(lockScreenWeather, forKey: "lockScreenWeather") }
    }
    @Published var lockScreenMedia: Bool {
        didSet { defaults.set(lockScreenMedia, forKey: "lockScreenMedia") }
    }
    /// Off by default: meeting titles would be readable by anyone at your Mac.
    @Published var lockScreenCalendar: Bool {
        didSet { defaults.set(lockScreenCalendar, forKey: "lockScreenCalendar") }
    }
    @Published var lockScreenBattery: Bool {
        didSet { defaults.set(lockScreenBattery, forKey: "lockScreenBattery") }
    }
    /// "auto" (from your region), "c" or "f".
    @Published var temperatureUnit: String {
        didSet { defaults.set(temperatureUnit, forKey: "temperatureUnit") }
    }
    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: "hoverDelay") }
    }
    @Published var expandOnFileDrag: Bool {
        didSet { defaults.set(expandOnFileDrag, forKey: "expandOnFileDrag") }
    }
    @Published var showBatteryInNotch: Bool {
        didSet { defaults.set(showBatteryInNotch, forKey: "showBatteryInNotch") }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var googleClientID: String {
        didSet { defaults.set(googleClientID, forKey: "googleClientID") }
    }
    /// Google issues a "secret" for Desktop OAuth clients, but documents that it
    /// is not confidential for installed apps. Kept in defaults for that reason;
    /// the actual refresh token goes to the Keychain.
    @Published var googleClientSecret: String {
        didSet { defaults.set(googleClientSecret, forKey: "googleClientSecret") }
    }
    @Published var gmailEnabled: Bool {
        didSet { defaults.set(gmailEnabled, forKey: "gmailEnabled") }
    }
    @Published var tasksEnabled: Bool {
        didSet { defaults.set(tasksEnabled, forKey: "tasksEnabled") }
    }

    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginMessage: String?

    private init() {
        defaults.register(defaults: [
            "clipboardHistoryEnabled": false,
            "extendedNowPlaying": false,
            "lockSensitiveTabs": false,
            "lockScreenWidgets": true,
            "lockScreenWeather": true,
            "lockScreenMedia": true,
            "lockScreenCalendar": false,
            "lockScreenBattery": true,
            "temperatureUnit": "auto",
            "hoverDelay": 0.15,
            "expandOnFileDrag": true,
            "showBatteryInNotch": false,
            "hapticFeedback": true,
            "gmailEnabled": true,
            "tasksEnabled": true,
        ])
        clipboardHistoryEnabled = defaults.bool(forKey: "clipboardHistoryEnabled")
        extendedNowPlaying = defaults.bool(forKey: "extendedNowPlaying")
        lockSensitiveTabs = defaults.bool(forKey: "lockSensitiveTabs")
        lockScreenWidgets = defaults.bool(forKey: "lockScreenWidgets")
        lockScreenWeather = defaults.bool(forKey: "lockScreenWeather")
        lockScreenMedia = defaults.bool(forKey: "lockScreenMedia")
        lockScreenCalendar = defaults.bool(forKey: "lockScreenCalendar")
        lockScreenBattery = defaults.bool(forKey: "lockScreenBattery")
        temperatureUnit = defaults.string(forKey: "temperatureUnit") ?? "auto"
        hoverDelay = defaults.double(forKey: "hoverDelay")
        expandOnFileDrag = defaults.bool(forKey: "expandOnFileDrag")
        showBatteryInNotch = defaults.bool(forKey: "showBatteryInNotch")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        googleClientID = defaults.string(forKey: "googleClientID") ?? ""
        googleClientSecret = defaults.string(forKey: "googleClientSecret") ?? ""
        gmailEnabled = defaults.bool(forKey: "gmailEnabled")
        tasksEnabled = defaults.bool(forKey: "tasksEnabled")
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Uses SMAppService (a Login Item). This is not a privacy permission, but a
    /// managed Mac can disallow it via MDM — in that case we just report it.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = "macOS refused: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}
