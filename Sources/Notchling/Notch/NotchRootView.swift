import SwiftUI
import UniformTypeIdentifiers

/// Closures the views use to reach app-level behaviour.
@MainActor
final class AppActions: ObservableObject {
    var openSettings: () -> Void = {}
    var collapse: () -> Void = {}
}

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var timer: TimerStore
    @ObservedObject var google: GoogleStore
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var awake: KeepAwakeStore
    let shelf: ShelfStore

    private enum Activity: Equatable {
        case none, music, timer, meeting, toast
    }

    private var activity: Activity {
        if vm.toast != nil { return .toast }
        if timer.isActive { return .timer }
        if google.imminentEvent != nil { return .meeting }
        if media.isPlaying { return .music }
        return .none
    }

    private var earWidth: CGFloat {
        switch activity {
        case .none: return (settings.showBatteryInNotch && battery.hasBattery) || awake.isActive ? 44 : 0
        case .music: return vm.notchSize.height + 4
        case .timer: return 64
        case .meeting: return 76
        case .toast: return 120
        }
    }

    /// Inner horizontal padding of the collapsed pill (must match `collapsedContent`).
    private let collapsedInset: CGFloat = 10

    private var shapeSize: CGSize {
        if vm.isExpanded { return vm.expandedSize }
        // Add the content inset to the width so the ear contents (battery icon,
        // percentage, artwork) aren't clipped by the pill edge. When idle with no
        // ears, keep the pill exactly notch-width so it blends with the hardware.
        let sidePadding = earWidth > 0 ? collapsedInset * 2 : 0
        return CGSize(width: vm.notchSize.width + earWidth * 2 + sidePadding, height: vm.notchSize.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: vm.isExpanded ? 14 : 6, bottomRadius: vm.isExpanded ? 26 : 10)
                    .fill(Color.black)
                    .overlay(
                        NotchShape(topRadius: vm.isExpanded ? 14 : 6, bottomRadius: vm.isExpanded ? 26 : 10)
                            .stroke(vm.isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(vm.isExpanded ? 0.45 : 0), radius: 12, y: 6)

                if vm.isExpanded {
                    ExpandedNotchView(vm: vm)
                        .padding(.horizontal, 14 + 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height)
            .clipShape(NotchShape(topRadius: vm.isExpanded ? 14 : 6, bottomRadius: vm.isExpanded ? 26 : 10))
            .onDrop(of: [UTType.fileURL], isTargeted: $vm.isDropTargeted, perform: handleDrop)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: vm.isExpanded)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: activity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.tab)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: Collapsed ("live activity") content

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            leftEar.frame(width: earWidth, alignment: .leading)
            Spacer(minLength: vm.notchSize.width)
            rightEar.frame(width: earWidth, alignment: .trailing)
        }
        .padding(.horizontal, collapsedInset)
        .frame(height: vm.notchSize.height)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leftEar: some View {
        switch activity {
        case .toast:
            if let toast = vm.toast {
                Image(systemName: toast.icon).foregroundStyle(toast.tint)
                    .font(.system(size: 13, weight: .semibold))
            }
        case .timer:
            Image(systemName: timer.isPomodoro ? "brain.head.profile" : "timer")
                .foregroundStyle(.orange)
                .font(.system(size: 12, weight: .semibold))
        case .meeting:
            Image(systemName: "video.fill").foregroundStyle(.green).font(.system(size: 12))
        case .music:
            ArtworkView(image: media.artwork, fallbackIcon: media.sourceAppIcon, cornerRadius: 5)
                .frame(width: vm.notchSize.height - 10, height: vm.notchSize.height - 10)
        case .none:
            if awake.isActive {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .help("Keeping your Mac awake")
            } else if settings.showBatteryInNotch, battery.hasBattery {
                Image(systemName: battery.isCharging ? "bolt.fill" : "battery.75")
                    .font(.system(size: 11)).foregroundStyle(battery.isCharging ? .green : .white)
            }
        }
    }

    @ViewBuilder
    private var rightEar: some View {
        switch activity {
        case .toast:
            if let toast = vm.toast {
                Text(toast.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(timer.remaining(at: ctx.date).clockString)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(timer.isRunning ? .orange : .gray)
            }
        case .meeting:
            if let event = google.imminentEvent {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(event.start <= ctx.date ? "Now" : "in \(max(1, Int(event.start.timeIntervalSince(ctx.date) / 60)))m")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                }
            }
        case .music:
            AudioBars(isPlaying: media.isPlaying).frame(width: 16, height: 12)
        case .none:
            if settings.showBatteryInNotch, let level = battery.level {
                Text("\(level)%").font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? URL)
                guard let url else { return }
                DispatchQueue.main.async {
                    shelf.add([url])
                    vm.tab = .shelf
                }
            }
        }
        return accepted
    }
}

/// Little animated equalizer shown next to the notch while music plays.
struct AudioBars: View {
    let isPlaying: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2.5, height: isPlaying ? 4 + 8 * CGFloat((phase + 1) / 2) : 3)
                }
            }
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let fallbackIcon: NSImage?
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let fallbackIcon {
                Color.white.opacity(0.08)
                Image(nsImage: fallbackIcon).resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
