import AppKit
import SwiftUI

/// The Nehir wordmark logo, loaded explicitly from the bundled `Logo.png` resource.
struct NehirLogo: View {
    private static let logoImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let nsImage = Self.logoImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Nehir")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.tint)
            }
        }
    }
}
