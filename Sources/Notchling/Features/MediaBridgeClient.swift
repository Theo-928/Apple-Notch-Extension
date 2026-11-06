import Foundation

/// Opt-in "Now Playing from any app" source (Settings → General).
///
/// Since macOS 15.4 the MediaRemote framework only answers Apple-signed
/// processes. This client runs the bundled `libMediaBridge.dylib` inside
/// `/usr/bin/perl` (an Apple binary) and reads JSON lines from it. It's an
/// unofficial technique: it may stop working after a macOS update, and it's off
/// by default so the user decides whether their IT policy allows it.
final class MediaBridgeClient {
    struct Payload {
        var title = "", artist = "", album = ""
        var duration: Double?, elapsed: Double?, timestamp: Date?
        var isPlaying = false
        var artworkData: Data?
        var pid: Int32?
    }

    var onPayload: ((Payload) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var restarts = 0
    private var wantsRunning = false

    static var dylibURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("libMediaBridge.dylib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var isAvailable: Bool { dylibURL != nil }

    private static let loader = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        wantsRunning = true
        restarts = 0
        launch()
    }

    func stop() {
        wantsRunning = false
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    func send(_ command: String) {
        guard let dylib = Self.dylibURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, dylib.path, "notchling_send"]
        p.environment = ["NOTCHLING_CMD": command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func launch() {
        guard wantsRunning, let dylib = Self.dylibURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, dylib.path, "notchling_stream"]
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardInput = input       // the helper exits when this closes
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning, self.restarts < 3 else { return }
                self.restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.launch() }
            }
        }
        do {
            try p.run()
            process = p
            stdinPipe = input
        } catch {
            process = nil
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "nowPlaying" else { continue }
            var p = Payload()
            p.title = json["title"] as? String ?? ""
            p.artist = json["artist"] as? String ?? ""
            p.album = json["album"] as? String ?? ""
            p.duration = (json["duration"] as? NSNumber)?.doubleValue
            p.elapsed = (json["elapsed"] as? NSNumber)?.doubleValue
            p.timestamp = (json["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            p.isPlaying = (json["playing"] as? Bool) ?? (((json["rate"] as? NSNumber)?.doubleValue ?? 0) > 0)
            p.artworkData = (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
            p.pid = (json["pid"] as? NSNumber)?.int32Value
            onPayload?(p)
        }
    }

    deinit { stop() }
}
