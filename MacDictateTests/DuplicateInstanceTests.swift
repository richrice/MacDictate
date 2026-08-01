import XCTest
@testable import MacDictate

@MainActor
final class DuplicateInstanceTests: XCTestCase {
    private let bundleID = "com.macdictate.app"

    func testAnotherProcessWithTheSameBundleIdentifierIsADuplicate() {
        XCTAssertTrue(AppDelegate.isDuplicateInstance(
            bundleIdentifier: bundleID,
            ownProcessID: 100,
            runningInstances: [
                ("com.apple.finder", 42),
                (bundleID, 55)
            ]
        ))
    }

    func testOwnProcessIsNotADuplicate() {
        XCTAssertFalse(AppDelegate.isDuplicateInstance(
            bundleIdentifier: bundleID,
            ownProcessID: 100,
            runningInstances: [
                ("com.apple.finder", 42),
                (bundleID, 100)
            ]
        ))
    }

    func testOtherApplicationsAreNotDuplicates() {
        XCTAssertFalse(AppDelegate.isDuplicateInstance(
            bundleIdentifier: bundleID,
            ownProcessID: 100,
            runningInstances: [
                ("com.apple.finder", 42),
                ("com.macdictate.tests", 55),
                (nil, 56)
            ]
        ))
    }

    /// An unbundled binary cannot identify siblings, so it must not block
    /// itself on the first entry that happens to carry no bundle identifier.
    func testMissingBundleIdentifierIsNeverADuplicate() {
        XCTAssertFalse(AppDelegate.isDuplicateInstance(
            bundleIdentifier: nil,
            ownProcessID: 100,
            runningInstances: [(nil, 55)]
        ))
    }
}
