import AppKit
import KeyboardControlFeature
import SimpleMacFixesCore
import SwiftUI

/// The tabs along the top of Settings, as in the system's own apps. The toolbar sizes each
/// tab to its label, so every label is one short word and the tabs come out evenly spaced.
enum SettingsTab: String, CaseIterable {
    case general, dock, windows, finder, mouse, keyboard

    var title: String {
        switch self {
        case .general: "General"
        case .dock: "Dock"
        case .windows: "Windows"
        case .finder: "Finder"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dock: "dock.rectangle"
        case .windows: "macwindow.on.rectangle"
        case .finder: "folder"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        }
    }

    /// The fixes on this tab, in the catalog's order.
    var features: [Feature] { Feature.allCases.filter { $0.settingsTab == self } }
}

extension Feature {
    /// Every fix is on one tab; a new fix does not build until it has one.
    var settingsTab: SettingsTab {
        switch self {
        case .finderCut: .finder
        case .mouseScrollReversal: .mouse
        case .greenButtonMaximize, .instantSpaces, .desktopShortcuts: .windows
        case .dockWindowPreviews, .dockFolderFinder, .instantDock: .dock
        }
    }
}

/// One tab of Settings. Every setting lives in Settings; the menu bar icon only opens
/// this window or quits.
struct SettingsView: View {
    let tab: SettingsTab
    @ObservedObject var model: AppModel
    @ObservedObject var features: FeatureController
    @ObservedObject var menuBarIcon: MenuBarIconSetting
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updates: UpdateManager
    @ObservedObject var audio: AudioController
    @ObservedObject var brightness: DDCController
    @ObservedObject var displayConnections: DisplayConnectionController
    @State private var confirmsReset = false

    var body: some View {
        Form {
            switch tab {
            case .general: general
            case .keyboard: keys
            case .dock, .windows, .finder, .mouse: fixes
            }
        }
        .formStyle(.grouped)
        // Fills the window, which takes the tab's height; the content stays at the top while
        // the window grows or shrinks.
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var fixes: some View {
        Section {
            ForEach(tab.features) { feature in
                Group {
                    Toggle(isOn: Binding(
                        get: { features.isEnabled(feature) },
                        set: { features.setEnabled(feature, $0) }
                    )) {
                        Text(feature.title)
                        // Inside the switch's own row, so the shortcuts stay with it.
                        if feature.shortcuts.isEmpty {
                            Text(feature.detail)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(feature.detail)
                                ShortcutList(shortcuts: feature.shortcuts)
                            }
                        }
                    }
                }
                // A fix that needs another sits under it, and waits while that's off.
                .padding(.leading, feature.parent == nil ? 0 : 20)
                .disabled(feature.parent.map { !features.isActive($0) } ?? false)
                if isLastInArea(feature) {
                    conflictNote(for: feature.conflictArea,
                                 active: Feature.allCases.contains { $0.conflictArea == feature.conflictArea && features.isActive($0) })
                }
            }
        }
    }

    @ViewBuilder
    private var keys: some View {
        Section {
            Toggle(isOn: $audio.isEnabled) {
                Text("Volume keys")
                Text("The volume keys also work with speakers and audio devices that usually ignore them.")
            }
            LabeledContent(audio.isEnabled ? (audio.deviceName ?? "Audio Output") : "Volume keys off") {
                levelSlider(value: audio.level.isMuted ? 0 : audio.level.percent,
                            leading: "speaker.fill", trailing: "speaker.wave.3.fill") { audio.setVolume($0) }
                    .disabled(!audio.isEnabled || !audio.canAdjustVolume)
            }
        } header: {
            heading("Volume", "How loud your Mac plays, from the volume keys or the slider.")
        }

        Section {
            Toggle(isOn: $brightness.isEnabled) {
                Text("Brightness keys")
                Text("The brightness keys also work with external monitors.")
            }
            if brightness.displays.count > 1 {
                Toggle(isOn: $brightness.isLinked) {
                    Text("Link brightness")
                    Text("Change the brightness of all screens together.")
                }
                    .disabled(!brightness.isEnabled)
            }
            ForEach(displays, id: \.id) { display in
                let level = brightness.displays.first { $0.id == display.id }
                LabeledContent {
                    levelSlider(value: level?.percent ?? 100, leading: "sun.min.fill", trailing: "sun.max.fill") {
                        brightness.set($0, for: display.id)
                    }
                    .disabled(!display.isEnabled || !brightness.isEnabled || level?.canAdjust != true)
                } label: {
                    if displayConnections.showsCheckboxes && display.physical {
                        Toggle(display.name, isOn: Binding(
                            get: { display.isEnabled },
                            set: { displayConnections.setEnabled($0, for: display.key) }
                        ))
                        .disabled(!display.canToggle || displayConnections.isChanging)
                        .help("Enable or Disable this display.")
                    } else {
                        Text(display.name)
                    }
                }
            }
            if let error = displayConnections.errorMessage {
                Text("Couldn’t change display").foregroundStyle(.secondary).help(error)
            }
            conflictNote(for: .keyboardControl, active: audio.isEnabled || brightness.isEnabled)
        } header: {
            heading("Brightness", "How bright each screen is, from the brightness keys or the sliders.")
        }
    }

    /// A section's name with a line or two about it under it.
    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.callout)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var general: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if let error = launchAtLogin.errorMessage {
                Text(error).foregroundStyle(.secondary)
            }
            Toggle(isOn: $menuBarIcon.isShown) {
                Text("Show in menu bar")
                if !menuBarIcon.isShown {
                    Text("To return to Settings, open \(AppIdentity.name) again.")
                }
            }
        }

        Section {
            if updates.isAvailable {
                Picker("Check for updates", selection: Binding(
                    get: { updates.schedule },
                    set: { updates.setSchedule($0) }
                )) {
                    ForEach(UpdateCheckSchedule.allCases, id: \.self) { schedule in
                        Text(schedule.title).tag(schedule)
                    }
                }
                Button("Check Now…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            } else {
                Text("Updates are available in release builds.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            heading("Updates", "\(AppIdentity.name) can look for a new version and install it for you.")
        }

        Section {
            PermissionsView(model: model)
                .padding(.vertical, 4)
        } header: {
            heading("Permissions", "What your Mac must allow for the fixes to work. Open Settings takes you to the place to allow it.")
        }

        Section {
            Button("Reset Settings…") { confirmsReset = true }
        }
        .alert("Reset all settings?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive, action: resetSettings)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All switches go back to how they were when you first installed \(AppIdentity.name). "
                 + "Launch at login, your screens and permissions stay as they are.")
        }
    }

    /// Back to how a new install starts. Launch at login is left alone: turning it off
    /// would stop the app from opening at the next login. Screens turned off or on, and
    /// permissions, are not settings of the app.
    private func resetSettings() {
        features.resetToDefaults()
        audio.isEnabled = true
        brightness.isEnabled = true
        brightness.isLinked = false
        menuBarIcon.isShown = true
        updates.resetSchedule()
    }

    private func isLastInArea(_ feature: Feature) -> Bool {
        guard let index = tab.features.firstIndex(of: feature) else { return false }
        return tab.features.dropFirst(index + 1).first?.conflictArea != feature.conflictArea
    }

    @ViewBuilder
    private func conflictNote(for area: ConflictingApp.Area, active: Bool) -> some View {
        let names = features.conflicts(in: area).map(\.name).joined(separator: " and ")
        if active, !names.isEmpty {
            Label("\(names) is also running. Quit it or turn this off so the same thing isn’t done twice.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    /// The online brightness list loses disabled displays; the connection inventory keeps them.
    private var displays: [DisplayConnectionController.Display] {
        displayConnections.displays.isEmpty
            ? brightness.displays.map { .init(id: $0.id, key: "", name: $0.name,
                                              isEnabled: true, canToggle: false, physical: false) }
            : displayConnections.displays
    }

    private func levelSlider(value: Double, leading: String, trailing: String,
                             set: @escaping (Double) -> Void) -> some View {
        Slider(value: Binding(get: { value }, set: set), in: 0...100) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: leading).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: trailing).foregroundStyle(.secondary)
        }
        .frame(width: 220)
    }
}

extension SettingsTab {
    var size: CGSize { CGSize(width: 520, height: height) }

    /// Tall enough for the tab's usual content; a longer one scrolls. The window takes
    /// each tab's height as it changes tab, as the system's own Settings windows do.
    var height: CGFloat {
        switch self {
        case .general: 620
        case .dock: 255
        case .windows: 370
        // Room for a note about another app that does the same thing.
        case .finder, .mouse: 150
        case .keyboard: 490
        }
    }
}

@MainActor
final class SettingsWindowController {
    private static let tabKey = "settingsTab"
    private let model: AppModel
    private let features: FeatureController
    private let menuBarIcon: MenuBarIconSetting
    private let updates: UpdateManager
    private var window: NSWindow?

    init(model: AppModel, features: FeatureController, menuBarIcon: MenuBarIconSetting, updates: UpdateManager) {
        self.model = model
        self.features = features
        self.menuBarIcon = menuBarIcon
        self.updates = updates
    }

    func show() {
        if window == nil {
            // The system's toolbar tabs, the same control SwiftUI's own Settings window uses.
            let tabs = SettingsTabsController()
            tabs.tabStyle = .toolbar
            // The new tab shows at once, as in Apple's own Settings windows; only the window's
            // size animates. A crossfade waited for the resize and showed both tabs at once.
            tabs.transitionOptions = [.allowUserInteraction]
            for tab in SettingsTab.allCases {
                let view = SettingsView(tab: tab, model: model, features: features, menuBarIcon: menuBarIcon,
                                        launchAtLogin: model.launchAtLogin, updates: updates,
                                        audio: model.audio, brightness: model.brightness,
                                        displayConnections: model.displayConnections)
                let host = NSHostingController(rootView: view)
                // The window takes each tab's size itself (`SettingsTabsController`).
                host.sizingOptions = []
                // Loaded now, so a tab shows at once the first time it is picked.
                host.view.frame = CGRect(origin: .zero, size: tab.size)
                host.view.layoutSubtreeIfNeeded()
                // The window's title, as in the system's own Settings windows.
                host.title = tab.title
                let item = NSTabViewItem(viewController: host)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                item.identifier = tab.rawValue
                tabs.addTabViewItem(item)
            }
            let saved = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(SettingsTab.init(rawValue:))
            tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: saved ?? .general) ?? 0
            tabs.selectionChanged = { tab in UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.setContentSize((saved ?? .general).size)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Grows or shrinks the window to each tab, and remembers the tab, so Settings opens
/// where it was left.
private final class SettingsTabsController: NSTabViewController {
    var selectionChanged: (SettingsTab) -> Void = { _ in }

    /// The tab control does not resize the window. As in Apple's own Settings windows, the
    /// new tab shows at once and the window grows or shrinks to it at the system's resize
    /// speed, keeping its top in place. `setFrame(_:display:animate:)` blocks until it ends,
    /// so the tab changed only after it; the animator runs alongside. None with Reduce Motion.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) else { return }
        selectionChanged(tab)
        guard let window = view.window, window.isVisible else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let frame = window.frameRect(forContentRect: CGRect(x: content.minX, y: content.maxY - tab.size.height,
                                                            width: tab.size.width, height: tab.size.height))
        guard frame != window.frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// Keyboard shortcuts as keycaps beside what they do.
private struct ShortcutList: View {
    let shortcuts: [(keys: [String], action: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    GridRow {
                        HStack(spacing: 3) {
                            ForEach(shortcuts[index].keys, id: \.self) { key in
                                Text(key)
                                    .font(.callout)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        Text(shortcuts[index].action)
                    }
                }
            }
            Text(Feature.keyNames)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
