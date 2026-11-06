import AppKit
import Combine
import Foundation

/// Now Playing without Accessibility, Automation (AppleScript) or any other
/// privacy permission.
///
/// Track info comes from:
///  1. Distributed notifications that Spotify and Apple Music broadcast to every
///     process on each state change (no permission needed to listen).
///  2. The MediaRemote framework, when the OS still answers this process
///     (macOS ≤ 15.3 answers everyone; newer versions only answer Apple apps,
///     in which case we silently rely on #1).
///  3. Opt-in only: `MediaBridgeClient` (Settings → "Now Playing from any app").
///
/// Transport controls go through MediaRemote's send-command call, which needs
/// no permission. Artwork is fetched over HTTPS from public endpoints.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval?
        var elapsed: TimeInterval?
        var elapsedTimestamp: Date
        var isPlaying: Bool
        var sourceBundleID: String?
        var spotifyTrackID: String?
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceAppIcon: NSImage?

    var isPlaying: Bool { track?.isPlaying ?? false }

    private var artworkKey: String?
    private var mediaRemote = MediaRemote()
    private let bridge = MediaBridgeClient()
    private var bridgeSubscription: AnyCancellable?

    init() {
        bridge.onPayload = { [weak self] payload in
            MainActor.assumeIsolated { self?.handleBridge(payload) }
        }
        bridgeSubscription = AppSettings.shared.$extendedNowPlaying
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && MediaBridgeClient.isAvailable { self.bridge.start() } else { self.bridge.stop() }
            }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handleSpotify(info) }
        }
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handleAppleMusic(info) }
        }

        mediaRemote.onChange = { [weak self] in self?.pollMediaRemote() }
        mediaRemote.start()
        pollMediaRemote()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                if let bundleID, bundleID == self?.track?.sourceBundleID { self?.clear() }
            }
        }
    }

    /// Current playback position, extrapolated while playing.
    func currentElapsed(at date: Date = Date()) -> TimeInterval? {
        guard let track, let elapsed = track.elapsed else { return nil }
        var value = elapsed
        if track.isPlaying { value += date.timeIntervalSince(track.elapsedTimestamp) }
        if let duration = track.duration { value = min(value, duration) }
        return max(0, value)
    }

    // MARK: Controls

    private func send(_ command: MediaRemote.Command, bridgeName: String) {
        if bridge.isRunning { bridge.send(bridgeName) } else { mediaRemote.send(command) }
    }

    func togglePlayPause() {
        send(.togglePlayPause, bridgeName: "toggle")
        // Optimistic UI update; the real state arrives with the next notification.
        if var t = track {
            t.elapsed = currentElapsed()
            t.elapsedTimestamp = Date()
            t.isPlaying.toggle()
            track = t
        }
    }
    func next() { send(.nextTrack, bridgeName: "next") }
    func previous() { send(.previousTrack, bridgeName: "previous") }
    func seek(to seconds: TimeInterval) {
        if bridge.isRunning { bridge.send("seek:\(seconds)") } else { mediaRemote.seek(to: seconds) }
        if var t = track { t.elapsed = seconds; t.elapsedTimestamp = Date(); track = t }
    }

    func openSourceApp() {
        guard let id = track?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Sources

    private func handleBridge(_ p: MediaBridgeClient.Payload) {
        guard !p.title.isEmpty else {
            // Nothing playing anywhere; only clear if the bridge was the source.
            if track != nil, track?.spotifyTrackID == nil, !p.isPlaying { clear() }
            return
        }
        let bundleID = p.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        update(Track(
            title: p.title, artist: p.artist, album: p.album,
            duration: p.duration, elapsed: p.elapsed,
            elapsedTimestamp: p.timestamp ?? Date(),
            isPlaying: p.isPlaying,
            sourceBundleID: bundleID ?? track?.sourceBundleID,
            spotifyTrackID: nil
        ), artwork: p.artworkData.flatMap(NSImage.init(data:)))
    }

    private func handleSpotify(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        let durationMS = (info["Duration"] as? NSNumber)?.doubleValue
        let trackID = (info["Track ID"] as? String)?.components(separatedBy: ":").last
        update(Track(
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: durationMS.map { $0 / 1000 },
            elapsed: (info["Playback Position"] as? NSNumber)?.doubleValue,
            elapsedTimestamp: Date(),
            isPlaying: state == "Playing",
            sourceBundleID: "com.spotify.client",
            spotifyTrackID: trackID
        ))
    }

    private func handleAppleMusic(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        let totalMS = (info["Total Time"] as? NSNumber)?.doubleValue
        var newTrack = Track(
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: totalMS.map { $0 / 1000 },
            elapsed: nil,
            elapsedTimestamp: Date(),
            isPlaying: state == "Playing",
            sourceBundleID: "com.apple.Music",
            spotifyTrackID: nil
        )
        // Music doesn't broadcast its position; keep extrapolating if it's the same song.
        if let old = track, old.title == newTrack.title, old.artist == newTrack.artist {
            newTrack.elapsed = currentElapsed()
        } else if newTrack.isPlaying {
            newTrack.elapsed = 0
        }
        update(newTrack)
    }

    private func pollMediaRemote() {
        mediaRemote.fetch { [weak self] snapshot in MainActor.assumeIsolated {
            guard let self, let snapshot, !snapshot.title.isEmpty else { return }
            self.update(Track(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration,
                elapsed: snapshot.elapsed,
                elapsedTimestamp: snapshot.timestamp ?? Date(),
                isPlaying: snapshot.isPlaying,
                sourceBundleID: snapshot.bundleID ?? self.track?.sourceBundleID,
                spotifyTrackID: nil
            ), artwork: snapshot.artwork)
        } }
    }

    private func update(_ newTrack: Track, artwork directArtwork: NSImage? = nil) {
        track = newTrack
        if let id = newTrack.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            sourceAppIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let directArtwork {
            artwork = directArtwork
            artworkKey = "\(newTrack.title)|\(newTrack.artist)"
            return
        }
        let key = "\(newTrack.title)|\(newTrack.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        Task { [weak self] in
            let image = await ArtworkFetcher.fetch(for: newTrack)
            guard let self, self.artworkKey == key else { return }
            self.artwork = image
        }
    }

    private func clear() {
        track = nil
        artwork = nil
        artworkKey = nil
        sourceAppIcon = nil
    }
}

// MARK: - Artwork

enum ArtworkFetcher {
    static func fetch(for track: MediaController.Track) async -> NSImage? {
        if let id = track.spotifyTrackID, let url = await spotifyArtworkURL(trackID: id) {
            return await image(at: url)
        }
        if let url = await iTunesArtworkURL(title: track.title, artist: track.artist) {
            return await image(at: url)
        }
        return nil
    }

    /// Spotify's public oEmbed endpoint returns a cover thumbnail, no auth needed.
    private static func spotifyArtworkURL(trackID: String) async -> URL? {
        var comps = URLComponents(string: "https://open.spotify.com/oembed")!
        comps.queryItems = [.init(name: "url", value: "https://open.spotify.com/track/\(trackID)")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String else { return nil }
        return URL(string: thumb)
    }

    /// Public iTunes Search API, used for Apple Music tracks.
    private static func iTunesArtworkURL(title: String, artist: String) async -> URL? {
        guard !title.isEmpty else { return nil }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let art = first["artworkUrl100"] as? String else { return nil }
        return URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
    }

    private static func image(at url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - MediaRemote (loaded dynamically, used only where the OS allows it)

final class MediaRemote {
    enum Command: Int32 {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
    }

    struct Snapshot {
        var title = "", artist = "", album = ""
        var duration: Double?, elapsed: Double?, timestamp: Date?
        var isPlaying = false
        var artwork: NSImage?
        var bundleID: String?
    }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private let handle: UnsafeMutableRawPointer?
    private var getInfo: GetInfoFn?
    private var getIsPlaying: GetIsPlayingFn?
    private var getPID: GetPIDFn?
    private var register: RegisterFn?
    private var sendCommand: SendFn?
    private var setElapsed: SetElapsedFn?

    var onChange: (@MainActor () -> Void)?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getInfo = sym("MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self)
        getIsPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetIsPlayingFn.self)
        getPID = sym("MRMediaRemoteGetNowPlayingApplicationPID", GetPIDFn.self)
        register = sym("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)
        sendCommand = sym("MRMediaRemoteSendCommand", SendFn.self)
        setElapsed = sym("MRMediaRemoteSetElapsedTime", SetElapsedFn.self)
    }

    func start() {
        register?(.main)
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"] {
            NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    func send(_ command: Command) { _ = sendCommand?(command.rawValue, nil) }
    func seek(to seconds: Double) { setElapsed?(seconds) }

    /// `completion` is always called on the main queue.
    func fetch(_ completion: @escaping (Snapshot?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(.main) { [getIsPlaying, getPID] cfInfo in
            guard let info = cfInfo as? [String: Any], !info.isEmpty else {
                completion(nil)
                return
            }
            var s = Snapshot()
            s.title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            s.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            s.album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            s.duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue
            s.elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue
            s.timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
            s.isPlaying = ((info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0) > 0
            if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data { s.artwork = NSImage(data: data) }

            let finish: (Snapshot) -> Void = { snap in completion(snap) }
            let withPID: (Snapshot) -> Void = { snap in
                guard let getPID else { finish(snap); return }
                getPID(.main) { pid in
                    var snap = snap
                    snap.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                    finish(snap)
                }
            }
            if let getIsPlaying {
                getIsPlaying(.main) { playing in
                    var snap = s
                    snap.isPlaying = playing
                    withPID(snap)
                }
            } else {
                withPID(s)
            }
        }
    }
}
