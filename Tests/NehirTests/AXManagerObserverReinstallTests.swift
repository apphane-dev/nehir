// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@testable import Nehir
import Testing

// Regression coverage for the launch/termination observer reinstall bug: a
// same-process stop→start cycle (as the onboarding gate performs) must fully
// restore app launch/termination detection.
//
// `AXManager.workspaceObserversInstalled` exposes the *real* observer state
// (whether the two NSWorkspace observers are registered). It is an observability
// accessor for a private lifecycle invariant — it does not stub or override the
// observers themselves — consistent with the caution in
// discovery/20260708-test-only-seams-can-make-tests-untruthful.md.
@Suite(.serialized) struct AXManagerObserverReinstallTests {
    @Test @MainActor func freshInitInstallsBothObservers() {
        let manager = AXManager()
        #expect(manager.workspaceObserversInstalled)
    }

    @Test @MainActor func cleanupTearsDownObservers() {
        let manager = AXManager()
        manager.cleanup()
        #expect(!manager.workspaceObserversInstalled)
    }

    @Test @MainActor func reinstallRestoresObserversAfterCleanup() {
        // The exact stop→start sequence: this assertion fails on today's main,
        // where startServices() never re-registered the observers.
        let manager = AXManager()
        manager.cleanup()
        manager.installWorkspaceObservers()
        #expect(manager.workspaceObserversInstalled)
    }

    @Test @MainActor func installIsIdempotent() {
        let manager = AXManager()
        manager.installWorkspaceObservers()
        manager.installWorkspaceObservers()
        #expect(manager.workspaceObserversInstalled)
    }
}
