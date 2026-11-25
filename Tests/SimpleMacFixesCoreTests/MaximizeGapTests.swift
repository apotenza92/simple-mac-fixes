import XCTest
@testable import SimpleMacFixesCore

final class MaximizeGapTests: XCTestCase {
    func testChoicesAreOffAndThreeSizesInPoints() {
        XCTAssertEqual(MaximizeGap.allCases.map(\.rawValue), [0, 8, 16, 32])
        XCTAssertEqual(MaximizeGap.allCases.map(\.title), ["Off", "Small", "Medium", "Large"])
    }

    func testANewInstallAndAnUnknownValueAreOff() {
        XCTAssertEqual(MaximizeGap.resolve(saved: nil), .off)
        XCTAssertEqual(MaximizeGap.resolve(saved: 12), .off)
        XCTAssertEqual(MaximizeGap.resolve(saved: 16), .medium)
    }
}
