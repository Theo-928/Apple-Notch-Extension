import Darwin
import Foundation

/// Runs the user's login shell on a pseudo-terminal.
final class PTYSession {
    private(set) var pid: pid_t = 0
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let readQueue = DispatchQueue(label: "notchling.pty.read")

    /// Called on the main queue with output bytes.
    var onOutput: (([UInt8]) -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { pid > 0 }

    func start(cols: Int, rows: Int) throws {
        guard !isRunning else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Notchling"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["HOME"] = home
        env["SHELL"] = shell

        // Everything the child needs is allocated *before* fork: after fork only
        // async-signal-safe C calls are allowed.
        let cShell = strdup(shell)
        let cHome = strdup(home)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 3)
        argv[0] = strdup("-" + shellName)   // leading "-" = login shell
        argv[1] = nil
        let envList = env.map { "\($0.key)=\($0.value)" }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envList.count + 1)
        for (i, entry) in envList.enumerated() { envp[i] = strdup(entry) }
        envp[envList.count] = nil
        defer {
            free(cShell); free(cHome); free(argv[0]); argv.deallocate()
            for i in 0..<envList.count { free(envp[i]) }
            envp.deallocate()
        }

        var master: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if child == 0 {
            chdir(cHome)
            execve(cShell, argv, envp)
            _exit(127)
        }

        pid = child
        masterFD = master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                let chunk = Array(buffer[0..<n])
                DispatchQueue.main.async { self.onOutput?(chunk) }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.resume()
        readSource = source

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self.cleanup()
            self.onExit?(status)
        }
        exit.resume()
        exitSource = exit
    }

    func write(_ bytes: [UInt8]) {
        guard masterFD >= 0, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if n > 0 { offset += n }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000) }
            else { break }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
    }

    private func cleanup() {
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        pid = 0
    }

    deinit {
        terminate()
    }
}
