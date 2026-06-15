import Foundation

/// Bundled, developer-written "What's New" highlights for the current release.
///
/// A single curated set of bullets shown on upgrade and on demand. The full per-release
/// changelog lives on the GitHub Releases page.
///
/// Which release these describe is inferred from the running app version — there is no
/// hardcoded version constant to keep in sync. Auto-show fires once when the running build
/// is a release version newer than the one the user last acknowledged (see
/// `AppDelegate.continueBootstrap`); dev builds (`0.0.0`) and prereleases never auto-show.
/// Keep `bullets` current as part of release prep — empty `bullets` disables the screen
/// (auto-show is skipped and the on-demand entries no-op).
enum WhatsNewContent {
    /// Curated highlights for the current release.
    static let bullets: [String] = [
        "Settings redesigned into ten sections, with new Behavior and Layout tabs that group related options together.",
        "Six new toggle commands: Focus Follows Mouse, Follow Window to Monitor, Move Cursor to Focused, Window Borders, Prevent Sleep, and IPC.",
        "App Rules now edited inline with +/− footer buttons instead of a modal sheet.",
        "Debug commands are hidden unless Developer Mode is enabled; the Diagnostics tab now shows Accessibility permission status.",
        "New openSettings command available from the command palette, hotkeys, and CLI.",
        "Improved Niri layout with per-monitor Inner Gap and Screen Margin overrides, plus explicit per-monitor Lone Window policy."
    ]
}
