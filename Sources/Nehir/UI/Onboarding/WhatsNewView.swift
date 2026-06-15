import SwiftUI

struct WhatsNewView: View {
    let version: String
    let bullets: [String]
    let onDismiss: () -> Void
    var onRerunOnboarding: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("What's New")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Nehir \(version)")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 28)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { index, bullet in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .padding(.top, 1)
                            Text(bullet)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 20)

            Link(destination: ReleaseNotes.url(forVersion: version)) {
                HStack(spacing: 4) {
                    Text("Read full release notes")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.footnote)
            }
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                if let onRerunOnboarding {
                    Button("Re-run Setup Wizard", action: onRerunOnboarding)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 640)
        .background(.thickMaterial)
    }
}
