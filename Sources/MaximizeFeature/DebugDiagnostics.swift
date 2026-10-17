import Combine
import Foundation
import os

final class DebugDiagnostics: ObservableObject, @unchecked Sendable {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private let logger = Logger(subsystem: "com.apotenza.SimpleMacFixes", category: "GreenButtonMaximize")
    private let maxEntries = 40
    private var isEnabled: (() -> Bool)?

    @Published private(set) var entries: [Entry] = []

    func setEnabledProvider(_ provider: @escaping () -> Bool) {
        isEnabled = provider
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    func logMessage(_ message: String, forceVisible: Bool = false) {
        logger.notice("\(message, privacy: .public)")
        RuntimeLogger.log(message)

        guard forceVisible || isEnabled?() == true else {
            return
        }

        let entry = Entry(timestamp: Date(), message: message)
        let maxEntries = self.maxEntries
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.entries.insert(entry, at: 0)
            self.entries = Array(self.entries.prefix(maxEntries))
        }
    }

    func logClickContext(_ context: ClickedWindowContext, chosenPath: String, notes: [String] = []) {
        let actionList = context.availableActions.joined(separator: ", ")
        let noteSuffix = notes.isEmpty ? "" : " | notes=\(notes.joined(separator: "; "))"
        let message = "app=\(context.appDescriptor) pid=\(context.pid) role=\(context.elementRole ?? "-") subrole=\(context.elementSubrole ?? "-") actions=[\(actionList)] settable(position=\(context.canSetPosition), size=\(context.canSetSize)) path=\(chosenPath)\(noteSuffix)"
        logMessage(message)
    }
}
