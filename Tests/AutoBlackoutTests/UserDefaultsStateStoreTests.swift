import XCTest
@testable import AutoBlackout

final class UserDefaultsStateStoreTests: ScratchTestCase {
    func testStartsEmpty() {
        let store = UserDefaultsStateStore(defaults: defaults)
        XCTAssertNil(store.lastKnownBuiltInID)
        XCTAssertNil(store.managedDisplayID)
    }

    func testRoundTripsBothValuesIndependently() {
        let store = UserDefaultsStateStore(defaults: defaults)
        store.lastKnownBuiltInID = 1
        store.managedDisplayID = 42
        XCTAssertEqual(store.lastKnownBuiltInID, 1)
        XCTAssertEqual(store.managedDisplayID, 42)

        store.managedDisplayID = nil
        XCTAssertEqual(store.lastKnownBuiltInID, 1)
        XCTAssertNil(store.managedDisplayID)
    }

    func testValuesSurviveANewInstance() {
        // A separate `--restore` process reads what the app wrote.
        UserDefaultsStateStore(defaults: defaults).managedDisplayID = 7
        XCTAssertEqual(UserDefaultsStateStore(defaults: defaults).managedDisplayID, 7)
    }

    func testLargeDisplayIDsRoundTrip() {
        let store = UserDefaultsStateStore(defaults: defaults)
        store.managedDisplayID = UInt32.max
        XCTAssertEqual(store.managedDisplayID, UInt32.max)
    }

    func testAutoModePreferenceStartsUnset() {
        // Unset means "use the default (on)"; only an explicit menu choice is ever saved.
        XCTAssertNil(UserDefaultsStateStore(defaults: defaults).autoModePreference)
    }

    func testAutoModePreferenceRoundTripsAcrossInstances() {
        UserDefaultsStateStore(defaults: defaults).autoModePreference = false
        XCTAssertEqual(UserDefaultsStateStore(defaults: defaults).autoModePreference, false)

        UserDefaultsStateStore(defaults: defaults).autoModePreference = true
        XCTAssertEqual(UserDefaultsStateStore(defaults: defaults).autoModePreference, true)

        UserDefaultsStateStore(defaults: defaults).autoModePreference = nil
        XCTAssertNil(defaults.object(forKey: "autoModeEnabled"))
    }

    func testSettingNilRemovesTheKey() {
        let store = UserDefaultsStateStore(defaults: defaults)
        store.lastKnownBuiltInID = 3
        store.lastKnownBuiltInID = nil
        XCTAssertNil(defaults.object(forKey: "lastKnownBuiltInID"))
    }
}
