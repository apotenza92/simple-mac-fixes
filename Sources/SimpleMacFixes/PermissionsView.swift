import SwiftUI
import KeyboardControlFeature

/// Shared by Settings and the setup guide: one explanation and action per permission.
struct PermissionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var audio: AudioController
    @ObservedObject private var brightness: DDCController

    init(model: AppModel) {
        self.model = model
        audio = model.audio
        brightness = model.brightness
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            permission(
                title: keyboardPermissionTitle,
                detail: "Needed for every fix to work",
                status: nil,
                enabled: model.hasAccessibilityPermission,
                actionTitle: model.hasAccessibilityPermission ? "Open Settings" : "Allow…"
            ) {
                if !model.hasAccessibilityPermission { model.requestAccessibility() }
                model.openPrivacySettings(.accessibility)
            }

            Divider()

            permission(
                title: "Input Monitoring",
                detail: "Brightness keys on separate keyboards",
                status: nil,
                enabled: model.hasInputMonitoringPermission,
                actionTitle: model.hasInputMonitoringPermission ? "Open Settings" : "Allow…"
            ) {
                if !model.hasInputMonitoringPermission { model.requestInputMonitoring() }
                model.openPrivacySettings(.inputMonitoring)
            }

            if needsSystemAudio {
                Divider()

                permission(
                    title: "System Audio Recording",
                    detail: "Volume keys for more speakers and audio devices",
                    status: nil,
                    enabled: audio.isApplyingSoftwareGain,
                    actionTitle: canTryAudio ? "Allow…" : nil,
                    enabledLabel: "Audio control working"
                ) {
                    model.requestSystemAudio()
                }
            }
        }
    }

    private var keyboardPermissionTitle: String {
        if #available(macOS 27.0, *) {
            return "Device Control"
        }
        return "Accessibility"
    }

    private var needsRawKeys: Bool {
        brightness.isEnabled && brightness.isAvailable && !brightness.hasActiveBuiltInDisplay
    }

    private var needsSystemAudio: Bool {
        guard audio.isEnabled else { return false }
        if case .native = audio.state { return false }
        return true
    }

    private var canTryAudio: Bool {
        guard audio.isEnabled else { return false }
        switch audio.state {
        case .stopped, .failed: return true
        case .active, .native: return false
        }
    }

    private func permission(title: String, detail: String, status: String?,
                            enabled: Bool, actionTitle: String?, enabledLabel: String = "Enabled",
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                permissionHeading(title, status: status, enabled: enabled, enabledLabel: enabledLabel)
                Text(detail).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
                    .fixedSize()
            }
        }
    }

    private func permissionHeading(_ title: String, status: String?, enabled: Bool, enabledLabel: String = "Enabled") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityLabel(enabled ? enabledLabel : "Not enabled")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SetupGuideView: View {
    static let windowSize = NSSize(width: 480, height: 780)
    @ObservedObject var model: AppModel
    private var step: Int { model.setupStep }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        headerIcon
                            .frame(height: 96)
                        VStack(spacing: 8) {
                            Text(title).font(.title2.weight(.semibold))
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 20) {
                        switch step {
                        case 0:
                            feature("folder", title: "Cut and paste in Finder",
                                    detail: "Command-X and Command-V move files between folders.")
                            Divider()
                            feature("computermouse", title: "Mouse scrolling",
                                    detail: "Mice scroll in the traditional direction. Trackpads aren’t affected.")
                            Divider()
                            feature("macwindow", title: "Maximize windows",
                                    detail: "The green button makes a window fill the screen.")
                            Divider()
                            feature("rectangle.split.3x1", title: "Desktops",
                                    detail: "Switch desktops straight away, without the slide. Control-Option-Command and a number jumps to that desktop.")
                            Divider()
                            feature("dock.rectangle", title: "The Dock",
                                    detail: "Click an app with several windows to choose one. Option-click a folder to open it. A hidden Dock appears straight away.")
                            Divider()
                            feature("speaker.wave.2", title: "Volume and brightness",
                                    detail: "Volume and brightness keys work with more speakers and screens.")
                        case 1:
                            PermissionsView(model: model)
                        default:
                            feature("switch.2", title: "Everything is on",
                                    detail: "Turn any fix off in Settings.")
                            Divider()
                            feature("gearshape", title: "Settings",
                                    detail: "Open Settings from the menu bar icon. If you hide the icon, open \(AppIdentity.name) again to get back.")
                            Divider()
                            feature("arrow.triangle.merge", title: "Replaces older apps",
                                    detail: "Macsimize, Dockmint and Simple Mac Keyboard Control quit automatically. Apps like LinearMouse quit while a matching fix is on.")
                            Text("You can return to this guide from Settings at any time.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel("Step \(step + 1) of 3")
                Spacer()
                if step > 0 {
                    Button("Back") { model.setupStep -= 1 }
                }
                Button(step == 0 ? "Get Started" : step == 1 ? "Continue" : "Done") {
                    if step == 2 { model.finishSetup() } else { model.setupStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .font(.body)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch step {
        case 0:
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityLabel("\(AppIdentity.name) app icon")
        case 1:
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        default:
            Image(nsImage: AppIdentity.makeMenuImage(pointSize: 88))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .accessibilityLabel("\(AppIdentity.name) menu bar icon")
        }
    }

    private var title: String {
        switch step {
        case 0: return "Welcome"
        case 1: return "Allow access"
        default: return "Find this icon in your menu bar"
        }
    }

    private var subtitle: String {
        switch step {
        case 0: return AppIdentity.name
        case 1: return "macOS asks before apps can change how your Mac responds."
        default: return "Your fixes and controls are here."
        }
    }

    private func feature(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 28)
                .foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
