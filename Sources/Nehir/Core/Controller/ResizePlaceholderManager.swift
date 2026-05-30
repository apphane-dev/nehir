import AppKit

struct ResizePlaceholderUpdate {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let frame: CGRect
    let selected: Bool
    let appName: String?
    let icon: NSImage?
}

struct ResizePlaceholderSnapshot: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let frame: CGRect
    let selected: Bool
    let appName: String?
}

@MainActor
final class ResizePlaceholderManager {
    static var materializesWindowsForTests = true

    var onActivate: ((WindowToken) -> Void)?

    private var windowsByToken: [WindowToken: ResizePlaceholderWindow] = [:]
    private var snapshotsByToken: [WindowToken: ResizePlaceholderSnapshot] = [:]

    func update(placeholders: [ResizePlaceholderUpdate], in workspaceId: WorkspaceDescriptor.ID) {
        let desiredTokens = Set(placeholders.map(\.token))
        let staleSnapshotTokens = snapshotsByToken.compactMap { token, snapshot in
            snapshot.workspaceId == workspaceId && !desiredTokens.contains(token) ? token : nil
        }
        for token in staleSnapshotTokens {
            snapshotsByToken.removeValue(forKey: token)
            windowsByToken.removeValue(forKey: token)?.destroy()
        }

        for placeholder in placeholders {
            snapshotsByToken[placeholder.token] = ResizePlaceholderSnapshot(
                workspaceId: placeholder.workspaceId,
                frame: placeholder.frame,
                selected: placeholder.selected,
                appName: placeholder.appName
            )
        }

        guard Self.materializesWindowsForTests else {
            for token in desiredTokens {
                windowsByToken.removeValue(forKey: token)?.destroy()
            }
            return
        }

        let staleWindowTokens = windowsByToken.compactMap { token, window in
            window.workspaceId == workspaceId && !desiredTokens.contains(token) ? token : nil
        }
        for token in staleWindowTokens {
            windowsByToken.removeValue(forKey: token)?.destroy()
        }

        for placeholder in placeholders {
            update(placeholder)
        }
    }

    func update(_ placeholder: ResizePlaceholderUpdate) {
        snapshotsByToken[placeholder.token] = ResizePlaceholderSnapshot(
            workspaceId: placeholder.workspaceId,
            frame: placeholder.frame,
            selected: placeholder.selected,
            appName: placeholder.appName
        )

        guard Self.materializesWindowsForTests else {
            windowsByToken.removeValue(forKey: placeholder.token)?.destroy()
            return
        }

        let window = windowsByToken[placeholder.token] ?? {
            let window = ResizePlaceholderWindow(token: placeholder.token)
            window.onActivate = { [weak self] token in
                self?.onActivate?(token)
            }
            windowsByToken[placeholder.token] = window
            return window
        }()
        window.update(placeholder)
    }

    func remove(_ token: WindowToken) {
        snapshotsByToken.removeValue(forKey: token)
        guard let window = windowsByToken.removeValue(forKey: token) else { return }
        window.destroy()
    }

    func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        guard oldToken != newToken else { return }
        if let snapshot = snapshotsByToken.removeValue(forKey: oldToken) {
            snapshotsByToken[newToken] = snapshot
        }
        if let window = windowsByToken.removeValue(forKey: oldToken) {
            window.rekey(to: newToken)
            windowsByToken[newToken] = window
        }
    }

    func removeAll() {
        for window in windowsByToken.values {
            window.destroy()
        }
        windowsByToken.removeAll()
        snapshotsByToken.removeAll()
    }

    func snapshotForTests() -> [WindowToken: ResizePlaceholderSnapshot] {
        snapshotsByToken
    }

    func hasPlaceholders(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        snapshotsByToken.values.contains { $0.workspaceId == workspaceId }
    }

    func hasPlaceholder(for token: WindowToken) -> Bool {
        snapshotsByToken[token] != nil || windowsByToken[token] != nil
    }

    func token(at point: CGPoint, in workspaceId: WorkspaceDescriptor.ID? = nil) -> WindowToken? {
        var fallbackToken: WindowToken?
        for (token, snapshot) in snapshotsByToken {
            guard workspaceId == nil || snapshot.workspaceId == workspaceId else { continue }
            guard snapshot.frame.contains(point) else { continue }
            if snapshot.selected {
                return token
            }
            fallbackToken = fallbackToken ?? token
        }
        return fallbackToken
    }

    func appearanceForTests(_ token: WindowToken) -> (isOpaque: Bool, backgroundColor: NSColor?, contentBackgroundColor: NSColor?)? {
        windowsByToken[token]?.appearanceForTests()
    }

    func windowNumberForTests(_ token: WindowToken) -> Int? {
        windowsByToken[token]?.windowNumber
    }

    func activateForTests(_ token: WindowToken) {
        if let window = windowsByToken[token] {
            window.activate()
        } else if snapshotsByToken[token] != nil {
            onActivate?(token)
        }
    }
}

@MainActor
private final class ResizePlaceholderWindow: NSPanel {
    private let placeholderView = ResizePlaceholderView(frame: .zero)
    private var token: WindowToken
    private var surfaceId: String
    private var lastUpdate: ResizePlaceholderSnapshot?
    private var registeredSurfaceId: String?

    var workspaceId: WorkspaceDescriptor.ID?
    var onActivate: ((WindowToken) -> Void)?

    init(token: WindowToken) {
        self.token = token
        surfaceId = Self.surfaceId(for: token)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        level = .floating
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.managed, .fullScreenNone]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        placeholderView.onActivate = { [weak self] in
            self?.activate()
        }
        contentView = placeholderView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(_ update: ResizePlaceholderUpdate) {
        token = update.token
        workspaceId = update.workspaceId
        let nextSnapshot = ResizePlaceholderSnapshot(
            workspaceId: update.workspaceId,
            frame: update.frame,
            selected: update.selected,
            appName: update.appName
        )
        let contentChanged = placeholderView.update(
            appName: update.appName,
            icon: update.icon,
            selected: update.selected
        )

        if lastUpdate != nextSnapshot || frame != update.frame {
            setFrame(update.frame, display: contentChanged)
            placeholderView.frame = CGRect(origin: .zero, size: update.frame.size)
            lastUpdate = nextSnapshot
        } else if contentChanged {
            contentView?.displayIfNeeded()
        }

        if update.frame.width > 1, update.frame.height > 1 {
            registerSurfaceIfNeeded()
            if !isVisible {
                orderFront(nil)
            }
        } else {
            orderOut(nil)
        }
    }

    func rekey(to newToken: WindowToken) {
        unregisterSurface()
        token = newToken
        surfaceId = Self.surfaceId(for: newToken)
        if isVisible {
            registerSurfaceIfNeeded()
        }
    }

    func activate() {
        onActivate?(token)
    }

    func destroy() {
        unregisterSurface()
        orderOut(nil)
        close()
    }

    func appearanceForTests() -> (isOpaque: Bool, backgroundColor: NSColor?, contentBackgroundColor: NSColor?) {
        (isOpaque, backgroundColor, placeholderView.layer?.backgroundColor.map(NSColor.init(cgColor:)) ?? nil)
    }

    private func registerSurfaceIfNeeded() {
        guard registeredSurfaceId != surfaceId else { return }
        unregisterSurface()
        OwnedWindowRegistry.shared.register(
            self,
            surfaceId: surfaceId,
            kind: .resizePlaceholder,
            hitTestPolicy: .interactive,
            capturePolicy: .excluded,
            suppressesManagedFocusRecovery: false
        )
        registeredSurfaceId = surfaceId
    }

    private func unregisterSurface() {
        guard let registeredSurfaceId else { return }
        OwnedWindowRegistry.shared.unregister(surfaceId: registeredSurfaceId)
        self.registeredSurfaceId = nil
    }

    private static func surfaceId(for token: WindowToken) -> String {
        "resize-placeholder-\(token.pid)-\(token.windowId)"
    }
}

private final class ResizePlaceholderView: NSView {
    private let warningView = NSImageView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let textField = NSTextField(
        labelWithString: "This app's window is too small to render properly. Please size it up."
    )
    private var currentAppName: String?
    private var currentIcon: NSImage?
    private var isSelected = false

    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        warningView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Window too small"
        )
        warningView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        warningView.contentTintColor = .systemYellow
        warningView.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        textField.alignment = .center
        textField.font = .systemFont(ofSize: 13, weight: .semibold)
        textField.textColor = .white
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 3
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(warningView)
        addSubview(iconView)
        addSubview(textField)

        NSLayoutConstraint.activate([
            warningView.centerXAnchor.constraint(equalTo: centerXAnchor),
            warningView.bottomAnchor.constraint(equalTo: iconView.topAnchor, constant: -12),
            warningView.widthAnchor.constraint(equalToConstant: 28),
            warningView.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            textField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onActivate?()
    }

    override func layout() {
        super.layout()
        let showText = bounds.width >= 180 && bounds.height >= 150
        let showWarning = bounds.width >= 96 && bounds.height >= 96
        textField.isHidden = !showText
        warningView.isHidden = !showWarning
    }

    func update(appName: String?, icon: NSImage?, selected: Bool) -> Bool {
        let changed = currentAppName != appName || currentIcon !== icon || isSelected != selected
        guard changed else { return false }

        currentAppName = appName
        currentIcon = icon
        isSelected = selected
        iconView.image = icon ?? NSImage(named: NSImage.applicationIconName)
        toolTip = appName
        refreshAppearance()
        return true
    }

    private func refreshAppearance() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.borderWidth = isSelected ? 2 : 1
        layer.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.28)).cgColor
        layer.backgroundColor = NSColor.black.cgColor
    }
}
