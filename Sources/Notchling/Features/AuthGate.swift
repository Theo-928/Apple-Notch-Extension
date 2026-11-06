import Foundation
import LocalAuthentication

/// Touch ID (or login-password) lock for sensitive tabs.
///
/// Uses LocalAuthentication, the same system sheet as unlocking 1Password or
/// Safari passwords. It needs no privacy permission, and Notchling never sees
/// your fingerprint or password, only whether the check passed.
@MainActor
final class AuthGate: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: String?

    private var relockTask: Task<Void, Never>?

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "your password"
    }

    func authenticate(reason: String) {
        guard !isAuthenticating else { return }
        lastError = nil
        isAuthenticating = true
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            let message = (error as? LAError).flatMap { $0.code == .userCancel || $0.code == .systemCancel ? nil : $0.localizedDescription }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isAuthenticating = false
                    self.isUnlocked = success
                    self.lastError = message
                }
            }
        }
    }

    func lock() {
        relockTask?.cancel()
        isUnlocked = false
    }

    /// Re-locks after a delay unless cancelled (called when the notch closes).
    func scheduleRelock(after seconds: TimeInterval) {
        relockTask?.cancel()
        guard isUnlocked else { return }
        relockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isUnlocked = false
        }
    }

    func cancelRelock() { relockTask?.cancel() }
}
