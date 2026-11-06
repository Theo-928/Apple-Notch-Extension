import Foundation

/// Teleprompter that scrolls text right under the camera.
@MainActor
final class PrompterStore: ObservableObject {
    @Published var script: String {
        didSet { UserDefaults.standard.set(script, forKey: "prompterScript") }
    }
    @Published var speed: Double = 30          // points per second
    @Published var fontSize: Double = 18
    @Published private(set) var isRunning = false
    @Published var isEditing = false

    /// Offset accumulated before the current run segment started.
    private var baseOffset: Double = 0
    private var runStart: Date?

    init() {
        script = UserDefaults.standard.string(forKey: "prompterScript")
            ?? "Paste your script here.\n\nPress play and the text scrolls right under your camera, so you keep eye contact while you read."
    }

    func offset(at date: Date) -> Double {
        guard let runStart else { return baseOffset }
        return baseOffset + date.timeIntervalSince(runStart) * speed
    }

    func toggle() {
        if isRunning {
            baseOffset = offset(at: Date())
            runStart = nil
            isRunning = false
        } else {
            isEditing = false
            runStart = Date()
            isRunning = true
        }
    }

    func reset() {
        baseOffset = 0
        runStart = isRunning ? Date() : nil
    }

    func nudge(_ points: Double) {
        let current = offset(at: Date())
        baseOffset = max(0, current + points)
        if isRunning { runStart = Date() }
    }

    func changeSpeed(by delta: Double) {
        let current = offset(at: Date())
        baseOffset = current
        if isRunning { runStart = Date() }
        speed = min(150, max(5, speed + delta))
    }
}
