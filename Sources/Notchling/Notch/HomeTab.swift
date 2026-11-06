import SwiftUI

struct HomeTab: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var google: GoogleStore
    @EnvironmentObject var timer: TimerStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NowPlayingView()
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                WeatherLine()
                UpNextView()
                if timer.isActive { TimerMiniView() }
                Spacer(minLength: 0)
            }
            .frame(width: 190, alignment: .leading)
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var media: MediaController

    var body: some View {
        if let track = media.track {
            HStack(alignment: .center, spacing: 12) {
                ArtworkView(image: media.artwork, fallbackIcon: media.sourceAppIcon, cornerRadius: 12)
                    .frame(width: 92, height: 92)
                    .onTapGesture { media.openSourceApp() }
                    .help("Open player")
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    ProgressRow()
                    HStack(spacing: 6) {
                        IconButton(systemImage: "backward.fill", size: 15, help: "Previous") { media.previous() }
                        IconButton(systemImage: track.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                   help: track.isPlaying ? "Pause" : "Play") { media.togglePlayPause() }
                        IconButton(systemImage: "forward.fill", size: 15, help: "Next") { media.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            EmptyStateView(systemImage: "music.note",
                           title: "Nothing playing",
                           detail: "Play something in Spotify or Apple Music\nand it shows up here.")
        }
    }
}

private struct ProgressRow: View {
    @EnvironmentObject var media: MediaController

    var body: some View {
        if let duration = media.track?.duration, duration > 0, media.currentElapsed() != nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsed = media.currentElapsed(at: ctx.date) ?? 0
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * CGFloat(min(1, elapsed / duration)))
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            media.seek(to: duration * fraction)
                        })
                    }
                    .frame(height: 4)
                    HStack {
                        Text(elapsed.clockString)
                        Spacer()
                        Text("-" + (duration - elapsed).clockString)
                    }
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One-line weather summary at the top of the Home tab.
struct WeatherLine: View {
    @EnvironmentObject var weather: WeatherStore

    var body: some View {
        if let report = weather.report {
            HStack(spacing: 6) {
                WeatherIcon(code: report.code, isDay: report.isDay).font(.system(size: 13))
                Text(weather.format(report.temperature)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(WeatherStore.description(for: report.code))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
                Text("H:\(weather.format(report.high)) L:\(weather.format(report.low))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
            }
            .help(weather.place?.name ?? "")
        }
    }
}

struct UpNextView: View {
    @EnvironmentObject var google: GoogleStore
    @EnvironmentObject var actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Up next", systemImage: "calendar")
            switch google.status {
            case .signedIn:
                if let event = google.upcomingEvents.first(where: { !$0.isAllDay }) ?? google.upcomingEvents.first {
                    EventRow(event: event, prominent: true)
                } else {
                    Text("Nothing else today 🎉").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                if let unread = google.unreadCount {
                    Button { google.openInbox() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope.fill")
                            Text("\(unread) unread")
                        }
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            case .signingIn:
                Text("Finish signing in in your browser…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            case .signedOut, .notConfigured:
                Text("Connect Google to see your calendar, mail and tasks here.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                PillButton(title: "Connect", systemImage: "link") { actions.openSettings() }
            }
        }
    }
}

struct EventRow: View {
    let event: GoogleStore.CalendarEvent
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.system(size: prominent ? 13 : 12, weight: .semibold))
                .lineLimit(prominent ? 2 : 1)
            HStack(spacing: 6) {
                Text(timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(event.isOngoing ? .green : .white.opacity(0.55))
                if let url = event.meetingURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.green.opacity(0.25), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let link = event.htmlLink { NSWorkspace.shared.open(link) } }
    }

    private var timeText: String {
        if event.isAllDay {
            return Calendar.current.isDateInToday(event.start) ? "All day" : "Tomorrow · all day"
        }
        let prefix = Calendar.current.isDateInTomorrow(event.start) ? "Tomorrow " : ""
        if event.isOngoing { return "Now · until \(event.end.shortTime)" }
        return "\(prefix)\(event.start.shortTime) – \(event.end.shortTime)"
    }
}

struct TimerMiniView: View {
    @EnvironmentObject var timer: TimerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: timer.label, systemImage: "timer")
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(timer.remaining(at: ctx.date).clockString)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Spacer()
                IconButton(systemImage: timer.isRunning ? "pause.fill" : "play.fill", size: 11) {
                    timer.isRunning ? timer.pause() : timer.resume()
                }
                IconButton(systemImage: "xmark", size: 11) { timer.stop() }
            }
        }
    }
}
