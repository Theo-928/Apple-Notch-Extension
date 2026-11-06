import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var google: GoogleStore
    @ObservedObject var weather: WeatherStore
    var previewLockScreen: () -> Void = {}

    @StateObject private var cityQuery = Box("")
    @StateObject private var cityResults = Box<[WeatherStore.Place]>([])
    @StateObject private var citySearchMessage = Box<String?>(nil)

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            lockScreen.tabItem { Label("Lock Screen", systemImage: "lock.display") }
            googleTab.tabItem { Label("Google", systemImage: "calendar") }
            privacy.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 470)
        .padding()
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if let msg = settings.launchAtLoginMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open the notch when dragging files to it", isOn: $settings.expandOnFileDrag)
                Toggle("Show battery next to the notch", isOn: $settings.showBatteryInNotch)
                Toggle("Haptic feedback on open (Force Touch trackpads)", isOn: $settings.hapticFeedback)
                HStack {
                    Text("Hover delay")
                    Slider(value: $settings.hoverDelay, in: 0...0.8)
                    Text("\(Int(settings.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Section("Now Playing") {
                Toggle("Show Now Playing from any app (browsers, Podcasts, …)", isOn: $settings.extendedNowPlaying)
                    .disabled(!MediaBridgeClient.isAvailable)
                Text("Off by default. Since macOS 15.4, Apple only shares system-wide Now Playing info with its own apps. This option runs a small bundled helper inside the built-in /usr/bin/perl to read it. It's an unofficial technique: it can break after macOS updates, and your organization's IT policy may not allow it. When off, Spotify and Apple Music still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Toggle("Keep clipboard history (memory only)", isOn: $settings.clipboardHistoryEnabled)
                Text("Off by default. Nothing is written to disk and copies marked as passwords are skipped. On recent macOS versions, turning this on may show a one-time pasteboard prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lock") {
                Toggle("Require Touch ID to open Clipboard and Terminal", isOn: $settings.lockSensitiveTabs)
                Text("Uses the system Touch ID sheet (or your login password if Touch ID isn't set up) — the same one 1Password uses. Notchling never sees your fingerprint. The tabs re-lock shortly after the notch closes. Needs no permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Lock Screen

    private var lockScreen: some View {
        Form {
            Section {
                Toggle("Show widgets on the lock screen", isOn: $settings.lockScreenWidgets)
                    .disabled(!LockScreenController.isSupported)
                if LockScreenController.isSupported {
                    Toggle("Weather", isOn: $settings.lockScreenWeather).disabled(!settings.lockScreenWidgets)
                    Toggle("Now Playing (with play/pause controls)", isOn: $settings.lockScreenMedia).disabled(!settings.lockScreenWidgets)
                    Toggle("Battery", isOn: $settings.lockScreenBattery).disabled(!settings.lockScreenWidgets)
                    Toggle("Next calendar event", isOn: $settings.lockScreenCalendar).disabled(!settings.lockScreenWidgets)
                    HStack {
                        Button("Preview") { previewLockScreen() }
                        Text("Shows the widgets on your desktop for 8 seconds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("This version of macOS doesn't support lock-screen widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Anyone who can see your locked Mac can see these widgets and use the music controls. The calendar is off by default so meeting titles stay private. A running timer always shows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Weather") {
                LabeledContent("Location") {
                    if let place = weather.place {
                        Text([place.name, place.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Search for a city", text: $cityQuery.value)
                        .onSubmit(searchCity)
                    Button("Search", action: searchCity)
                        .disabled(cityQuery.value.trimmingCharacters(in: .whitespaces).count < 2)
                }
                if let msg = citySearchMessage.value {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cityResults.value) { place in
                    Button {
                        weather.setPlace(place)
                        cityResults.value = []
                        cityQuery.value = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name)
                            Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Picker("Units", selection: $settings.temperatureUnit) {
                    Text("Automatic").tag("auto")
                    Text("°F").tag("f")
                    Text("°C").tag("c")
                }
                .onChange(of: settings.temperatureUnit) { _ in weather.unitsChanged() }
                Text("From Open-Meteo, free with no account. You pick the city, so Notchling never asks for Location Services. Until you pick one it's guessed from your time zone. Only the city's coordinates are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func searchCity() {
        let query = cityQuery.value
        citySearchMessage.value = "Searching…"
        Task {
            do {
                let results = try await WeatherStore.search(query)
                cityResults.value = results
                citySearchMessage.value = results.isEmpty ? "No places found." : nil
            } catch {
                citySearchMessage.value = error.localizedDescription
            }
        }
    }

    // MARK: Google

    private var googleTab: some View {
        Form {
            Section("Account") {
                switch google.status {
                case .signedIn(let email):
                    LabeledContent("Signed in as", value: email)
                    HStack {
                        Button("Refresh now") { Task { await google.refresh() } }
                        Button("Sign out", role: .destructive) { Task { await google.signOut() } }
                    }
                case .signingIn:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to finish in the browser…")
                        Spacer()
                        Button("Cancel") { google.cancelSignIn() }
                    }
                case .signedOut, .notConfigured:
                    Button("Sign in with Google") { Task { await google.signIn() } }
                        .disabled(settings.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = google.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Features") {
                Toggle("Google Calendar (always on, read-only)", isOn: .constant(true)).disabled(true)
                Toggle("Gmail unread messages (read-only)", isOn: $settings.gmailEnabled)
                Toggle("Google Tasks", isOn: $settings.tasksEnabled)
                Text("Changing these asks for the matching Google scopes the next time you sign in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OAuth client") {
                TextField("Client ID", text: $settings.googleClientID)
                    .onChange(of: settings.googleClientID) { _ in google.updateStatus() }
                SecureField("Client secret", text: $settings.googleClientSecret)
                DisclosureGroup("How to get these (5 minutes, one time)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open Google Cloud Console and create (or pick) a project.")
                        Text("2. Enable the Google Calendar API, Gmail API and Tasks API.")
                        Text("3. OAuth consent screen → External (or Internal for Workspace), add yourself as a test user.")
                        Text("4. Credentials → Create credentials → OAuth client ID → type **Desktop app**.")
                        Text("5. Paste the client ID and secret here, then Sign in.")
                        Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Permissions

    private var privacy: some View {
        Form {
            Section {
                Text("Notchling is designed to work on managed Macs: it asks for **no** macOS privacy permissions.")
            }
            Section("How each feature avoids a permission") {
                row("Hover to open", "Mouse-only event monitor", "Accessibility")
                row("Now Playing", "Spotify / Music broadcast notifications + MediaRemote (optional helper for all apps)", "Automation, Accessibility")
                row("Terminal", "Your login shell on a pseudo-terminal. Commands you run may trigger their own folder prompts, e.g. `ls ~/Documents`", "—")
                row("Keep awake", "IOKit power assertions; closed-lid mode uses pmset with an admin password", "—")
                row("File shelf", "Drag-and-drop file references", "Files & Folders, Full Disk")
                row("Calendar / Tasks", "Google APIs over HTTPS", "Calendars, Reminders")
                row("Timer alerts", "Shown in the notch with a sound", "Notifications")
                row("Battery", "IOKit power-source API", "—")
                row("Weather", "City you choose + Open-Meteo over HTTPS", "Location Services")
                row("Lock-screen widgets", "Lock/unlock notifications + a window placed above the lock screen", "Accessibility")
                row("Clipboard", "Opt-in, memory-only", "—")
            }
            Section("Not included on purpose") {
                Text("Camera mirror (Camera), volume/brightness HUD replacement (Accessibility), Bluetooth device alerts (Bluetooth). These each need a permission an IT admin can block.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ feature: String, _ how: String, _ avoided: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(feature).fontWeight(.semibold)
            Text(how).font(.caption)
            Text("Avoids: \(avoided)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
