//
//  GlassLabBenchHUDPanel.swift
//  LiquidGlassLab
//
//  Bench: the frozen-baseline acceptance vehicle — a real non-activating HUD
//  panel that is never key or main, rendering an AdjustableGlassEffectView
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

        var frozenSelection: GlassMaterialStrength.FrozenAppearanceSelection {
            switch self {
            case .light: .light
            case .dark: .dark
            case .auto: .system
            }
        }
    }

    private var panel: NSPanel?
    private(set) var glassView: AdjustableGlassEffectView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?

    private var atlas: GlassMaterialStyleAtlas?
    private var appearance: Appearance = .auto
    private var isClear = false
    private var isMuted = false
    private var strengthValue = 1.0
    private var tintColor: NSColor?
    private var contentSize = CGSize(width: 320, height: 120)
    private var experimentalOuterPasses: AdjustableGlassOuterPasses = [
        .ringShadow,
        .bleed,
        .outerRefraction,
    ]
    private var experimentalMarginWidth: CGFloat? = 0
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

    var nativeRequiredWindowInset: CGFloat {
        nativeRequiredInset(for: min(contentSize.width, contentSize.height))
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
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        panel?.appearance = appearance.nsAppearance
        refreeze()
        scheduleFreezeRetryIfNeeded()
        updateLabels()
    }

    func setClear(_ isClear: Bool) {
        guard self.isClear != isClear else { return }
        self.isClear = isClear
        if let glassView {
            glassView.style = isClear ? .clear : .regular
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
        glassView?.effectAmount = CGFloat(value)
        updateLabels()
    }

    func setTint(_ color: NSColor?) {
        tintColor = color
        glassView?.tintColor = color
    }

    func setContentSize(_ size: CGSize) {
        contentSize = size
        layoutPanel()
        updateLabels()
    }

    func setRenderExperiment(
        outerPasses: AdjustableGlassOuterPasses,
        marginWidth: CGFloat?
    ) {
        experimentalOuterPasses = outerPasses
        experimentalMarginWidth = marginWidth
        applyRenderExperiment()
        layoutPanel()
        onStatusChanged?()
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

        let glassView = AdjustableGlassEffectView()
        glassView.useExternallyManagedMaterialStrength()
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
        glassView.style = isClear ? .clear : .regular
        glassView.tintColor = tintColor
        refreeze()
        glassView.effectAmount = CGFloat(strengthValue)
        applyRenderExperiment()
        layoutPanel()
        updateLabels()
    }

    private func applyRenderExperiment() {
        guard let glassView else { return }
        glassView.experimentalOuterPasses = experimentalOuterPasses
        glassView.experimentalMarginWidth = experimentalMarginWidth
    }

    private func refreeze() {
        guard let glassView else { return }
        if let atlas {
            let installed = glassView.materialStrength.freeze(
                atlas: atlas,
                mainParticipation: !isMuted,
                appearanceSelection: appearance.frozenSelection
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

    /// Sizes the panel to content plus the effective window room. The backing
    /// surface hard-clips at the window frame, so native mode uses the widest
    /// sampled margin and the experiment can replace it with an exact value.
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
        if let marginWidth = glassView?.experimentalMarginWidth {
            return GlassEffectController.windowInset(
                for: Double(marginWidth),
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            )
        }
        return nativeRequiredInset(for: shortSide)
    }

    private func nativeRequiredInset(for shortSide: Double) -> CGFloat {
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
        return GlassEffectController.windowInset(
            for: margin,
            osMajorVersion: ProcessInfo.processInfo
                .operatingSystemVersion.majorVersion
        )
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
