import Foundation

/// Keeps an auto-hiding Dock up while a preview is open, so pointing at the
/// preview doesn't drop the Dock out from under it.
///
/// Uses the Dock's own auto-hide switch, turned off while the preview shows and
/// back on when it closes. A crash mid-preview is undone on the next start.
enum DockAutoHideHold {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let get = dlsym(handle, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: Get.self) }
    private static let set = dlsym(handle, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: Set.self) }
    private static let heldKey = "dockPreviews.heldAutoHide"

    @MainActor private static var holding = false

    @MainActor static func hold() {
        guard !holding, let get, let set, get() else { return }
        UserDefaults.standard.set(true, forKey: heldKey)
        holding = true
        set(false)
    }

    @MainActor static func release() {
        guard holding else { return }
        holding = false
        set?(true)
        UserDefaults.standard.removeObject(forKey: heldKey)
    }

    /// Puts auto-hide back if a previous run stopped while holding the Dock up.
    @MainActor static func recover() {
        guard UserDefaults.standard.bool(forKey: heldKey) else { return }
        set?(true)
        UserDefaults.standard.removeObject(forKey: heldKey)
    }
}
