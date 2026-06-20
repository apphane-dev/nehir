// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI

extension SettingsColor {
    init?(color: Color, preservesAlpha: Bool = true) {
        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: preservesAlpha ? Double(converted.alphaComponent) : 1
        )
    }

    init?(nsColor: NSColor, preservesAlpha: Bool = true) {
        guard let converted = nsColor.usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: preservesAlpha ? Double(converted.alphaComponent) : 1
        )
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
