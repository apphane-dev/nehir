import SwiftUI

struct DeveloperBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer")
                .font(.caption2)
            Text("Dev")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.purple.opacity(0.12), in: Capsule())
    }
}
