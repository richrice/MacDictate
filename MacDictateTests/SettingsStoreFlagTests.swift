import XCTest
@testable import MacDictate

@MainActor
final class SettingsStoreFlagTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsStoreFlagTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testSetupAndMuteNoticeFlagsDefaultToFalse() {
        let settings = SettingsStore(defaults: makeDefaults())
        XCTAssertFalse(settings.hasCompletedSetup)
        XCTAssertFalse(settings.hasSeenMuteNotice)
    }

    func testSetupAndMuteNoticeFlagsPersistAcrossReloads() {
        let defaults = makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.hasCompletedSetup = true
        settings.hasSeenMuteNotice = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedSetup)
        XCTAssertTrue(reloaded.hasSeenMuteNotice)
    }

    func testLanguageCatalogKeepsAutomaticUntaggedAndSendsISOCodeForOthers() {
        XCTAssertNil(TranscriptionLanguage.automatic.apiValue)
        XCTAssertEqual(TranscriptionLanguage.english.apiValue, "en")
        XCTAssertEqual(TranscriptionLanguage.japanese.apiValue, "ja")
        XCTAssertEqual(TranscriptionLanguage.chinese.displayName, "Chinese")
    }

    func testLegacyEnglishRawValueFallsBackToEnglishDefault() {
        // Older builds persisted the case label "english"; the store must load
        // English rather than being dropped or misread as another language.
        let defaults = makeDefaults()
        defaults.set("english", forKey: "transcriptionLanguage")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.language, .english)

        defaults.set("automatic", forKey: "transcriptionLanguage")
        XCTAssertEqual(SettingsStore(defaults: defaults).language, .automatic)
    }
}
