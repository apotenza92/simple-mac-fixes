import AppKit
import ApplicationServices
import KeyboardControlFeature

@main
@MainActor
final class SimpleMacFixesApp: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var features: FeatureController?
    private var updates: UpdateManager?
    private var settings: SettingsWindowController?
    private var menuBar: MenuBarController?
    private var menuBarIcon: MenuBarIconSetting?
    private var launchedAtLogin = false

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Several fixes ask the app under the pointer about a click while the click
        // waits. The system default of 6 seconds lets one busy app freeze every
        // click; set on the system-wide element, this limit applies to every query.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        let model = AppModel()
        let features = FeatureController()
        let updates = UpdateManager()
        let menuBarIcon = MenuBarIconSetting()
        let settings = SettingsWindowController(model: model, features: features, menuBarIcon: menuBarIcon, updates: updates)
        self.menuBarIcon = menuBarIcon
        self.model = model
        self.features = features
        self.updates = updates
        self.settings = settings
        guard UpdateTestSession.current == nil else { return }
        // Accessibility changes reach every feature through the model's permission refresh.
        model.onAccessibilityChange = { [weak features] in features?.apply() }
        menuBar = MenuBarController(icon: menuBarIcon) { [weak settings] in settings?.show() }
        features.start()
        model.start()
        // Without the icon, Settings is the only way in. The setup guide covers first launch.
        if !menuBarIcon.isShown, !launchedAtLogin, model.hasCompletedSetup { settings.show() }
    }

    /// Opening the app again while it runs, from Finder, Spotlight or the Dock.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        features?.stop()
        model?.stop()
    }
}
