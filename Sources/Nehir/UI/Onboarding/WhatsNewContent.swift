import Foundation

/// Bundled, developer-written "What's New" highlights for the current release.
///
/// Content is grouped into a handful of meaningful sections so the screen communicates
/// the gist of the release without dumping raw changelog detail. The full per-release
/// changelog lives on the GitHub Releases page.
///
/// Which release these describe is inferred from the running app version — there is no
/// hardcoded version constant to keep in sync. Auto-show fires once when the running build
/// is a release version newer than the one the user last acknowledged (see
/// `AppDelegate.continueBootstrap`); dev builds (`0.0.0`) and prereleases never auto-show.
/// Keep `sections` current as part of release prep — empty `sections` disables the screen
/// (auto-show is skipped and the on-demand entries no-op).
enum WhatsNewContent {
    /// A single curated group of highlights, shown under a short title with an SF Symbol.
    struct Section {
        let title: String
        let icon: String
        let bullets: [String]
    }

    /// Curated, grouped highlights for the current release.
    ///
    /// Keep copy at the level of "what changed and why it matters" — avoid raw structural
    /// trivia (exact counts of commands, tabs, etc.). Pointers to where things live
    /// (e.g. "Settings → General") are fine because they're actionable.
    static let sections: [Section] = [
        Section(
            title: "Settings, rebuilt",
            icon: "slider.horizontal.3",
            bullets: [
                "Settings is reorganized into focused areas — Behavior, Layout, Monitors, Workspaces, and more — so related options finally live together.",
                "App Rules are edited inline with +/− buttons instead of a modal sheet.",
                "Diagnostics became a real troubleshooting hub: Accessibility status, runtime-state tools, and recent traces. Developer Mode moved here too.",
                "There's a new About page to share Nehir and support the project.",
                "Sliders no longer stutter while you drag them."
            ]
        ),
        Section(
            title: "Layout that fits every display",
            icon: "rectangle.split.3x1",
            bullets: [
                "Tune Inner Gap, Screen Margins, and the lone-window policy per monitor, inheriting global defaults wherever you like.",
                "New Reveal Partial and snap-grid navigation make viewport movement more predictable, replacing the old centering controls.",
                "Proportional columns like 50% + 50% now center their slack instead of hugging one edge, and terminal-cell rounding no longer mis-pins window heights."
            ]
        ),
        Section(
            title: "Focus & multi-monitor, refined",
            icon: "display",
            bullets: [
                "Focus-follows-mouse stays on the right window through fast pointer moves and ignores apps hidden behind quick-terminals and other overlays.",
                "New windows and quick-terminals open on the workspace you're actually using.",
                "Workspaces revalidate against your displays when you dock or undock, keeping the workspace bar and reveals correct.",
                "Cursor warp no longer fights window drags or misfires across monitors when Nehir isn't the active app."
            ]
        ),
        Section(
            title: "More ways to control Nehir",
            icon: "command",
            bullets: [
                "New toggle commands for the options you flip most, plus a dedicated Open Settings command reachable from the palette, hotkeys, or CLI.",
                "The status-bar menu is now a compact set of quick toggles and shortcuts."
            ]
        ),
        Section(
            title: "Config you can trust",
            icon: "checkmark.shield",
            bullets: [
                "Unrecognized settings keys are preserved and surfaced in Diagnostics instead of being stripped on save.",
                "Renamed keys and legacy formats get clear, one-tap migration guidance, and Nehir only blocks launch when settings truly can't load."
            ]
        ),
        Section(
            title: "New for first-time users",
            icon: "sparkles",
            bullets: [
                "A setup wizard walks new users through Nehir's model — with a live Niri demo — before the layout engine activates. Re-run it any time from Settings → General."
            ]
        )
    ]

    /// Flattened view of all bullets across sections. Handy for emptiness checks and as a
    /// fallback; the screen itself renders `sections`.
    static var bullets: [String] { sections.flatMap(\.bullets) }

    /// True when there is no curated content to show.
    static var isEmpty: Bool { sections.allSatisfy { $0.bullets.isEmpty } }
}
