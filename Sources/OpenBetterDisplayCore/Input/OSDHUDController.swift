import Cocoa
import QuartzCore

/// Thin animated progress bar used inside the HUD.
final class OSDProgressView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private(set) var progress: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        fillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        applyLayout(animated: false)
    }

    func setProgress(_ value: Double, animated: Bool) {
        progress = min(max(value, 0), 1)
        applyLayout(animated: animated)
    }

    private func applyLayout(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        let h = bounds.height
        trackLayer.frame = bounds
        trackLayer.cornerRadius = h / 2
        fillLayer.frame = NSRect(x: 0, y: 0, width: max(h, bounds.width * progress), height: h)
        fillLayer.cornerRadius = h / 2
        fillLayer.isHidden = progress <= 0
        CATransaction.commit()
    }
}

/// Translucent, click-through, non-activating on-screen display shown near the bottom-center of a screen.
@MainActor
public final class OSDHUDController {
    public nonisolated static let panelSize = NSSize(width: 240, height: 112)
    public nonisolated static let bottomMargin: CGFloat = 96
    public nonisolated static let defaultDuration: TimeInterval = 1.8

    /// Master switch (wired to `AppSettings.showOSD`).
    public var isEnabled = true
    /// Default duration (wired to `AppSettings.osdDurationSeconds`).
    public var duration: TimeInterval = OSDHUDController.defaultDuration

    private var panel: NSPanel?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var progressView: OSDProgressView?
    private var hideTimer: Timer?

    public init() {}

    deinit {
        hideTimer?.invalidate()
    }

    public func apply(settings: AppSettings) {
        isEnabled = settings.showOSD
        duration = settings.osdDurationSeconds
    }

    // MARK: - Pure helpers

    public nonisolated static func symbolName(for item: OSDItem) -> String {
        switch item.kind {
        case .brightness:
            return "sun.max.fill"
        case .mute:
            return "speaker.slash.fill"
        case .volume:
            if item.isMuted { return "speaker.slash.fill" }
            let v = item.value ?? 0
            if v <= 0 { return "speaker.fill" }
            if v < 0.34 { return "speaker.wave.1.fill" }
            if v < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .notice:
            return "display"
        }
    }

    /// Bottom-center frame within the screen's visible area.
    public nonisolated static func panelFrame(visibleFrame: NSRect, size: NSSize = OSDHUDController.panelSize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + OSDHUDController.bottomMargin,
            width: size.width,
            height: size.height
        )
    }

    /// Fill amount for the progress bar (0 when muted).
    public nonisolated static func progressValue(for item: OSDItem) -> Double? {
        if item.kind == .mute || (item.kind == .volume && item.isMuted) { return 0 }
        guard let v = item.value else { return nil }
        return min(max(v, 0), 1)
    }

    // MARK: - Display

    public func show(_ item: OSDItem, duration customDuration: TimeInterval? = nil) {
        guard isEnabled else { return }
        let panel = ensurePanel()

        let symbol = OSDHUDController.symbolName(for: item)
        iconView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
        titleLabel?.stringValue = item.title
        subtitleLabel?.stringValue = item.subtitle ?? ""
        subtitleLabel?.isHidden = (item.subtitle ?? "").isEmpty

        if let progress = OSDHUDController.progressValue(for: item) {
            progressView?.isHidden = false
            progressView?.setProgress(progress, animated: panel.isVisible)
        } else {
            progressView?.isHidden = true
        }

        let screen = targetScreen(for: item)
        let frame = OSDHUDController.panelFrame(visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: false)

        hideTimer?.invalidate()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let seconds = max(customDuration ?? duration, 0.2)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    public func hide(animated: Bool = true) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel = panel, panel.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    // Only order out if no newer show() re-timed the HUD.
                    if self.hideTimer == nil { panel.orderOut(nil) }
                }
            })
        } else {
            panel.orderOut(nil)
        }
    }

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var currentPanel: NSPanel? { panel }

    // MARK: - Internals

    private func targetScreen(for item: OSDItem) -> NSScreen {
        if let id = item.displayID, let screen = OverlayManager.screen(for: id) { return screen }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return screen }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func ensurePanel() -> NSPanel {
        if let panel = panel { return panel }
        let size = OSDHUDController.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true // note: resets `level`, so the level must be set afterwards
        panel.level = NSWindow.Level(rawValue: OverlayManager.overlayWindowLevel.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .none
        panel.canHide = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: (size.width - 40) / 2, y: size.height - 56, width: 40, height: 40))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        let title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 12, y: 44, width: size.width - 24, height: 18)
        title.alignment = .center
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: "")
        subtitle.frame = NSRect(x: 12, y: 26, width: size.width - 24, height: 16)
        subtitle.alignment = .center
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.7)
        subtitle.lineBreakMode = .byTruncatingTail

        let bar = OSDProgressView(frame: NSRect(x: 24, y: 12, width: size.width - 48, height: 6))

        effect.addSubview(icon)
        effect.addSubview(title)
        effect.addSubview(subtitle)
        effect.addSubview(bar)
        panel.contentView = effect

        self.panel = panel
        self.iconView = icon
        self.titleLabel = title
        self.subtitleLabel = subtitle
        self.progressView = bar
        return panel
    }
}
