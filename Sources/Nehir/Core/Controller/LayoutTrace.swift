// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import os

/// Opt-in diagnostic trace for the layout / frame-application pipeline.
///
/// Disabled by default and effectively zero-cost (a single `Bool` check) unless
/// the `NEHIR_LAYOUT_TRACE` environment variable is set when the app launches.
///
/// To capture a session:
///
/// ```sh
/// NEHIR_LAYOUT_TRACE=1 /path/to/Nehir            # launch with tracing on
/// log stream --predicate 'subsystem == "com.nehir" && category == "layout-trace"' --level info
/// ```
///
/// The trace records, per relayout/scroll tick, the viewport offset and the
/// per-window decision (computed frame, hide/show/restore, and whether the AX
/// write was applied, deduplicated, or confirmed) so workspace-switch and scroll
/// glitches can be diagnosed from a real run before changing behavior.
enum LayoutTrace {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["NEHIR_LAYOUT_TRACE"] != nil

    private static let logger = Logger(subsystem: "com.nehir", category: "layout-trace")

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }

    static func point(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.0f,%.0f)", point.x, point.y)
    }
}
