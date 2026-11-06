import SwiftUI

// MARK: - Terminal

struct TerminalTab: View {
    @ObservedObject var vm: NotchViewModel
    @EnvironmentObject var terminal: TerminalStore

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                SectionLabel(text: terminal.title, systemImage: "terminal")
                    .lineLimit(1)
                Spacer()
                Text(vm.isPinned ? "Click 📌 or another app to release" : "Click inside to type")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                Text("⌘K clear · ⌘± size")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                IconButton(systemImage: "arrow.counterclockwise", size: 10, help: "Restart shell") { terminal.restart() }
            }
            TerminalHost(store: terminal)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(vm.isPinned ? 0.25 : 0.1), lineWidth: 1))
        }
        .onAppear { terminal.start() }
    }
}

// MARK: - Keep awake

struct KeepAwakeTab: View {
    @EnvironmentObject var awake: KeepAwakeStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Button { awake.toggle() } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(awake.isActive ? Color.orange : Color.white.opacity(0.12))
                            Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "moon.zzz.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(awake.isActive ? .black : .white.opacity(0.8))
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(awake.isActive ? "Staying awake" : "Keep awake")
                                .font(.system(size: 14, weight: .semibold))
                            Text(statusLine)
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    durationChip("∞", nil)
                    durationChip("30m", 30)
                    durationChip("1h", 60)
                    durationChip("2h", 120)
                    durationChip("4h", 240)
                    durationChip("8h", 480)
                }
            }
            .frame(width: 270, alignment: .leading)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Options", systemImage: "slider.horizontal.3")
                toggle("Keep the display on", $awake.keepDisplayOn)
                toggle("Keep Wi-Fi / network connection alive", $awake.keepNetworkAlive)
                toggle("Also with the lid closed (asks for admin password)",
                       Binding(get: { awake.closedLidMode }, set: { awake.setClosedLid($0) }))
                VStack(alignment: .leading, spacing: 3) {
                    statusRow(icon: networkIcon, text: networkText)
                    statusRow(icon: awake.lidSleepDisabled ? "laptopcomputer" : "laptopcomputer.slash",
                              text: awake.lidSleepDisabled
                                ? "Lid-close sleep is OFF. Mac stays awake when closed\(awake.isLidClosed ? " (lid closed now)" : "")"
                                : "Lid-close sleep is on (normal)",
                              tint: awake.lidSleepDisabled ? .orange : nil)
                    if awake.lidSleepDisabled && !awake.isActive && !awake.isWorking {
                        Button("Sleep is still disabled system-wide. Restore") { awake.forceRestoreSleep() }
                            .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
                    }
                    if awake.isWorking {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Working…") }
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    if let msg = awake.message {
                        Text(msg).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .onAppear { awake.refreshSystemState() }
    }

    private var statusLine: String {
        guard awake.isActive else { return "Your Mac sleeps normally" }
        if let until = awake.until { return "Until \(until.shortTime) · click to stop" }
        return "Indefinitely · click to stop"
    }

    private func durationChip(_ label: String, _ minutes: Int?) -> some View {
        let selected = awake.isActive && (minutes == nil ? awake.until == nil : false)
        return Button { awake.activate(minutes: minutes) } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 36, height: 24)
                .background(selected ? Color.orange.opacity(0.35) : Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(title).font(.system(size: 11.5)) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private func statusRow(icon: String, text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).frame(width: 14)
            Text(text).lineLimit(2)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(tint ?? .white.opacity(0.55))
    }

    private var networkIcon: String {
        switch awake.network {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private var networkText: String {
        let base: String
        switch awake.network {
        case .wifi: base = "Wi-Fi connected"
        case .ethernet: base = "Ethernet connected"
        case .other: base = "Connected"
        case .offline: base = "Offline"
        }
        guard awake.isActive, awake.keepNetworkAlive, let ping = awake.lastPing else { return base }
        return base + " · last keep-alive \(ping.formatted(.dateTime.hour().minute().second()))"
    }
}
