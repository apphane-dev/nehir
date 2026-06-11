import SwiftUI

struct ExperimentalBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flask")
                .font(.caption2)
            Text("Experimental")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.orange.opacity(0.12), in: Capsule())
    }
}
