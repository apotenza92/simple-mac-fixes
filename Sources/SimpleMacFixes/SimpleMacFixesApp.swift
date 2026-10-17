import AppKit
import KeyboardControlFeature

@main
@MainActor
final class SimpleMacFixesApp: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var features: FeatureController?
    private var updates: UpdateManager?
    private var settings: SettingsWindowController?
    private var menuBar: MenuBarController?

    static func main() {
        // Helper modes used by display switching; they never show UI.
        if DisplayRecoveryProcess.runIfRequested() { return }
        if DisplayConnectionPrototype.runIfRequested() { return }
        let application = NSApplication.shared
        let delegate = SimpleMacFixesApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let features = FeatureController()
        let updates = UpdateManager()
        let settings = SettingsWindowController(model: model, updates: updates)
        self.model = model
        self.features = features
        self.updates = updates
        self.settings = settings
        guard UpdateTestSession.current == nil else { return }
        // Accessibility changes reach every feature through the model's permission refresh.
        model.onAccessibilityChange = { [weak features] in features?.apply() }
        menuBar = MenuBarController(model: model, features: features) { [weak settings] in settings?.show() }
        features.start()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        features?.stop()
        model?.stop()
    }
}
