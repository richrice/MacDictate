import Carbon.HIToolbox
import Foundation
import XCTest
@testable import MacDictate

private struct HotkeyCombination: Hashable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
}

@MainActor
final class HotkeyPresetTests: XCTestCase {
    func testPresetsFlattenGroupsAndHaveExpectedCount() {
        let flattenedPresets = HotkeyShortcut.presetGroups.flatMap(\.shortcuts)

        XCTAssertEqual(HotkeyShortcut.presets, flattenedPresets)
        XCTAssertEqual(HotkeyShortcut.presets.count, 17)
    }

    func testCatalogMatchesPinnedContractExactly() {
        let expected = [
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), displayName: "⌥ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey), displayName: "⌃ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey), displayName: "⌘⇧ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), displayName: "⌥⇧ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | shiftKey), displayName: "⌃⇧ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), displayName: "⌃⌥⌘ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_F13), carbonModifiers: 0, displayName: "F13"),
            HotkeyShortcut(keyCode: UInt32(kVK_F14), carbonModifiers: 0, displayName: "F14"),
            HotkeyShortcut(keyCode: UInt32(kVK_F15), carbonModifiers: 0, displayName: "F15"),
            HotkeyShortcut(keyCode: UInt32(kVK_F16), carbonModifiers: 0, displayName: "F16"),
            HotkeyShortcut(keyCode: UInt32(kVK_F17), carbonModifiers: 0, displayName: "F17"),
            HotkeyShortcut(keyCode: UInt32(kVK_F18), carbonModifiers: 0, displayName: "F18"),
            HotkeyShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: 0, displayName: "F19"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥ D"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥ M"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_Grave), carbonModifiers: UInt32(optionKey), displayName: "⌥ `")
        ]

        XCTAssertEqual(HotkeyShortcut.presets, expected)
        XCTAssertEqual(HotkeyShortcut.presets.first, HotkeyShortcut.defaultShortcut)
    }

    func testPresetsContainDefaultAndEveryLegacyShortcut() {
        XCTAssertTrue(HotkeyShortcut.presets.contains(HotkeyShortcut.defaultShortcut))

        let legacyCombinations = [
            HotkeyCombination(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: UInt32(optionKey)
            ),
            HotkeyCombination(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: UInt32(controlKey)
            ),
            HotkeyCombination(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: UInt32(controlKey | optionKey)
            ),
            HotkeyCombination(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: UInt32(cmdKey | shiftKey)
            )
        ]

        for legacyCombination in legacyCombinations {
            XCTAssertTrue(
                HotkeyShortcut.presets.contains {
                    $0.keyCode == legacyCombination.keyCode
                        && $0.carbonModifiers == legacyCombination.carbonModifiers
                },
                "Missing legacy hotkey combination \(legacyCombination)"
            )
        }
    }

    func testPresetCombinationsNamesAndIdentifiersAreUnique() {
        let presets = HotkeyShortcut.presets
        let combinations = presets.map {
            HotkeyCombination(keyCode: $0.keyCode, carbonModifiers: $0.carbonModifiers)
        }

        XCTAssertEqual(Set(combinations).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.displayName)).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
    }

    func testBareKeyPresetsAreLimitedToF13ThroughF19() {
        let safeBareKeyCodes: Set<UInt32> = [
            UInt32(kVK_F13),
            UInt32(kVK_F14),
            UInt32(kVK_F15),
            UInt32(kVK_F16),
            UInt32(kVK_F17),
            UInt32(kVK_F18),
            UInt32(kVK_F19)
        ]

        for preset in HotkeyShortcut.presets where preset.carbonModifiers == 0 {
            XCTAssertTrue(
                safeBareKeyCodes.contains(preset.keyCode),
                "Bare shortcut \(preset.displayName) is not a safe F13-F19 key"
            )
        }
    }

    func testEveryPresetRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for preset in HotkeyShortcut.presets {
            let data = try encoder.encode(preset)
            let decodedPreset = try decoder.decode(HotkeyShortcut.self, from: data)

            XCTAssertEqual(decodedPreset, preset)
        }
    }

    func testPersistedLegacyOptionSpaceLoadsAsCatalogDefault() throws {
        let suiteName = "HotkeyPresetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let persistedOptionSpace = HotkeyShortcut(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(optionKey),
            displayName: "⌥ Space"
        )
        let encodedShortcut = try JSONEncoder().encode(persistedOptionSpace)
        defaults.set(encodedShortcut, forKey: "hotkeyShortcut")

        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(settings.hotkey, HotkeyShortcut.defaultShortcut)
        XCTAssertTrue(HotkeyShortcut.presets.contains(settings.hotkey))
    }

    @MainActor
    func testAudioInputSelectionAndFallbackPersist() throws {
        let suiteName = "AudioInputSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let selected = AudioInputSelection.device(uid: "iphone-uid", name: "Backup iPhone")
        let fallback = AudioInputSelection.device(uid: "mac-uid", name: "MacBook Microphone")
        var settings: SettingsStore? = SettingsStore(defaults: defaults)
        settings?.audioInputSelection = selected
        settings?.fallbackAudioInputSelection = fallback
        settings = nil

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.audioInputSelection, selected)
        XCTAssertEqual(reloaded.fallbackAudioInputSelection, fallback)
    }
}
