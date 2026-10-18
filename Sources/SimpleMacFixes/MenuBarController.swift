import AppKit
import Combine

/// Whether the menu bar icon is shown. With it hidden, opening the app again shows Settings.
@MainActor
final class MenuBarIconSetting: ObservableObject {
    private static let key = "showMenuBarIcon"
    private let defaults: UserDefaults

    @Published var isShown: Bool {
        didSet { defaults.set(isShown, forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.key: true])
        isShown = defaults.bool(forKey: Self.key)
    }
}

/// The menu holds only Settings and Quit; every setting is in the Settings window.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openSettings: () -> Void
    private var observation: AnyCancellable?

    init(icon: MenuBarIconSetting, openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.addItem(action("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit \(AppIdentity.name)", #selector(quit), key: "q"))
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = AppIdentity.menuImage
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(AppIdentity.name)
            button.toolTip = AppIdentity.name
        }
        observation = icon.$isShown.sink { [weak self] in self?.statusItem.isVisible = $0 }
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
