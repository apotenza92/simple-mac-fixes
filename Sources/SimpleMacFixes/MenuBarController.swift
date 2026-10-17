import AppKit
import Combine
import KeyboardControlFeature
import SimpleMacFixesCore

/// System menu rows own actions and appearance; checkboxes and level controls
/// use views so toggling one leaves the menu open.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let width: CGFloat = 304

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel
    private let features: FeatureController
    private let openSettings: () -> Void
    private var observations = Set<AnyCancellable>()
    private var previousApplication: NSRunningApplication?
    private var accessibilityItem = NSMenuItem()
    private var featureItems: [Feature: NSMenuItem] = [:]
    private var conflictItems: [ConflictingApp.Area: NSMenuItem] = [:]
    private var volumeItem = NSMenuItem()
    private var brightnessItem = NSMenuItem()
    private var linkItem = NSMenuItem()
    private var displayErrorItem = NSMenuItem()
    private var audioItem = NSMenuItem()
    private var audioRow: NativeMenuSlider!
    private let displayContainer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 62))
    private var displayRows: [UInt32: NativeMenuSlider] = [:]

    init(model: AppModel, features: FeatureController, openSettings: @escaping () -> Void) {
        self.model = model
        self.features = features
        self.openSettings = openSettings
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: AppIdentity.name, action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: AppIdentity.name,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        title.isEnabled = false
        menu.addItem(title)
        accessibilityItem = action("Allow \(Self.accessibilityName)…", #selector(allowAccessibility))
        menu.addItem(accessibilityItem)

        for (index, feature) in Feature.allCases.enumerated() {
            let item = checkbox(feature.title, #selector(toggleFeature(_:)))
            (item.view?.subviews.first as? NSButton)?.identifier = NSUserInterfaceItemIdentifier(feature.rawValue)
            item.view?.toolTip = feature.detail
            featureItems[feature] = item
            menu.addItem(item)
            // One note per area, after the last switch in it.
            let next = Feature.allCases.dropFirst(index + 1).first
            if next?.conflictArea != feature.conflictArea {
                menu.addItem(conflictItem(for: feature.conflictArea))
            }
        }
        menu.addItem(.separator())

        volumeItem = checkbox("Volume keys", #selector(toggleVolume))
        volumeItem.view?.toolTip = "Volume and mute keys for audio interfaces and other outputs without Mac volume control."
        menu.addItem(volumeItem)
        audioRow = NativeMenuSlider(leading: "speaker.fill", trailing: "speaker.wave.3.fill", target: self, action: #selector(adjustVolume(_:)))
        let audioSliderItem = NSMenuItem()
        audioSliderItem.view = audioRow
        menu.addItem(audioSliderItem)
        audioItem = action("Allow System Audio Recording…", #selector(allowAudio))
        audioItem.indentationLevel = 1
        menu.addItem(audioItem)
        menu.addItem(.separator())
        brightnessItem = checkbox("Brightness keys", #selector(toggleBrightness))
        brightnessItem.view?.toolTip = "Brightness keys for external displays."
        linkItem = checkbox("Link brightness", #selector(toggleLink), indent: 1)
        menu.addItem(brightnessItem)
        menu.addItem(linkItem)
        let displaysItem = NSMenuItem()
        displaysItem.view = displayContainer
        menu.addItem(displaysItem)
        displayErrorItem.title = "Couldn’t change display"
        displayErrorItem.isEnabled = false
        displayErrorItem.isHidden = true
        menu.addItem(displayErrorItem)
        menu.addItem(conflictItem(for: .keyboardControl))
        menu.addItem(.separator())

        menu.addItem(action("Settings…", #selector(showSettings), key: ","))
        menu.addItem(action("Quit \(AppIdentity.name)", #selector(quit), key: "q"))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(openMenu)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.image = AppIdentity.menuImage
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(AppIdentity.name)
            button.toolTip = AppIdentity.name
        }
        for publisher in [model.objectWillChange.eraseToAnyPublisher(),
                          model.audio.objectWillChange.eraseToAnyPublisher(),
                          model.brightness.objectWillChange.eraseToAnyPublisher(),
                          model.displayConnections.objectWillChange.eraseToAnyPublisher(),
                          features.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }
                .store(in: &observations)
        }
        refresh()
        if AppIdentity.isDevelopmentBuild, ProcessInfo.processInfo.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openMenu()
            }
        }
    }

    private static var accessibilityName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control" : "Accessibility"
    }

    @objc private func openMenu() {
        guard let button = statusItem.button else { return }
        // AppKit draws embedded controls as inactive unless their application is
        // active. Activate before tracking starts, rather than recoloring cells.
        previousApplication = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu = menu
        button.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    func menuDidClose(_ closedMenu: NSMenu) {
        guard closedMenu === menu else { return }
        statusItem.menu = nil
        // Assigning a status menu replaces the button's action. Restore our
        // activation path for every subsequent opening, including right-click.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openMenu)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        let previous = previousApplication
        previousApplication = nil
        // Menu actions run after the menu closes; let Settings take focus first,
        // and never steal focus back from an application the user chose.
        DispatchQueue.main.async {
            if NSApp.isActive, NSApp.keyWindow == nil,
               previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous?.activate(options: [])
            }
        }
    }

    private func refresh() {
        accessibilityItem.isHidden = model.hasAccessibilityPermission
        for (feature, item) in featureItems {
            setCheckbox(item, checked: features.isEnabled(feature))
        }
        for (area, item) in conflictItems {
            let names = features.conflicts(in: area).map(\.name).joined(separator: " and ")
            item.isHidden = names.isEmpty || !isEnabled(area)
            item.title = "\(names) is also running"
            item.toolTip = "Quit \(names) or turn this off so the same thing isn’t done twice."
        }

        setCheckbox(volumeItem, checked: model.audio.isEnabled)
        setCheckbox(brightnessItem, checked: model.brightness.isEnabled)
        setCheckbox(linkItem, checked: model.brightness.isLinked, enabled: model.brightness.isEnabled)
        audioRow.update(title: model.audio.isEnabled ? (model.audio.deviceName ?? "Audio Output") : "Volume keys off",
                        value: model.audio.level.isMuted ? 0 : Double(model.audio.level.percent),
                        enabled: model.audio.isEnabled && model.audio.canAdjustVolume)
        switch model.audio.state {
        case .native, .active: audioItem.isHidden = true
        case .stopped, .failed: audioItem.isHidden = !model.audio.isEnabled
        }
        refreshDisplays()
        displayErrorItem.isHidden = model.displayConnections.errorMessage == nil
        displayErrorItem.toolTip = model.displayConnections.errorMessage
        linkItem.isHidden = model.brightness.displays.count < 2
        linkItem.isEnabled = model.brightness.isEnabled
    }

    private func isEnabled(_ area: ConflictingApp.Area) -> Bool {
        if area == .keyboardControl { return model.audio.isEnabled || model.brightness.isEnabled }
        return Feature.allCases.contains { $0.conflictArea == area && features.isEnabled($0) }
    }

    private func conflictItem(for area: ConflictingApp.Area) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        item.indentationLevel = 1
        conflictItems[area] = item
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleFeature(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let feature = Feature(rawValue: raw) else { return }
        features.setEnabled(feature, sender.state == .on)
    }
    @objc private func toggleVolume() { model.audio.isEnabled.toggle() }
    @objc private func toggleBrightness() { model.brightness.isEnabled.toggle() }
    @objc private func toggleLink() { model.brightness.isLinked.toggle() }
    @objc private func allowAudio() { model.requestSystemAudio() }
    @objc private func quit() { model.quit() }
    @objc private func showSettings() { openSettings() }
    @objc private func allowAccessibility() {
        if !model.hasAccessibilityPermission { model.requestAccessibility() }
        model.openPrivacySettings(.accessibility)
    }

    private func checkbox(_ title: String, _ selector: Selector, indent: Int = 0) -> NSMenuItem {
        let item = action(title, selector)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 28))
        let button = NSButton(checkboxWithTitle: title, target: self, action: selector)
        let inset = 14 + CGFloat(indent) * 20
        button.frame = NSRect(x: inset, y: 3, width: Self.width - inset - 14, height: 22)
        button.font = .menuFont(ofSize: 0)
        row.addSubview(button)
        item.view = row
        return item
    }

    private func setCheckbox(_ item: NSMenuItem, checked: Bool, enabled: Bool = true) {
        item.isEnabled = enabled
        guard let button = item.view?.subviews.first as? NSButton else { return }
        button.state = checked ? .on : .off
        button.isEnabled = enabled
    }

    private func refreshDisplays() {
        // The online brightness list loses disabled displays. Connection inventory
        // retains them; brightness remains a separate capability and key toggle.
        let brightness = model.brightness.displays
        let displays = model.displayConnections.displays.isEmpty
            ? brightness.map { DisplayConnectionController.Display(id: $0.id, key: "", name: $0.name,
                isEnabled: true, canToggle: false, physical: false) }
            : model.displayConnections.displays
        let ids = Set(displays.map(\.id))
        for id in Array(displayRows.keys) where !ids.contains(id) {
            displayRows.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, display) in displays.enumerated() {
            let row: NativeMenuSlider
            if let existing = displayRows[display.id] { row = existing }
            else {
                row = NativeMenuSlider(leading: "sun.min.fill", trailing: "sun.max.fill", target: self, action: #selector(adjustBrightness(_:)))
                row.slider.tag = Int(display.id)
                row.displayToggle.target = self
                row.displayToggle.action = #selector(toggleDisplay(_:))
                displayRows[display.id] = row
                displayContainer.addSubview(row)
            }
            row.frame.origin.y = CGFloat(displays.count - index - 1) * 62
            let level = brightness.first { $0.id == display.id }
            row.update(title: display.name, value: Double(level?.percent ?? 100),
                enabled: display.isEnabled && model.brightness.isEnabled && level?.canAdjust == true)
            row.updateDisplayToggle(key: display.key, title: display.name,
                visible: model.displayConnections.showsCheckboxes && display.physical,
                checked: display.isEnabled,
                enabled: display.canToggle && !model.displayConnections.isChanging)
        }
        let height = CGFloat(displays.count) * 62
        if displayContainer.frame.height != height {
            displayContainer.setFrameSize(NSSize(width: Self.width, height: height))
            menu.update()
        }
    }

    @objc private func adjustVolume(_ sender: NSSlider) {
        model.audio.setVolume(Int(sender.doubleValue.rounded()))
    }
    @objc private func adjustBrightness(_ sender: NSSlider) {
        model.brightness.set(Int(sender.doubleValue.rounded()), for: UInt32(sender.tag))
    }
    @objc private func toggleDisplay(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        model.displayConnections.setEnabled(sender.state == .on, for: key)
    }
}

/// Standard AppKit controls inherit menu appearance and the user's system accent.
@MainActor
private final class NativeMenuSlider: NSView {
    let slider: NSSlider
    let displayToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")

    init(leading: String, trailing: String, target: AnyObject, action: Selector) {
        slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 62))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 14, y: 36, width: 276, height: 18)
        addSubview(titleLabel)
        displayToggle.frame = NSRect(x: 272, y: 35, width: 20, height: 20)
        displayToggle.isHidden = true
        displayToggle.toolTip = "Enable or Disable this display."
        addSubview(displayToggle)
        slider.isContinuous = true
        slider.frame = NSRect(x: 40, y: 6, width: 222, height: 24)
        addSubview(slider)
        for (symbol, x) in [(leading, 14.0), (trailing, 272.0)] {
            let image = NSImageView(frame: NSRect(x: x, y: 10, width: 18, height: 18))
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.contentTintColor = .secondaryLabelColor
            addSubview(image)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, value: Double, enabled: Bool) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        slider.setAccessibilityLabel(title)
        slider.doubleValue = value
        slider.isEnabled = enabled
    }

    func updateDisplayToggle(key: String, title: String, visible: Bool, checked: Bool, enabled: Bool) {
        displayToggle.identifier = NSUserInterfaceItemIdentifier(key)
        displayToggle.isHidden = !visible
        displayToggle.state = checked ? .on : .off
        displayToggle.isEnabled = enabled
        displayToggle.setAccessibilityLabel("Enable or Disable \(title)")
        titleLabel.frame.size.width = visible ? 250 : 276
    }
}
