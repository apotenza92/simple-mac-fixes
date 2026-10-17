import Foundation

/// Opt-in release harness, scoped to one temporary app copy owned by this user.
struct UpdateTestSession: Decodable {
    let bundlePath: String
    let resultPath: String
    let feedURL: String
    let expectedBuild: String
    let expiresAt: Double

    static var current: UpdateTestSession? {
        let path = "/tmp/simplemacfixes-sparkle-test-\(getuid()).json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              attributes[.posixPermissions] as? Int == 0o600,
              let data = FileManager.default.contents(atPath: path),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.expiresAt > Date().timeIntervalSince1970,
              value.expiresAt < Date().timeIntervalSince1970 + 600,
              URL(fileURLWithPath: value.bundlePath).resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              value.bundlePath.contains("/simplemacfixes-update-test-"),
              URL(fileURLWithPath: value.resultPath).deletingLastPathComponent() == URL(fileURLWithPath: value.bundlePath).deletingLastPathComponent(),
              let url = URL(string: value.feedURL), url.scheme == "http", url.host == "127.0.0.1", url.port != nil
        else { return nil }
        return value
    }

    func record(_ result: String) {
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }
}
