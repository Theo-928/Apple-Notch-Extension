import SwiftUI

/// The row of cards shown on the lock screen.
struct LockScreenWidgetsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var weather: WeatherStore
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var google: GoogleStore
    @EnvironmentObject var battery: BatteryMonitor
    @EnvironmentObject var timer: TimerStore

    private var nextEvent: GoogleStore.CalendarEvent? {
        guard case .signedIn = google.status else { return nil }
        return google.upcomingEvents.first { !$0.isAllDay && Calendar.current.isDateInToday($0.start) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if settings.lockScreenWeather { WeatherCard() }
            if settings.lockScreenMedia, media.track != nil { LockNowPlayingCard() }
            if settings.lockScreenCalendar, let nextEvent { LockEventCard(event: nextEvent) }
            if timer.isActive { LockTimerCard() }
            if settings.lockScreenBattery, battery.hasBattery { LockBatteryCard() }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: media.track?.title)
    }
}

// MARK: - Card chrome

private let cardHeight: CGFloat = 150

private struct Card<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: width, height: cardHeight, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

private struct CardLabel: View {
    let text: String
    let systemImage: String
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
    }
}

// MARK: - Weather

struct WeatherCard: View {
    @EnvironmentObject var weather: WeatherStore

    var body: some View {
        Card(width: 300) {
            if let report = weather.report {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            CardLabel(text: weather.place?.name ?? "Weather", systemImage: "location.fill")
                            Text(weather.format(report.temperature))
                                .font(.system(size: 40, weight: .medium, design: .rounded))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            WeatherIcon(code: report.code, isDay: report.isDay).font(.system(size: 26))
                            Text(WeatherStore.description(for: report.code))
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text("H:\(weather.format(report.high))  L:\(weather.format(report.low))")
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 0) {
                        ForEach(report.hours) { hour in
                            VStack(spacing: 4) {
                                Text(Self.hourFormatter.string(from: hour.time))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                                WeatherIcon(code: hour.code, isDay: hour.isDay).font(.system(size: 14))
                                    .frame(height: 16)
                                Text(weather.format(hour.temperature))
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel(text: "Weather", systemImage: "cloud.sun.fill")
                    Spacer()
                    Text(weather.lastError ?? "Loading…")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()
}

struct WeatherIcon: View {
    let code: Int
    let isDay: Bool
    var body: some View {
        Image(systemName: WeatherStore.symbol(for: code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
    }
}

// MARK: - Now Playing

private struct LockNowPlayingCard: View {
    @EnvironmentObject var media: MediaController

    var body: some View {
        Card(width: 320) {
            if let track = media.track {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ArtworkView(image: media.artwork, fallbackIcon: media.sourceAppIcon, cornerRadius: 10)
                            .frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(track.artist.isEmpty ? track.album : track.artist)
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        AudioBars(isPlaying: track.isPlaying).frame(width: 16, height: 12)
                    }
                    LockProgressBar()
                    HStack(spacing: 28) {
                        controlButton("backward.fill", size: 16) { media.previous() }
                        controlButton(track.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.togglePlayPause() }
                        controlButton("forward.fill", size: 16) { media.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LockProgressBar: View {
    @EnvironmentObject var media: MediaController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let duration = media.track?.duration ?? 0
            let elapsed = media.currentElapsed(at: ctx.date) ?? 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: duration > 0 ? geo.size.width * CGFloat(min(1, elapsed / duration)) : 0)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Calendar

private struct LockEventCard: View {
    let event: GoogleStore.CalendarEvent

    var body: some View {
        Card(width: 220) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(text: "Up next", systemImage: "calendar")
                Spacer(minLength: 0)
                Text(event.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(relative(at: ctx.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(event.start <= ctx.date ? .green : .white.opacity(0.7))
                }
                if event.meetingURL != nil {
                    Label("Video call", systemImage: "video.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                }
            }
        }
    }

    private func relative(at now: Date) -> String {
        if event.start <= now { return "Now · until \(event.end.shortTime)" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "in \(max(1, minutes)) min · \(event.start.shortTime)" }
        return "\(event.start.shortTime) – \(event.end.shortTime)"
    }
}

// MARK: - Timer

private struct LockTimerCard: View {
    @EnvironmentObject var timer: TimerStore
    var body: some View {
        Card(width: 160) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(text: timer.label, systemImage: timer.isPomodoro ? "brain.head.profile" : "timer")
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(timer.remaining(at: ctx.date).clockString)
                        .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(timer.isRunning ? .orange : .white.opacity(0.6))
                }
                Text(timer.isRunning ? "Running" : "Paused")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Battery

private struct LockBatteryCard: View {
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        Card(width: 150) {
            let level = battery.level ?? 0
            let tint: Color = battery.isCharging ? .green : (level <= 20 ? .red : .white)
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(level) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Image(systemName: battery.isCharging ? "bolt.fill" : "laptopcomputer")
                            .font(.system(size: 13)).foregroundStyle(tint)
                        Text("\(level)%").font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                .frame(width: 78, height: 78)
                Text(caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var caption: String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in" }
        if let m = battery.minutesRemaining, m > 0 { return "\(m / 60)h \(m % 60)m left" }
        return "On battery"
    }
}
