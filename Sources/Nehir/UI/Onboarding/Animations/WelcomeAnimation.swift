import SwiftUI

/// Merged first-slide animation. Two phases loop:
/// 1. **Appear** — three column tiles fade/scale in one by one.
/// 2. **Focus + move** — a highlighted "focused" column sweeps left → right with a small
///    viewport offset, mirroring how Nehir scrolls columns into view.
struct WelcomeAnimation: View {
    @State private var isAnimating = false
    @State private var appearedCount = 0
    @State private var focusedIndex = -1
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    private let columnCount = 3

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<columnCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(index == focusedIndex ? Color.accentColor.opacity(0.5) : Color.accentColor.opacity(0.3))
                        .frame(width: 52, height: 72)
                        .opacity(index < appearedCount ? 1.0 : 0.0)
                        .scaleEffect(index < appearedCount ? 1.0 : 0.6)
                }
            }
            .offset(x: offset)
        }
        .onAppear { startLoop() }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
            isAnimating = false
        }
    }

    private func startLoop() {
        animationTask?.cancel()
        isAnimating = true
        animationTask = Task { @MainActor in
            while isAnimating && !Task.isCancelled {
                // Phase 1: appear one by one.
                appearedCount = 0
                focusedIndex = -1
                offset = 0
                for index in 0..<columnCount {
                    guard isAnimating, !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        appearedCount = index + 1
                    }
                    try? await Task.sleep(for: .milliseconds(180))
                }
                guard isAnimating, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(400))

                // Phase 2: focus + viewport scroll sweep.
                for index in 0..<columnCount {
                    guard isAnimating, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        focusedIndex = index
                        offset = focusedOffset(for: index)
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                guard isAnimating, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(700))

                // Fade out before looping back to the appear phase.
                withAnimation(.easeIn(duration: 0.3)) {
                    appearedCount = 0
                    focusedIndex = -1
                    offset = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Simulates viewport scrolling: nudge the row slightly opposite to focus so the
    /// highlighted column reads as the "active" one without sliding offscreen.
    private func focusedOffset(for index: Int) -> CGFloat {
        let center = Double(columnCount - 1) / 2.0
        return CGFloat(index - Int(center)) * -10
    }
}
