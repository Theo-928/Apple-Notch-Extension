import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, clipboard, timer, prompter, terminal, awake, google
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .timer: return "Timer"
        case .prompter: return "Prompter"
        case .terminal: return "Terminal"
        case .awake: return "Keep Awake"
        case .google: return "Google"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .timer: return "timer"
        case .prompter: return "text.alignleft"
        case .terminal: return "terminal.fill"
        case .awake: return "cup.and.saucer.fill"
        case .google: return "calendar"
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    struct Toast: Equatable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String?
        var tint: Color = .white
    }

    @Published var isExpanded = false
    @Published var tab: NotchTab = .home
    @Published var isDropTargeted = false
    @Published var toast: Toast?
    /// Keeps the panel open even when the cursor leaves (e.g. teleprompter running).
    @Published var isPinned = false

    /// Size of the physical notch (or the pill on displays without one).
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasPhysicalNotch = true

    /// Panel size for the current tab; the terminal gets extra height.
    var expandedSize: CGSize {
        tab == .terminal ? CGSize(width: 720, height: 370) : CGSize(width: 720, height: 220)
    }
    /// Largest panel size (the window is sized for this once).
    let maxExpandedSize = CGSize(width: 720, height: 370)

    private var toastTask: Task<Void, Never>?

    func showToast(_ toast: Toast, duration: TimeInterval = 3) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.toast = toast }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self?.toast = nil }
        }
    }
}
