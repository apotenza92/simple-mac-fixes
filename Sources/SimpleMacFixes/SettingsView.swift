import AppKit
import KeyboardControlFeature
import SimpleMacFixesCore
import SwiftUI

/// Everything that is not a menu toggle: startup, updates, permissions and help.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).foregroundStyle(.secondary)
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private let updates: UpdateManager
    private var window: NSWindow?

    init(model: AppModel, updates: UpdateManager) {
        self.model = model
        self.updates = updates
    }

    func show() {
        if window == nil {
            let view = SettingsView(model: model, launchAtLogin: model.launchAtLogin, updates: updates)
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
