import XCTest
@testable import MaximizeFeature

final class ElectronAccessibilityTests: XCTestCase {
    func testAnAppWithTheElectronFrameworkCountsAsElectron() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let electron = root.appendingPathComponent("Some.app")
        try FileManager.default.createDirectory(
            at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true
        )
        let native = root.appendingPathComponent("Native.app")
        try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ElectronAccessibility.isElectron(electron))
        XCTAssertFalse(ElectronAccessibility.isElectron(native))
        try? FileManager.default.removeItem(at: root)
    }
}
