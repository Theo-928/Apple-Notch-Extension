import SwiftUI

struct ExpandedNotchView: View {
    @ObservedObject var vm: NotchViewModel
    @EnvironmentObject var battery: BatteryMonitor
    @EnvironmentObject var google: GoogleStore
    @EnvironmentObject var actions: AppActions
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var gate: AuthGate

    /// Tabs hidden behind Touch ID when the setting is on.
    private func isLocked(_ tab: NotchTab) -> Bool {
        settings.lockSensitiveTabs && !gate.isUnlocked && (tab == .clipboard || tab == .terminal)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Group {
                if isLocked(vm.tab) {
                    LockedTabView(tab: vm.tab)
                } else {
                    switch vm.tab {
                    case .home: HomeTab()
                    case .shelf: ShelfTab()
                    case .clipboard: ClipboardTab()
                    case .timer: TimerTab()
                    case .prompter: PrompterTab(vm: vm)
                    case .terminal: TerminalTab(vm: vm)
                    case .awake: KeepAwakeTab()
                    case .google: GoogleTab()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        .onChange(of: vm.tab) { tab in
            if tab == .google || tab == .home { google.refreshIfStale() }
        }
        .onAppear { google.refreshIfStale() }
    }

    /// Header row sits beside the physical notch: tabs on the left, status on the right.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.allCases) { tab in
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.tab = tab } } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 25, height: 22)
                            .background(vm.tab == tab ? Color.white.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(vm.tab == tab ? .white : .white.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            Spacer(minLength: vm.notchSize.width + 8)
            HStack(spacing: 10) {
                if let level = battery.level {
                    HStack(spacing: 3) {
                        Image(systemName: batteryIcon(level))
                        Text("\(level)%").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(battery.isCharging ? .green : .white.opacity(0.75))
                }
                Button { vm.isPinned.toggle() } label: {
                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(vm.isPinned ? .orange : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(vm.isPinned ? "Unpin (close when the cursor leaves)" : "Keep open")
                Button { actions.openSettings() } label: {
                    Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .font(.system(size: 12))
        }
        .frame(height: vm.notchSize.height)
    }

    private func batteryIcon(_ level: Int) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Shared bits

struct SectionLabel: View {
    let text: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text.uppercased())
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(.white.opacity(0.45))
    }
}

struct PillButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemImage: String
    var size: CGFloat = 14
    var help: String = ""
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 16, height: size + 12)
                .background(Color.white.opacity(hovering.value ? 0.14 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help(help)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Date {
    var shortTime: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: self)
    }
}

/// Local view state without the `@State` macro, so the app builds with just the
/// Command Line Tools (newer SDKs implement `@State` as a macro whose plugin
/// ships only with full Xcode).
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
