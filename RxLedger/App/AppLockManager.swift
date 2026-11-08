import SwiftUI

/// Placeholder; Face ID lock is implemented in step 5.
@Observable
final class AppLockManager {
    init(previewUnlocked: Bool = false) {}
    func shouldObscureContent(scenePhase: ScenePhase) -> Bool { false }
    func handle(scenePhase: ScenePhase) {}
}

struct LockScreenView: View {
    var body: some View { Color.clear }
}
