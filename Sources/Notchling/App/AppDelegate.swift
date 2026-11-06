import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var viewModel = NotchViewModel()
    private lazy var media = MediaController()
    private lazy var battery = BatteryMonitor()
    private lazy var shelf = ShelfStore()
    private lazy var clipboard = ClipboardHistory(settings: settings)
    private lazy var timer = TimerStore()
    private lazy var prompter = PrompterStore()
    private lazy var google = GoogleStore(settings: settings)
    private lazy var terminal = TerminalStore()
    private lazy var awake = KeepAwakeStore()
    private lazy var authGate = AuthGate()
    private lazy var weather = WeatherStore(settings: settings)
    private var lockScreen: LockScreenController?
    private let actions = AppActions()

    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-lockscreen"), i + 1 < args.count {
            Task {
                await snapshotLockScreen(to: args[i + 1])
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)

        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.collapse = { [weak self] in self?.notchController?.setExpanded(false) }

        timer.onFinish = { [weak self] title, detail in
            self?.viewModel.showToast(.init(icon: "bell.fill", title: title, detail: detail, tint: .orange), duration: 5)
        }
        battery.onPowerSourceChange = { [weak self] pluggedIn in
            guard let self else { return }
            let level = self.battery.level.map { "\($0)%" } ?? ""
            self.viewModel.showToast(pluggedIn
                ? .init(icon: "bolt.fill", title: "Charging \(level)", detail: nil, tint: .green)
                : .init(icon: "battery.75", title: "On battery \(level)", detail: nil))
        }

        let root = NotchRootView(vm: viewModel, media: media, timer: timer, google: google,
                                 battery: battery, settings: settings, awake: awake, shelf: shelf)
            .environmentObject(viewModel)
            .environmentObject(media)
            .environmentObject(battery)
            .environmentObject(shelf)
            .environmentObject(clipboard)
            .environmentObject(timer)
            .environmentObject(prompter)
            .environmentObject(google)
            .environmentObject(settings)
            .environmentObject(actions)
            .environmentObject(terminal)
            .environmentObject(awake)
            .environmentObject(authGate)
            .environmentObject(weather)

        notchController = NotchWindowController(viewModel: viewModel, settings: settings, rootView: root)
        // Re-lock the protected tabs shortly after the notch closes.
        viewModel.$isExpanded
            .sink { [weak self] expanded in
                guard let self else { return }
                if expanded { self.authGate.cancelRelock() }
                else { self.authGate.scheduleRelock(after: 15) }
            }
            .store(in: &cancellables)
        // Typing in the terminal keeps the notch open; clicking elsewhere releases it.
        terminal.onFocusChange = { [weak self] focused in
            if focused { self?.viewModel.isPinned = true }
        }
        notchController?.onResignKey = { [weak self] in
            guard let self, self.viewModel.tab == .terminal else { return }
            self.viewModel.isPinned = false
        }
        awake.onChange = { [weak self] on in
            self?.viewModel.showToast(on
                ? .init(icon: "cup.and.saucer.fill", title: "Staying awake", detail: nil, tint: .orange)
                : .init(icon: "moon.zzz.fill", title: "Sleep allowed", detail: nil), duration: 2)
        }
        lockScreen = LockScreenController(settings: settings, weather: weather) { [unowned self] in
            AnyView(self.lockScreenContent())
        }
        setUpStatusItem()

        if settings.googleClientID.isEmpty && !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            viewModel.showToast(.init(icon: "sparkles", title: "Hover the notch", detail: nil, tint: .yellow), duration: 4)
        }
    }

    private func lockScreenContent() -> some View {
        LockScreenWidgetsView()
            .environmentObject(settings)
            .environmentObject(weather)
            .environmentObject(media)
            .environmentObject(google)
            .environmentObject(battery)
            .environmentObject(timer)
    }

    /// Renders the lock-screen widgets to a PNG (developer check: `--snapshot-lockscreen <path>`).
    func snapshotLockScreen(to path: String) async {
        weather.refreshIfStale()
        for _ in 0..<40 where weather.report == nil && weather.lastError == nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let view = lockScreenContent()
            .frame(width: 1000, height: 240)
            .background(LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake.prepareForQuit()
        terminal.stop()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notchling")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notch", action: #selector(toggleNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() {
        viewModel.isPinned = false
        notchController?.toggle()
    }

    @objc private func openSettingsAction() { showSettings() }

    @objc private func toggleAwake() { awake.toggle() }

    func showSettings() {
        notchController?.setExpanded(false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Notchling Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings, google: google, weather: weather,
                                                                                         previewLockScreen: { [weak self] in self?.lockScreen?.preview() }))
            window.center()
            settingsWindow = window
        }
        settings.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
