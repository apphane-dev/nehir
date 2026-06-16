import SwiftUI

struct AboutSettingsTab: View {
    private static let repositoryURL = URL(string: ReleaseNotes.repositoryURLString)!
    private static let issuesURL = URL(string: "\(ReleaseNotes.repositoryURLString)/issues")!
    private static let discussionsURL = URL(string: "\(ReleaseNotes.repositoryURLString)/discussions")!
    private static let sponsorsURL = URL(string: "https://github.com/sponsors/guria")!
    private static let licenseURL = URL(string: "\(ReleaseNotes.repositoryURLString)/blob/main/LICENSE")!
    private static let omniWMURL = URL(string: "https://github.com/BarutSRB/OmniWM")!

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)) where build != version:
            return "Version \(version) (\(build))"
        case let (.some(version), _):
            return "Version \(version)"
        case let (_, .some(build)):
            return "Build \(build)"
        default:
            return "Development build"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sponsorShowcase
                .layoutPriority(1)
            githubLinks
            licenseAndAttributionSection
        }
        .padding(20)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            NehirLogo()
                .frame(width: 132, height: 54)
                .accessibilityLabel("Nehir")

            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var sponsorShowcase: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: "heart.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.pink)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("Sponsor Showcase")
                    .font(.title3.weight(.semibold))
                Text("This space is reserved for the people and organizations who support Nehir. There are no sponsors yet — become the first one and help keep development moving.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }

            Link(destination: Self.sponsorsURL) {
                Label("Sponsor Nehir", systemImage: "heart.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var githubLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub")
                .font(.headline)

            HStack(spacing: 10) {
                AboutLinkCard(
                    title: "Repository",
                    caption: "Source code and releases",
                    iconName: "chevron.left.forwardslash.chevron.right",
                    tint: .accentColor,
                    url: Self.repositoryURL
                )
                AboutLinkCard(
                    title: "Issues",
                    caption: "Report bugs and track fixes",
                    iconName: "exclamationmark.bubble",
                    tint: .orange,
                    url: Self.issuesURL
                )
                AboutLinkCard(
                    title: "Discussions",
                    caption: "Ask questions and share ideas",
                    iconName: "bubble.left.and.bubble.right",
                    tint: .blue,
                    url: Self.discussionsURL
                )
            }
        }
    }

    private var licenseAndAttributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License & Attribution")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                AboutInfoCard(
                    title: "GPL-2.0-only",
                    caption: "Nehir is free software distributed under the GNU General Public License v2.0-only.",
                    iconName: "doc.text",
                    tint: .secondary,
                    linkTitle: "View License",
                    url: Self.licenseURL
                )
                AboutInfoCard(
                    title: "Based on OmniWM",
                    caption: "Nehir builds on the original OmniWM work by BarutSRB and is maintained independently.",
                    iconName: "arrow.triangle.branch",
                    tint: .purple,
                    linkTitle: "View OmniWM",
                    url: Self.omniWMURL
                )
            }
        }
    }
}

private struct AboutInfoCard: View {
    let title: String
    let caption: String
    let iconName: String
    let tint: Color
    let linkTitle: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                Link(linkTitle, destination: url)
                    .font(.caption.weight(.medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct AboutLinkCard: View {
    let title: String
    let caption: String
    let iconName: String
    let tint: Color
    let url: URL

    var body: some View {
        Link(destination: url) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
