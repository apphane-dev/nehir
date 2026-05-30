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
