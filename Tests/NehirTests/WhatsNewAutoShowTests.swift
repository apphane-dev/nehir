@testable import Nehir
import Testing

@Suite @MainActor struct WhatsNewAutoShowTests {
    @Test func patchUpgradeWithinSeenMajorMinorDoesNotAutoShow() {
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.1",
            lastSeenVersion: "0.5.0",
            hasContent: true
        ))
    }

    @Test func majorMinorUpgradeAutoShowsEvenToPatchRelease() {
        #expect(AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.1",
            lastSeenVersion: "0.4.9",
            hasContent: true
        ))
    }

    @Test func majorVersionUpgradeAutoShows() {
        #expect(AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "1.0.0",
            lastSeenVersion: "0.9.9",
            hasContent: true
        ))
    }

    @Test func equalVersionsDoNotAutoShow() {
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.0",
            lastSeenVersion: "0.5.0",
            hasContent: true
        ))
    }

    @Test func downgradeDoesNotAutoShow() {
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.4.0",
            lastSeenVersion: "0.5.0",
            hasContent: true
        ))
    }

    @Test func malformedVersionDoesNotAutoShow() {
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "not-a-version",
            lastSeenVersion: "0.4.9",
            hasContent: true
        ))
    }

    @Test func prereleaseDevMissingStateAndEmptyContentDoNotAutoShow() {
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.1-rc.1",
            lastSeenVersion: "0.4.9",
            hasContent: true
        ))
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.0.0",
            lastSeenVersion: "0.4.9",
            hasContent: true
        ))
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.0",
            lastSeenVersion: nil,
            hasContent: true
        ))
        #expect(!AppDelegate.shouldAutoShowWhatsNew(
            appVersion: "0.5.0",
            lastSeenVersion: "0.4.9",
            hasContent: false
        ))
    }
}
