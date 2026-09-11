import XCTest
@testable import MacDictate

final class AudioInputDeviceReconnectorTests: XCTestCase {
    func testReplacesMissingUIDWhenExactlyOneDeviceHasTheSavedName() {
        let saved = AudioInputSelection.device(uid: "old-port", name: "USB Microphone")
        let current = AudioInputDevice(uid: "new-port", name: "USB Microphone")

        XCTAssertEqual(
            AudioInputDeviceReconnector.replacement(for: saved, among: [current]),
            current.selection
        )
    }

    func testDoesNotReplaceAnAvailableSavedUID() {
        let saved = AudioInputSelection.device(uid: "saved-port", name: "USB Microphone")
        let savedDevice = AudioInputDevice(uid: "saved-port", name: "USB Microphone")
        let duplicate = AudioInputDevice(uid: "other-port", name: "USB Microphone")

        XCTAssertNil(
            AudioInputDeviceReconnector.replacement(
                for: saved,
                among: [savedDevice, duplicate]
            )
        )
    }

    func testDoesNotGuessBetweenIdenticallyNamedDevices() {
        let saved = AudioInputSelection.device(uid: "old-port", name: "USB Microphone")
        let devices = [
            AudioInputDevice(uid: "new-port-1", name: "USB Microphone"),
            AudioInputDevice(uid: "new-port-2", name: "USB Microphone")
        ]

        XCTAssertNil(AudioInputDeviceReconnector.replacement(for: saved, among: devices))
    }

    func testDoesNotReplaceWithADifferentlyNamedDevice() {
        let saved = AudioInputSelection.device(uid: "old-port", name: "USB Microphone")
        let builtIn = AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone")

        XCTAssertNil(
            AudioInputDeviceReconnector.replacement(for: saved, among: [builtIn])
        )
    }

    func testDoesNotReplaceSystemDefault() {
        let device = AudioInputDevice(uid: "usb", name: "USB Microphone")

        XCTAssertNil(
            AudioInputDeviceReconnector.replacement(for: .systemDefault, among: [device])
        )
    }

    func testFallbackUsesPreviousDeviceBeforeSystemDefault() {
        let preferred = AudioInputSelection.device(uid: "usb", name: "USB Microphone")
        let previous = AudioInputSelection.device(uid: "bluetooth", name: "Headset")

        XCTAssertEqual(
            AudioInputFallbackPolicy.candidates(after: preferred, previous: previous),
            [previous, .systemDefault]
        )
    }

    func testFallbackDoesNotDuplicateSystemDefault() {
        let preferred = AudioInputSelection.device(uid: "usb", name: "USB Microphone")

        XCTAssertEqual(
            AudioInputFallbackPolicy.candidates(after: preferred, previous: .systemDefault),
            [.systemDefault]
        )
    }

    func testSystemDefaultHasNoImplicitFallback() {
        XCTAssertEqual(
            AudioInputFallbackPolicy.candidates(after: .systemDefault, previous: nil),
            []
        )
    }
}
