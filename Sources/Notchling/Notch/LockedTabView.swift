import SwiftUI

/// Shown in place of a locked tab (Clipboard / Terminal) until the user passes
/// Touch ID (or the login password). Uses the system LocalAuthentication sheet,
/// so it needs no permission and Notchling never sees the fingerprint.
struct LockedTabView: View {
    let tab: NotchTab
    @EnvironmentObject var gate: AuthGate

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: gate.isAuthenticating ? "touchid" : "lock.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(gate.isAuthenticating ? .green : .white.opacity(0.7))
                .opacity(gate.isAuthenticating ? 0.6 : 1)
            Text("\(tab.title) is locked")
                .font(.system(size: 13, weight: .semibold))
            PillButton(title: "Unlock with \(gate.biometryName)", systemImage: "touchid", tint: .green) {
                unlock()
            }
            if let err = gate.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if !gate.isUnlocked, !gate.isAuthenticating { unlock() } }
    }

    private func unlock() {
        gate.authenticate(reason: "unlock \(tab.title) in Notchling")
    }
}
