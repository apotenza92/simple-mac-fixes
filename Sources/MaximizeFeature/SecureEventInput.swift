import Darwin
import Foundation

enum SecureEventInput {
    private typealias IsSecureEventInputEnabledFn = @convention(c) () -> DarwinBoolean

    static func isEnabled() -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IsSecureEventInputEnabled") else {
            return false
        }
        let function = unsafeBitCast(symbol, to: IsSecureEventInputEnabledFn.self)
        return function().boolValue
    }
}
