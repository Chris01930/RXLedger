import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID (falling back to the device passcode) app lock. On by default.
@Observable
final class AppLockManager {
    static let enabledKey = "appLock.enabled"

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    var lastError: String?

    init(previewUnlocked: Bool = false) {
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        var skip = previewUnlocked
        #if DEBUG
        skip = skip || ProcessInfo.processInfo.arguments.contains("-skipAppLock")
        #endif
        isEnabled = skip ? false : stored
        isLocked = skip ? false : stored
    }

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode".
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Cover the UI while locked, and in the app switcher when the lock is enabled.
    func shouldObscureContent(scenePhase: ScenePhase) -> Bool {
        isEnabled && (isLocked || scenePhase != .active)
    }

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            if isEnabled { isLocked = true }
        case .active:
            if isLocked && !isAuthenticating { Task { await unlock() } }
        default:
            break
        }
    }

    @MainActor
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if await authenticate(reason: "Unlock your prescription history") {
            isLocked = false
        }
    }

    /// Turning the lock off requires authenticating first.
    @MainActor
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if !enabled {
            guard await authenticate(reason: "Turn off the app lock") else { return }
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if !enabled { isLocked = false }
    }

    @MainActor
    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode is set on the device, so there is nothing to authenticate against.
            // Don't lock the user out of their own data.
            lastError = "This device has no passcode, so RxLedger can't be locked. Set a passcode in Settings to enable the lock."
            return true
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            lastError = nil
            return ok
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
            return false
        }
    }
}

struct LockScreenView: View {
    @Environment(AppLockManager.self) private var lock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("RxLedger is locked")
                    .font(.title2.bold())
                if lock.isLocked {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label("Unlock with \(lock.biometryName)", systemImage: "faceid")
                            .frame(minWidth: 220, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lock.isAuthenticating)
                    if let error = lock.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .padding()
        }
    }
}

#Preview {
    LockScreenView()
        .environment(AppLockManager())
}
