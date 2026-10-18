import AppKit
import KeyboardControlFeature
import SimpleMacFixesCore
import SwiftUI

/// Every setting lives here; the menu bar icon only opens this window or quits.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var features: FeatureController
    @ObservedObject var menuBarIcon: MenuBarIconSetting
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updates: UpdateManager
    @ObservedObject var audio: AudioController
    @ObservedObject var brightness: DDCController
    @ObservedObject var displayConnections: DisplayConnectionController

    var body: some View {
        Form {
            Section("Fixes") {
                ForEach(Feature.allCases) { feature in
                    Toggle(isOn: Binding(
                        get: { features.isEnabled(feature) },
                        set: { features.setEnabled(feature, $0) }
                    )) {
                        Text(feature.title)
                        Text(feature.detail)
                    }
                    if isLastInArea(feature) {
                        conflictNote(for: feature.conflictArea, active: features.isEnabled(feature))
                    }
                }
            }

            Section("Volume") {
                Toggle(isOn: $audio.isEnabled) {
                    Text("Volume keys")
                    Text("The volume keys also work with speakers and audio devices that usually ignore them.")
                }
                LabeledContent(audio.isEnabled ? (audio.deviceName ?? "Audio Output") : "Volume keys off") {
                    levelSlider(value: audio.level.isMuted ? 0 : audio.level.percent,
                                leading: "speaker.fill", trailing: "speaker.wave.3.fill") { audio.setVolume($0) }
                        .disabled(!audio.isEnabled || !audio.canAdjustVolume)
                }
            }

            Section("Brightness") {
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
            }

            Section("General") {
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

            Section("Updates") {
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
            }

            Section("Permissions") {
                PermissionsView(model: model)
                    .padding(.vertical, 4)
            }

            Section {
                Button("Show Setup Guide…") { model.showSetupGuide() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
    }

    private func isLastInArea(_ feature: Feature) -> Bool {
        guard let index = Feature.allCases.firstIndex(of: feature) else { return false }
        return Feature.allCases.dropFirst(index + 1).first?.conflictArea != feature.conflictArea
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

    private func levelSlider(value: Int, leading: String, trailing: String,
                             set: @escaping (Int) -> Void) -> some View {
        Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: 0...100) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: leading).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: trailing).foregroundStyle(.secondary)
        }
        .frame(width: 220)
    }
}

@MainActor
final class SettingsWindowController {
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
            let view = SettingsView(model: model, features: features, menuBarIcon: menuBarIcon,
                                    launchAtLogin: model.launchAtLogin, updates: updates,
                                    audio: model.audio, brightness: model.brightness,
                                    displayConnections: model.displayConnections)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "\(AppIdentity.name) Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
