import SwiftUI

struct SettingInfo: View {
    let text: String
    var consequence: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let consequence {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
