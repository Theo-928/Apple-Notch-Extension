import AppKit
import Foundation

/// Countdown timer + Pomodoro. Completion is signalled inside the notch with a
/// sound, so no Notifications permission is required.
@MainActor
final class TimerStore: ObservableObject {
    enum Mode: Equatable { case countdown, focus, shortBreak }

    @Published private(set) var mode: Mode = .countdown
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var completedFocusSessions = 0
    @Published var focusMinutes: Double = 25
    @Published var breakMinutes: Double = 5

    /// Called when a countdown finishes: (title, message).
    var onFinish: ((String, String) -> Void)?

    private var ticker: Timer?

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isRunning: Bool { endDate != nil }
    var isPomodoro: Bool { mode != .countdown }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? 0
    }

    func progress(at date: Date = Date()) -> Double {
        guard total > 0 else { return 0 }
        return 1 - remaining(at: date) / total
    }

    var label: String {
        switch mode {
        case .countdown: return "Timer"
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        }
    }

    func start(minutes: Double) {
        mode = .countdown
        begin(seconds: minutes * 60)
    }

    func startPomodoro() {
        mode = .focus
        begin(seconds: focusMinutes * 60)
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        ticker?.invalidate()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        schedule()
    }

    func addMinute() {
        if let endDate { self.endDate = endDate.addingTimeInterval(60) }
        else if let pausedRemaining { self.pausedRemaining = pausedRemaining + 60 }
        total += 60
    }

    func stop() {
        ticker?.invalidate()
        endDate = nil
        pausedRemaining = nil
        total = 0
        if mode != .countdown { completedFocusSessions = 0 }
        mode = .countdown
    }

    private func begin(seconds: TimeInterval) {
        total = seconds
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(seconds)
        schedule()
    }

    private func schedule() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let endDate, endDate <= Date() else { return }
        ticker?.invalidate()
        self.endDate = nil
        NSSound(named: "Glass")?.play()
        switch mode {
        case .countdown:
            total = 0
            onFinish?("Time's up", "Your timer finished")
        case .focus:
            completedFocusSessions += 1
            onFinish?("Focus done", "Take a \(Int(breakMinutes)) min break")
            mode = .shortBreak
            begin(seconds: breakMinutes * 60)
        case .shortBreak:
            onFinish?("Break over", "Back to focus")
            mode = .focus
            begin(seconds: focusMinutes * 60)
        }
    }
}

extension TimeInterval {
    /// 75 → "1:15", 3700 → "1:01:40"
    var clockString: String {
        let s = Int(self.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
