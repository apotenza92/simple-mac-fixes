import Foundation

/// Windows-style cut and paste for files in Finder.
///
/// Finder already moves copied files with Command-Option-V, so Command-X
/// becomes a copy that remembers it was a cut, and the next Command-V in
/// Finder becomes a move. Any later change to the pasteboard cancels the cut.
public struct FinderCutTracker: Equatable {
    public enum Shortcut: Equatable { case cut, paste, other }

    public enum Decision: Equatable {
        case passThrough
        case copyInsteadOfCut
        case moveInsteadOfPaste
    }

    public enum Pending: Equatable {
        case none
        /// Finder has been asked to copy; the pasteboard still holds `previousChangeCount`.
        case awaitingCopy(previousChangeCount: Int)
        /// Finder copied the cut files at `changeCount`.
        case ready(changeCount: Int)
    }

    public private(set) var pending: Pending = .none

    public init() {}

    public static func shortcut(characters: String?, commandOnly: Bool) -> Shortcut {
        guard commandOnly else { return .other }
        switch characters?.lowercased() {
        case "x": return .cut
        case "v": return .paste
        default: return .other
        }
    }

    public mutating func handle(
        _ shortcut: Shortcut,
        finderIsFrontmost: Bool,
        textInputFocused: Bool,
        pasteboardChangeCount: Int
    ) -> Decision {
        // Pasting cut files into another app is an ordinary copy and keeps the cut,
        // and text fields inside Finder (rename, search, Go to Folder) keep normal editing.
        guard shortcut != .other, finderIsFrontmost, !textInputFocused else { return .passThrough }
        switch shortcut {
        case .cut:
            pending = .awaitingCopy(previousChangeCount: pasteboardChangeCount)
            return .copyInsteadOfCut
        case .paste:
            let isCut: Bool
            switch pending {
            case .none: isCut = false
            case let .awaitingCopy(previous): isCut = pasteboardChangeCount != previous
            case let .ready(changeCount): isCut = pasteboardChangeCount == changeCount
            }
            pending = .none
            return isCut ? .moveInsteadOfPaste : .passThrough
        case .other:
            return .passThrough
        }
    }

    /// Call shortly after `copyInsteadOfCut` once Finder has written the pasteboard.
    public mutating func copyFinished(pasteboardChangeCount: Int) {
        guard case let .awaitingCopy(previous) = pending else { return }
        // An unchanged pasteboard means nothing was selected.
        pending = pasteboardChangeCount == previous ? .none : .ready(changeCount: pasteboardChangeCount)
    }
}
