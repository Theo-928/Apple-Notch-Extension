import SwiftUI

// MARK: - Shelf

struct ShelfTab: View {
    @EnvironmentObject var shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(0.25))
                .overlay(EmptyStateView(systemImage: "tray.and.arrow.down",
                                        title: "Drop files here",
                                        detail: "Drag files onto the notch to park them,\nthen drag them out wherever you need them."))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")", systemImage: "tray.full")
                    Spacer()
                    PillButton(title: "AirDrop all", systemImage: "airplayaudio") { shelf.airDrop(shelf.items) }
                    PillButton(title: "Clear", systemImage: "trash") { shelf.clear() }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in ShelfTile(item: item) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfStore.Item
    @EnvironmentObject var shelf: ShelfStore
    @StateObject private var hovering = Box(false)

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: shelf.icon(for: item))
                .resizable().frame(width: 52, height: 52)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 78)
        }
        .padding(6)
        .background(Color.white.opacity(hovering.value ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if hovering.value {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering.value = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .help(item.url.path)
    }
}

// MARK: - Clipboard

struct ClipboardTab: View {
    @EnvironmentObject var clipboard: ClipboardHistory
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        if !settings.clipboardHistoryEnabled {
            VStack(spacing: 8) {
                EmptyStateView(systemImage: "doc.on.clipboard",
                               title: "Clipboard history is off",
                               detail: "It's opt-in. Text you copy is kept in memory only, never saved to disk.\nPassword-manager copies are skipped. Recent macOS may ask to allow pasteboard access.")
                PillButton(title: "Turn on", systemImage: "power") { settings.clipboardHistoryEnabled = true }
            }
        } else if clipboard.entries.isEmpty {
            EmptyStateView(systemImage: "doc.on.clipboard", title: "Nothing copied yet",
                           detail: "Copy some text and it'll appear here.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel(text: "Click to copy again", systemImage: "doc.on.clipboard")
                    Spacer()
                    PillButton(title: "Clear", systemImage: "trash") { clipboard.clear() }
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboard.entries) { entry in
                            ClipboardRow(entry: entry) {
                                clipboard.copy(entry)
                                vm.showToast(.init(icon: "checkmark.circle.fill", title: "Copied", detail: nil, tint: .green), duration: 1.5)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardHistory.Entry
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            HStack {
                Text(entry.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(entry.sourceApp ?? "").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(hovering.value ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

// MARK: - Timer

struct TimerTab: View {
    @EnvironmentObject var timer: TimerStore

    var body: some View {
        if timer.isActive {
            HStack(spacing: 24) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: 1 - timer.progress(at: ctx.date))
                            .stroke(timer.mode == .shortBreak ? Color.green : Color.orange,
                                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(timer.remaining(at: ctx.date).clockString)
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text(timer.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: 120, height: 120)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if timer.isPomodoro {
                        Text("Focus sessions done: \(timer.completedFocusSessions)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(spacing: 8) {
                        PillButton(title: timer.isRunning ? "Pause" : "Resume",
                                   systemImage: timer.isRunning ? "pause.fill" : "play.fill", tint: .orange) {
                            timer.isRunning ? timer.pause() : timer.resume()
                        }
                        PillButton(title: "+1 min", systemImage: "plus") { timer.addMinute() }
                        PillButton(title: "Stop", systemImage: "stop.fill", tint: .red) { timer.stop() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Quick timer", systemImage: "timer")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4), spacing: 8) {
                        ForEach([1, 3, 5, 10, 15, 20, 30, 60], id: \.self) { minutes in
                            Button { timer.start(minutes: Double(minutes)) } label: {
                                Text(minutes >= 60 ? "1 h" : "\(minutes) m")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 62, height: 30)
                                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Pomodoro", systemImage: "brain.head.profile")
                    Stepper("Focus  \(Int(timer.focusMinutes)) min", value: $timer.focusMinutes, in: 5...90, step: 5)
                    Stepper("Break  \(Int(timer.breakMinutes)) min", value: $timer.breakMinutes, in: 1...30, step: 1)
                    PillButton(title: "Start focus", systemImage: "play.fill", tint: .orange) { timer.startPomodoro() }
                }
                .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Teleprompter

struct PrompterTab: View {
    @ObservedObject var vm: NotchViewModel
    @EnvironmentObject var prompter: PrompterStore
    @StateObject private var textHeight = Box<CGFloat>(0)

    var body: some View {
        VStack(spacing: 6) {
            if prompter.isEditing {
                TextEditor(text: $prompter.script)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                GeometryReader { geo in
                    TimelineView(.animation(paused: !prompter.isRunning)) { ctx in
                        let offset = min(prompter.offset(at: ctx.date), max(0, textHeight.value - 20))
                        Text(prompter.script)
                            .font(.system(size: prompter.fontSize, weight: .medium))
                            .multilineTextAlignment(.center)
                            .frame(width: geo.size.width)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { t in
                                Color.clear.onAppear { textHeight.value = t.size.height }
                                    .onChange(of: t.size.height) { textHeight.value = $0 }
                            })
                            .offset(y: 20 - offset)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                }
                .contentShape(Rectangle())
                .onTapGesture { prompter.toggle() }
            }
            HStack(spacing: 4) {
                IconButton(systemImage: prompter.isRunning ? "pause.fill" : "play.fill", size: 13,
                           help: "Play / pause (or click the text)") { prompter.toggle() }
                IconButton(systemImage: "backward.end.fill", size: 11, help: "Back to start") { prompter.reset() }
                IconButton(systemImage: "chevron.up", size: 11, help: "Scroll back") { prompter.nudge(-40) }
                IconButton(systemImage: "chevron.down", size: 11, help: "Scroll ahead") { prompter.nudge(40) }
                Spacer()
                Text("Speed").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                IconButton(systemImage: "tortoise.fill", size: 11) { prompter.changeSpeed(by: -5) }
                IconButton(systemImage: "hare.fill", size: 11) { prompter.changeSpeed(by: 5) }
                Text("Size").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                IconButton(systemImage: "textformat.size.smaller", size: 11) { prompter.fontSize = max(11, prompter.fontSize - 2) }
                IconButton(systemImage: "textformat.size.larger", size: 11) { prompter.fontSize = min(36, prompter.fontSize + 2) }
                Spacer()
                PillButton(title: prompter.isEditing ? "Done" : "Edit script",
                           systemImage: prompter.isEditing ? "checkmark" : "pencil") {
                    prompter.isEditing.toggle()
                }
            }
        }
        .onChange(of: prompter.isRunning) { running in
            // Keep the notch open while reading.
            vm.isPinned = running
        }
    }
}
