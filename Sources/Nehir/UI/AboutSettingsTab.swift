// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

struct AboutSettingsTab: View {
    @State private var isPresentingSpreadSheet = false

    private static let repositoryURL = URL(string: ReleaseNotes.repositoryURLString)!
    private static let issuesURL = URL(string: "\(ReleaseNotes.repositoryURLString)/issues")!
    private static let discussionsURL = URL(string: "\(ReleaseNotes.repositoryURLString)/discussions")!
    private static let sponsorsURL = URL(string: "https://github.com/sponsors/guria")!
    private static let upstreamSponsorsURL = URL(string: "https://github.com/sponsors/barutsrb")!
    private static let licenseURL = URL(string: "\(ReleaseNotes.repositoryURLString)/blob/main/LICENSE")!
    private static let noticeURL = URL(string: "\(ReleaseNotes.repositoryURLString)/blob/main/NOTICE.md")!
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                sponsorShowcase
                githubLinks
                licenseAndAttributionSection
            }
            .padding(14)
            .frame(maxWidth: 740, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isPresentingSpreadSheet) {
            SpreadTheWordSheet()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            NehirLogo()
                .frame(width: 112, height: 46)
                .accessibilityLabel("Nehir")

            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var sponsorShowcase: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Image(systemName: "heart.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.pink)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 4) {
                Text("Sponsor Showcase")
                    .font(.callout.weight(.semibold))
                Text(
                    "This space is reserved for the people and organizations who support Nehir. There are no sponsors yet — become the first one and help keep development moving."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            }

            HStack(spacing: 10) {
                Button {
                    isPresentingSpreadSheet = true
                } label: {
                    Label("Spread the word", systemImage: "megaphone.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Link(destination: Self.sponsorsURL) {
                    Label("Sponsor Nehir", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 152)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
        }
    }

    private var githubLinks: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            VStack(alignment: .leading, spacing: 6) {
                Text("License")
                    .font(.headline)
                AboutInfoCard(
                    title: "GPL-2.0-only free software",
                    caption: "Distributed with no warranty. You can inspect, modify, and share Nehir under GPL v2 terms.",
                    iconName: "doc.text",
                    tint: .secondary,
                    linkTitle: "View License",
                    url: Self.licenseURL
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OmniWM Attribution")
                    .font(.headline)
                AboutAttributionCard(
                    noticeURL: Self.noticeURL,
                    upstreamURL: Self.omniWMURL,
                    upstreamSponsorsURL: Self.upstreamSponsorsURL
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Link(linkTitle, destination: url)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct AboutAttributionCard: View {
    let noticeURL: URL
    let upstreamURL: URL
    let upstreamSponsorsURL: URL

    private let sponsorTooltip = "This fork brought some unspoken traction and misunderstanding. " +
        "Sponsoring BarutSRB is a direct way to acknowledge the original OmniWM work."
    private let attributionText = "Nehir is an independent GPL fork of OmniWM by BarutSRB. " +
        "Source headers and NOTICE.md preserve that lineage while Nehir-specific changes are attributed separately."

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Built from OmniWM")
                        .font(.subheadline.weight(.semibold))
                    Text(attributionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Link("Notice", destination: noticeURL)
                    .buttonStyle(.bordered)
                Link("OmniWM", destination: upstreamURL)
                    .buttonStyle(.bordered)

                Link(destination: upstreamSponsorsURL) {
                    Label("Share some love to BarutSRB", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .help(Text(sponsorTooltip))

                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.22), lineWidth: 1)
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
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SpreadTheWordSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let shortTitle = "Nehir — scrolling tiling window manager for macOS"
    private static let shareMessage = "I'm trying Nehir, a scrolling tiling window manager for macOS inspired by Niri. Windows flow in columns."
    private static let repositoryURL = URL(string: ReleaseNotes.repositoryURLString)!
    private static let repositoryString = repositoryURL.absoluteString

    /// Builds a share URL from a base URL plus query items using
    /// `URLComponents`/`URLQueryItem`, which percent-encode reserved
    /// characters (`&`, `=`, `+`, ...) correctly per RFC 3986. Returns nil if
    /// the base URL is invalid, so callers can drop the destination safely.
    private static func shareURL(
        _ baseURL: String,
        queryItems: [(name: String, value: String)]
    ) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        if !queryItems.isEmpty {
            components.queryItems = queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        return components.url
    }

    private var destinations: [ShareDestination] {
        let message = Self.shareMessage
        let repo = Self.repositoryString
        let shortTitle = Self.shortTitle

        let definitions: [(
            name: String,
            caption: String,
            monogram: String,
            tint: Color,
            baseURL: String,
            queryItems: [(name: String, value: String)]
        )] = [
            (
                "X",
                "Post to your followers",
                "X",
                Color(red: 0.06, green: 0.06, blue: 0.07),
                "https://twitter.com/intent/tweet",
                [("text", message), ("url", repo)]
            ),
            (
                "Bluesky",
                "Share to your feed",
                "B",
                Color(red: 0.0, green: 0.52, blue: 1.0),
                "https://bsky.app/intent/compose",
                [("text", "\(message) \(repo)")]
            ),
            (
                "Reddit",
                "r/macapps · r/MacOS · r/windowmanagers",
                "R",
                Color(red: 1.0, green: 0.27, blue: 0.0),
                "https://www.reddit.com/submit",
                []
            ),
            (
                "Hacker News",
                "Submit to the front page",
                "Y",
                Color(red: 1.0, green: 0.4, blue: 0.0),
                "https://news.ycombinator.com/submitlink",
                [("u", repo), ("t", shortTitle)]
            ),
            (
                "LinkedIn",
                "Share with your network",
                "in",
                Color(red: 0.08, green: 0.37, blue: 0.72),
                "https://www.linkedin.com/sharing/share-offsite/",
                [("url", repo)]
            ),
            (
                "Telegram",
                "Send in a chat",
                "T",
                Color(red: 0.0, green: 0.5, blue: 0.85),
                "https://t.me/share/url",
                [("url", repo), ("text", message)]
            ),
            (
                "Email",
                "Tell a friend",
                "@",
                .secondary,
                "mailto:",
                [("subject", shortTitle), ("body", "\(message)\n\(repo)")]
            )
        ]

        var results: [ShareDestination] = []
        for definition in definitions {
            guard let url = Self.shareURL(definition.baseURL, queryItems: definition.queryItems) else { continue }
            results.append(
                ShareDestination(
                    name: definition.name,
                    caption: definition.caption,
                    monogram: definition.monogram,
                    tint: definition.tint,
                    url: url
                )
            )
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "megaphone.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spread the word")
                        .font(.headline)
                    Text("Help others discover Nehir. Every share helps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Divider()

            List(destinations) { destination in
                ShareRow(destination: destination)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 420, idealHeight: 480)
    }
}

private struct ShareDestination: Identifiable {
    var id: String {
        name
    }

    let name: String
    let caption: String
    let monogram: String
    let tint: Color
    let url: URL
}

private struct ShareRow: View {
    let destination: ShareDestination

    var body: some View {
        Link(destination: destination.url) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(destination.tint)
                        .frame(width: 30, height: 30)
                    Text(destination.monogram)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                        .font(.body.weight(.medium))
                    Text(destination.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
