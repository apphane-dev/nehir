// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
@testable import Nehir
import Testing

@Suite struct OverviewRendererTests {
    @Test func aspectFitRectCentersContentWithoutStretching() {
        let rect = OverviewRenderer.aspectFitRect(
            contentSize: CGSize(width: 800, height: 400),
            in: CGRect(x: 10, y: 20, width: 100, height: 100)
        )

        #expect(rect.origin.x == 10)
        #expect(rect.origin.y == 45)
        #expect(rect.width == 100)
        #expect(rect.height == 50)
    }
}
