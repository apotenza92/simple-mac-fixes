import CoreGraphics
import Foundation

public enum MediaKey: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown

    public var isBrightness: Bool {
        self == .brightnessUp || self == .brightnessDown
    }
}

public enum MediaKeyEvent {
    // IOKit/hidsystem/ev_keymap.h key types. The header does not import these
    // constants into Swift.
    private static let soundUp: Int64 = 0
    private static let soundDown: Int64 = 1
    private static let brightnessUp: Int64 = 2
    private static let brightnessDown: Int64 = 3
    private static let mute: Int64 = 7

    public static func decode(data1: Int64) -> (key: MediaKey, isKeyDown: Bool)? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        let key: MediaKey
        switch keyCode {
        case soundUp: key = .volumeUp
        case soundDown: key = .volumeDown
        case mute: key = .mute
        case brightnessUp: key = .brightnessUp
        case brightnessDown: key = .brightnessDown
        default: return nil
        }
        return (key, state == 0x0A)
    }

    public static func decodeFunctionKey(keyCode: Int64) -> MediaKey? {
        switch keyCode {
        case 122, 107: return .brightnessDown // F1 or F14
        case 120, 113: return .brightnessUp   // F2 or F15
        default: return nil
        }
    }
}
