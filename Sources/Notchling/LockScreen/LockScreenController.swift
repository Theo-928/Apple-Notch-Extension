import AppKit
import SwiftUI

/// Shows a row of widgets (weather, Now Playing, next event, battery) on the
/// lock screen.
///
/// Lock/unlock comes from the `com.apple.screenIsLocked` distributed
/// notifications, which any app can observe without a permission.
@MainActor
final class LockScreenController {
    private let settings: AppSettings
    private let weather: WeatherStore
    private let makeContent: () -> AnyView
    private var panel: NSPanel?
    private var previewTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    static var isSupported: Bool { LockScreenSpace.shared != nil }

    /// Band height; the cards are centred inside it and the rest is transparent.
    private let bandHeight: CGFloat = 240

    init(settings: AppSettings, weather: WeatherStore, content: @escaping () -> AnyView) {
        self.settings = settings
        self.weather = weather
        self.makeContent = content
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        })
    }

    private func screenLocked() {
        weather.refreshIfStale()
        guard settings.lockScreenWidgets, let space = LockScreenSpace.shared else { return }
        previewTask?.cancel()
        let panel = makePanel()
        panel.canBecomeVisibleWithoutLogin = true
        space.adopt(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func screenUnlocked() {
        dismiss()
    }

    /// Shows the widgets on the normal desktop for a few seconds, so you can
    /// see them without locking your Mac.
    func preview() {
        dismiss()
        weather.refreshIfStale()
        let panel = makePanel()
        panel.level = .screenSaver
        panel.orderFrontRegardless()
        self.panel = panel
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        previewTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Centre of the band sits ~44% down from the top: below the big lock-screen
        // clock and well above the user picture / password field.
        let centerY = frame.maxY - frame.height * 0.44
        let rect = NSRect(x: frame.minX, y: centerY - bandHeight / 2, width: frame.width, height: bandHeight)

        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: makeContent())
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.setFrame(rect, display: false)
        return panel
    }
}
