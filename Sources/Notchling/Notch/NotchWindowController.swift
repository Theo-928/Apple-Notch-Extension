import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that sits over the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the notch panel and decides when it opens and closes.
///
/// Hover detection uses NSEvent *mouse* monitors. Unlike keyboard monitors,
/// these don't require the Accessibility permission.
@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let viewModel: NotchViewModel
    private let settings: AppSettings
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var cancellables: Set<AnyCancellable> = []
    private var screen: NSScreen?

    /// Extra room around the expanded shape so its shadow isn't clipped.
    private let shadowMargin: CGFloat = 24

    init<Content: View>(viewModel: NotchViewModel, settings: AppSettings, rootView: Content) {
        self.viewModel = viewModel
        self.settings = settings
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        viewModel.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in self?.expandedChanged(expanded) }
            .store(in: &cancellables)
        viewModel.$isPinned
            .sink { [weak self] pinned in if !pinned { self?.scheduleCollapseIfOutside() } }
            .store(in: &cancellables)

        installMonitors()

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResignKey?() }
        }
    }

    /// Called when the panel loses keyboard focus (e.g. the user clicked another app).
    var onResignKey: (() -> Void)?

    // MARK: Layout

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    func layout() {
        guard let screen = preferredScreen() else { return }
        self.screen = screen
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            viewModel.notchSize = CGSize(width: width, height: screen.safeAreaInsets.top)
            viewModel.hasPhysicalNotch = true
        } else {
            let menuBar = max(24, frame.maxY - screen.visibleFrame.maxY)
            viewModel.notchSize = CGSize(width: 180, height: menuBar)
            viewModel.hasPhysicalNotch = false
        }

        let size = CGSize(width: viewModel.maxExpandedSize.width + shadowMargin * 2,
                          height: viewModel.maxExpandedSize.height + shadowMargin)
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// The physical notch in screen coordinates, padded a little so it's easy to hit.
    private var hotRect: CGRect {
        guard let screen else { return .zero }
        let n = viewModel.notchSize
        let padX: CGFloat = 12
        return CGRect(x: screen.frame.midX - n.width / 2 - padX,
                      y: screen.frame.maxY - n.height - 6,
                      width: n.width + padX * 2,
                      height: n.height + 6)
    }

    /// Area of the open panel; leaving it closes the notch.
    private var expandedRect: CGRect {
        guard let screen else { return .zero }
        let e = viewModel.expandedSize
        return CGRect(x: screen.frame.midX - e.width / 2,
                      y: screen.frame.maxY - e.height,
                      width: e.width, height: e.height).insetBy(dx: -14, dy: -14)
    }

    // MARK: Mouse tracking

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
            return event
        }) { monitors.append(local) }
    }

    private func handleMouse(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation

        if type == .leftMouseDown {
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            return
        }

        if !viewModel.isExpanded {
            guard hotRect.contains(location) else {
                hoverTask?.cancel(); hoverTask = nil
                return
            }
            // A changed drag pasteboard means the user is dragging content (e.g. files),
            // not just moving a window. We only read the counter, never the contents.
            let isContentDrag = type == .leftMouseDragged
                && NSPasteboard(name: .drag).changeCount != dragChangeCount
            if type == .leftMouseDragged && !(isContentDrag && settings.expandOnFileDrag) { return }
            guard hoverTask == nil else { return }
            let delay = isContentDrag ? 0 : settings.hoverDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.hoverTask = nil
                guard self.hotRect.contains(NSEvent.mouseLocation) else { return }
                if isContentDrag { self.viewModel.tab = .shelf }
                self.setExpanded(true)
            }
        } else {
            if expandedRect.contains(location) {
                collapseTask?.cancel(); collapseTask = nil
            } else {
                scheduleCollapseIfOutside()
            }
        }
    }

    private func scheduleCollapseIfOutside() {
        guard viewModel.isExpanded, !viewModel.isPinned, collapseTask == nil else { return }
        guard !expandedRect.contains(NSEvent.mouseLocation) else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            if !self.expandedRect.contains(NSEvent.mouseLocation), !self.viewModel.isPinned {
                self.setExpanded(false)
            }
        }
    }

    func setExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            viewModel.isExpanded = expanded
        }
    }

    func toggle() { setExpanded(!viewModel.isExpanded) }

    private func expandedChanged(_ expanded: Bool) {
        panel.ignoresMouseEvents = !expanded
        if expanded {
            if settings.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else if panel.isKeyWindow {
            // Hand keyboard focus back to whatever app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
}
