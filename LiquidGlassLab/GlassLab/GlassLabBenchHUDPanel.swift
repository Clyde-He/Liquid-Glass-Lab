//
//  GlassLabBenchHUDPanel.swift
//  LiquidGlassLab
//
//  Bench: the frozen-baseline acceptance vehicle — a real non-activating HUD
//  panel that is never key or main, rendering a GlassMaterialEffectView
//  frozen from a captured style atlas. This is the product contract under
//  test: Light/Dark/Auto, Regular/Clear, Normal/Muted participation, Glass
//  Visibility, Tint, and content-driven size with no recapture.
//

#if os(macOS)
import AppKit

@MainActor
final class GlassLabHUDPanelController {
    enum Appearance: String, CaseIterable, Identifiable {
        case light = "Light"
        case dark = "Dark"
        case auto = "Auto"

        var id: Self { self }

        var nsAppearance: NSAppearance? {
            switch self {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .auto: nil
            }
        }
    }

    private var panel: NSPanel?
    private(set) var glassView: GlassMaterialEffectView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?

    private var atlas: GlassMaterialStyleAtlas?
    private var appearance: Appearance = .auto
    private var isClear = false
    private var isMuted = false
    private var strengthValue = 1.0
    private var tintColor: NSColor?
    private var contentSize = CGSize(width: 320, height: 120)
    private var freezeRetryTask: Task<Void, Never>?

    var onStatusChanged: (() -> Void)?

    /// The result of the most recent freeze attempt, for the Bench readout.
    private(set) var lastFreezeSucceeded = false

    var isVisible: Bool { panel?.isVisible ?? false }

    var strengthIsAvailable: Bool {
        glassView?.materialStrength.isAvailable ?? false
    }

    var windowIsMainOrKey: Bool {
        guard let panel else { return false }
        return panel.isMainWindow || panel.isKeyWindow
    }

    /// The window room currently reserved around the glass.
    private(set) var currentInset: CGFloat = 16

    // MARK: Lifecycle

    func show() {
        buildPanelIfNeeded()
        panel?.orderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        applyEverything()
        scheduleFreezeRetryIfNeeded()
        onStatusChanged?()
    }

    func hide() {
        panel?.orderOut(nil)
        onStatusChanged?()
    }

    func tearDown() {
        freezeRetryTask?.cancel()
        freezeRetryTask = nil
        panel?.orderOut(nil)
        panel = nil
        glassView = nil
        titleLabel = nil
        detailLabel = nil
    }

    // MARK: Controls (the product contract)

    func setAtlas(_ atlas: GlassMaterialStyleAtlas?) {
        self.atlas = atlas
        refreeze()
        scheduleFreezeRetryIfNeeded()
        layoutPanel()
    }

    func setAppearance(_ appearance: Appearance) {
        self.appearance = appearance
        panel?.appearance = appearance.nsAppearance
        updateLabels()
    }

    func setClear(_ isClear: Bool) {
        guard self.isClear != isClear else { return }
        self.isClear = isClear
        if let glassView {
            glassView.materialStyle = isClear ? .clear : .regular
        }
        updateLabels()
    }

    func setMuted(_ isMuted: Bool) {
        guard self.isMuted != isMuted else { return }
        self.isMuted = isMuted
        refreeze()
        scheduleFreezeRetryIfNeeded()
        layoutPanel()
        updateLabels()
    }

    func setStrength(_ value: Double) {
        strengthValue = value
        glassView?.materialVisibility = value
        updateLabels()
    }

    func setTint(_ color: NSColor?) {
        tintColor = color
        glassView?.materialTint = color
    }

    func setContentSize(_ size: CGSize) {
        contentSize = size
        layoutPanel()
        updateLabels()
    }

    // MARK: Internals

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container

        let glassView = GlassMaterialEffectView()
        glassView.cornerRadius = 24
        container.addSubview(glassView)

        let title = NSTextField(labelWithString: "Liquid Glass HUD")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        container.addSubview(title)

        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        container.addSubview(detail)

        self.panel = panel
        self.glassView = glassView
        self.titleLabel = title
        self.detailLabel = detail

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - 200,
                y: frame.midY - 90
            ))
        }
    }

    private func applyEverything() {
        guard let panel, let glassView else { return }
        panel.appearance = appearance.nsAppearance
        glassView.materialStyle = isClear ? .clear : .regular
        glassView.materialTint = tintColor
        refreeze()
        glassView.materialVisibility = strengthValue
        layoutPanel()
        updateLabels()
    }

    private func refreeze() {
        guard let glassView else { return }
        if let atlas {
            let installed = glassView.materialStrength.freeze(
                atlas: atlas,
                mainParticipation: !isMuted
            )
            lastFreezeSucceeded = installed
                && glassView.materialStrength.frozenStyleIsCurrentlyApplied
        } else {
            lastFreezeSucceeded = false
            glassView.materialStrength.unfreeze()
        }
        onStatusChanged?()
    }

    /// `NSGlassEffectView` can expose the background pass before its grade and
    /// rim topology has materialized. A product HUD must not interpret that
    /// transient refusal as an invalid atlas, and must not require an unrelated
    /// user event to try again after the panel becomes visible.
    private func scheduleFreezeRetryIfNeeded() {
        freezeRetryTask?.cancel()
        guard atlas != nil, !lastFreezeSucceeded else { return }
        freezeRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 80, 160, 320, 640, 1000] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, self.isVisible else { return }
                self.refreeze()
                if self.lastFreezeSucceeded {
                    self.layoutPanel()
                    return
                }
            }
        }
    }

    /// Sizes the panel to content plus the sampled window room. The backing
    /// surface hard-clips at the window frame, so the glass sits inset by at
    /// least the atlas's `marginWidth` for the current short side — the one
    /// transplant group that cannot be restamped (README group 5).
    private func layoutPanel() {
        guard let panel, let glassView else { return }
        let shortSide = min(contentSize.width, contentSize.height)
        currentInset = requiredInset(for: shortSide)

        let total = CGSize(
            width: contentSize.width + currentInset * 2,
            height: contentSize.height + currentInset * 2
        )
        let topLeft = NSPoint(
            x: panel.frame.minX,
            y: panel.frame.maxY
        )
        panel.setContentSize(total)
        panel.setFrameTopLeftPoint(topLeft)

        glassView.frame = NSRect(
            x: currentInset,
            y: currentInset,
            width: contentSize.width,
            height: contentSize.height
        )
        if let title = titleLabel, let detail = detailLabel {
            let mid = contentSize.height / 2 + currentInset
            title.frame = NSRect(
                x: currentInset,
                y: mid,
                width: contentSize.width,
                height: 20
            )
            detail.frame = NSRect(
                x: currentInset,
                y: mid - 22,
                width: contentSize.width,
                height: 16
            )
        }
    }

    /// The widest sampled `marginWidth` across the selected participation's
    /// cells at this short side, so appearance/variant switches never outgrow
    /// the room.
    /// Falls back to the measured `max(16, 0.35 · shortSide)` shape before an
    /// atlas exists.
    private func requiredInset(for shortSide: Double) -> CGFloat {
        var margin = max(16.0, 0.35 * shortSide)
        if let atlas = glassView?.materialStrength.frozenAtlas {
            for isLight in [true, false] {
                for isClear in [true, false] {
                    let cell = GlassMaterialStyleAtlas.Cell(
                        isLightAppearance: isLight,
                        isClear: isClear,
                        hasMainParticipation: !isMuted
                    )
                    if let sampled = atlas.sample(
                        for: cell,
                        at: shortSide
                    )?.marginWidth {
                        margin = max(margin, sampled)
                    }
                }
            }
        }
        return ceil(margin) + 1
    }

    private func updateLabels() {
        guard let detailLabel else { return }
        let material = isClear ? "Clear" : "Regular"
        let emphasis = isMuted ? "Muted" : "Normal"
        detailLabel.stringValue = String(
            format: "%@ · %@ · %@ · G %.2f · %.0f×%.0f",
            material,
            appearance.rawValue,
            emphasis,
            strengthValue,
            contentSize.width,
            contentSize.height
        )
    }
}
#endif
