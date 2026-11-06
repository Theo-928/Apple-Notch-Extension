import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import Network

/// Keeps the Mac (and its network connection) awake.
///
/// * Lid open: IOKit power assertions. No permission or password needed.
/// * Lid closed: macOS always sleeps on lid close, unless an external display is
///   attached or sleep is disabled system-wide with `pmset disablesleep`, which
///   needs an administrator password. Notchling asks once, then starts a small
///   root watcher that turns sleep back on automatically when you switch it off,
///   when Notchling quits or crashes, or when the battery gets low.
@MainActor
final class KeepAwakeStore: ObservableObject {
    enum NetworkStatus: Equatable { case wifi, ethernet, other, offline }

    @Published private(set) var isActive = false
    @Published private(set) var until: Date?
    @Published var keepDisplayOn: Bool { didSet { save(); if isActive { applyAssertions() } } }
    @Published var keepNetworkAlive: Bool { didSet { save(); if isActive { applyAssertions(); updatePinger() } } }
    @Published var closedLidMode: Bool { didSet { save() } }
    @Published var lowBatteryCutoff: Int { didSet { save() } }

    @Published private(set) var lidSleepDisabled = false
    @Published private(set) var isLidClosed = false
    @Published private(set) var network: NetworkStatus = .other
    @Published private(set) var lastPing: Date?
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false

    var onChange: ((Bool) -> Void)?

    private var assertions: [IOPMAssertionID] = []
    private var expiryTimer: Timer?
    private var pingTimer: Timer?
    private var statusTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let defaults = UserDefaults.standard
    private lazy var stopFlagURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("notchling-allow-sleep")
    private lazy var pingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init() {
        defaults.register(defaults: ["awake.keepDisplayOn": false, "awake.keepNetworkAlive": true,
                                     "awake.closedLid": false, "awake.lowBattery": 15])
        keepDisplayOn = defaults.bool(forKey: "awake.keepDisplayOn")
        keepNetworkAlive = defaults.bool(forKey: "awake.keepNetworkAlive")
        closedLidMode = defaults.bool(forKey: "awake.closedLid")
        lowBatteryCutoff = defaults.integer(forKey: "awake.lowBattery")

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status: NetworkStatus
            if path.status != .satisfied { status = .offline }
            else if path.usesInterfaceType(.wifi) { status = .wifi }
            else if path.usesInterfaceType(.wiredEthernet) { status = .ethernet }
            else { status = .other }
            DispatchQueue.main.async { self?.network = status }
        }
        pathMonitor.start(queue: DispatchQueue(label: "notchling.awake.path"))

        refreshSystemState()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemState() }
        }
    }

    // MARK: Public

    func activate(minutes: Int?) {
        until = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        isActive = true
        applyAssertions()
        updatePinger()
        scheduleExpiry()
        if closedLidMode && !lidSleepDisabled { enableClosedLid() }
        onChange?(true)
    }

    func deactivate() {
        isActive = false
        until = nil
        expiryTimer?.invalidate()
        releaseAssertions()
        updatePinger()
        if lidSleepDisabled { disableClosedLid() }
        onChange?(false)
    }

    func toggle() { isActive ? deactivate() : activate(minutes: nil) }

    func setClosedLid(_ on: Bool) {
        closedLidMode = on
        guard isActive else { return }
        if on && !lidSleepDisabled { enableClosedLid() }
        if !on && lidSleepDisabled { disableClosedLid() }
    }

    /// Called on quit: the root watcher notices we're gone, but signal it right away too.
    func prepareForQuit() {
        releaseAssertions()
        if lidSleepDisabled { FileManager.default.createFile(atPath: stopFlagURL.path, contents: nil) }
    }

    // MARK: Assertions (no permission needed)

    private func applyAssertions() {
        releaseAssertions()
        var types = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]
        if keepDisplayOn { types.append("PreventUserIdleDisplaySleep") }
        if keepNetworkAlive { types.append("NetworkClientActive") }
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Notchling: keep awake" as CFString, &id)
            if result == kIOReturnSuccess { assertions.append(id) }
        }
    }

    private func releaseAssertions() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let until else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deactivate() }
        }
    }

    // MARK: Network keep-alive

    /// A tiny HTTPS request every 45 s keeps Wi-Fi out of power-save and NAT/VPN sessions open.
    private func updatePinger() {
        pingTimer?.invalidate()
        pingTimer = nil
        guard isActive, keepNetworkAlive else { return }
        ping()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
    }

    private func ping() {
        var req = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        pingSession.dataTask(with: req) { [weak self] _, response, _ in
            guard response != nil else { return }
            DispatchQueue.main.async { self?.lastPing = Date() }
        }.resume()
    }

    // MARK: Closed lid (admin)

    private func enableClosedLid() {
        try? FileManager.default.removeItem(at: stopFlagURL)
        let pid = ProcessInfo.processInfo.processIdentifier
        let flag = stopFlagURL.path.replacingOccurrences(of: "'", with: "")
        let cutoff = max(5, min(50, lowBatteryCutoff))
        // Root watcher: re-enables sleep when the flag file appears, when Notchling
        // exits for any reason, or when the battery drops below the cutoff.
        let script = """
        /usr/bin/pmset -a disablesleep 1; \
        ( while /bin/kill -0 \(pid) 2>/dev/null && [ ! -e '\(flag)' ]; do \
            b=$(/usr/bin/pmset -g batt); \
            case "$b" in *"Battery Power"*) p=$(echo "$b" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d '%'); \
              [ -n "$p" ] && [ "$p" -le \(cutoff) ] && break;; esac; \
            /bin/sleep 5; \
          done; \
          /usr/bin/pmset -a disablesleep 0; /bin/rm -f '\(flag)' ) >/dev/null 2>&1 &
        """
        runPrivileged(script) { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.closedLidMode = false
                self.message = "Closed-lid mode needs an administrator password. Without one, keep the lid open, or connect power and an external display (clamshell mode)."
            } else {
                self.message = nil
            }
            self.refreshSystemState()
        }
    }

    private func disableClosedLid() {
        // Signal the root watcher; it restores sleep within ~5 seconds. No password needed.
        FileManager.default.createFile(atPath: stopFlagURL.path, contents: nil)
        isWorking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.isWorking = false
            self.refreshSystemState()
        }
    }

    /// Restores sleep if it was left disabled (e.g. by an older crash).
    func forceRestoreSleep() {
        runPrivileged("/usr/bin/pmset -a disablesleep 0") { [weak self] _ in self?.refreshSystemState() }
    }

    private func runPrivileged(_ shell: String, completion: @escaping @MainActor (Bool) -> Void) {
        isWorking = true
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Notchling wants to keep your Mac awake while the lid is closed.\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let ok = error == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isWorking = false
                    completion(ok)
                }
            }
        }
    }

    // MARK: System state

    func refreshSystemState() {
        isLidClosed = Self.readClamshellState()
        DispatchQueue.global(qos: .utility).async {
            let disabled = Self.readSleepDisabled()
            DispatchQueue.main.async { [weak self] in self?.lidSleepDisabled = disabled }
        }
    }

    private nonisolated static func readSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }

    private static func readClamshellState() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    private func save() {
        defaults.set(keepDisplayOn, forKey: "awake.keepDisplayOn")
        defaults.set(keepNetworkAlive, forKey: "awake.keepNetworkAlive")
        defaults.set(closedLidMode, forKey: "awake.closedLid")
        defaults.set(lowBatteryCutoff, forKey: "awake.lowBattery")
    }
}
