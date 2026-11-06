import AppKit
import SwiftUI

/// Owns the single terminal session so it survives the notch opening and closing.
@MainActor
final class TerminalStore: ObservableObject {
    @Published private(set) var title = "Terminal"
    @Published private(set) var isRunning = false
    @Published private(set) var exitMessage: String?

    /// Called when the terminal gains/loses keyboard focus (used to keep the notch open).
    var onFocusChange: (Bool) -> Void = { _ in }

    let emulator = TerminalEmulator(cols: 80, rows: 12)
    private(set) lazy var view: TerminalView = makeView()
    private let session = PTYSession()

    private func makeView() -> TerminalView {
        let view = TerminalView(emulator: emulator)
        view.sendBytes = { [weak self] bytes in
            guard let self else { return }
            if !self.isRunning {
                // Any key restarts a finished shell.
                self.start()
                return
            }
            self.session.write(bytes)
        }
        view.onResize = { [weak self] cols, rows in self?.session.resize(cols: cols, rows: rows) }
        view.onFocusChange = { [weak self] focused in self?.onFocusChange(focused) }
        emulator.respond = { [weak self] bytes in self?.session.write(bytes) }
        session.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.emulator.feed(bytes)
            self.view.outputArrived()
            let t = self.emulator.title
            if !t.isEmpty, t != self.title { self.title = t }
        }
        session.onExit = { [weak self] status in
            guard let self else { return }
            self.isRunning = false
            self.exitMessage = "Shell exited (\(status)). Press any key to start a new one."
            self.emulator.feed(Array("\r\n\u{1B}[2m[Process exited — press any key to restart]\u{1B}[0m\r\n".utf8))
            self.view.outputArrived()
        }
        return view
    }

    /// Starts the shell lazily, the first time the Terminal tab is shown.
    func start() {
        guard !session.isRunning else { return }
        _ = view
        do {
            try session.start(cols: emulator.cols, rows: emulator.rows)
            isRunning = true
            exitMessage = nil
            title = "Terminal"
        } catch {
            exitMessage = "Couldn't start shell: \(error.localizedDescription)"
        }
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    func restart() {
        session.terminate()
    }

    func stop() { session.terminate() }
}

/// SwiftUI wrapper that reuses the same terminal NSView every time.
struct TerminalHost: NSViewRepresentable {
    let store: TerminalStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if store.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let view = store.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
