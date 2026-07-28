//
//  GlassMaterialStrength.swift
//  GlassMaterial
//
//  A continuous 0...1 material strength for NSGlassEffectView.
//
//  This is the entry point. Everything else in this directory supports it.
//

#if os(macOS)
import AppKit

/// One resolved style, captured from a live pristine tree and stamped verbatim
/// thereafter: endpoints, context flags, the untinted color grades, and the
/// rim gate all stop following the window and stay at the captured context.
///
/// This is how a glass is locked to a context its window is not actually in —
/// a HUD panel that should always render the Main-On DarkAqua Regular material
/// even while another window is main. Writes to the private tree are not gated
/// by window state; only the system's own resolver is, and the frozen restamp
/// outlives its rebuilds.
///
/// Capture from a glass that genuinely *is* in the context to lock — main/key
/// window, forced `NSAppearance` — on the same display and at the same
/// geometry as the destination:
///
///     let style = GlassMaterialFrozenStyle.capture(from: probeGlass)!
///     hudGlass.materialStrength.freezeStyle(style)
///
/// Geometry is part of the capture: size-scaled endpoints (the
/// `0.35 · shortSide` bleed family, the shadow family, per-context blur caps)
/// are baked into the baseline, so a frozen style is exact only at the short
/// side it was captured at. Freeze fixed-size surfaces, or recapture after a
/// resize. A handful of resolved fields are additionally display-sensitive
/// (the key-fill highlight offset/height family), so recapture applies after
/// moving to a different display too. Both are the reason the Golden fixture
/// values stay regression references rather than a runtime source: a capture
/// taken on the running machine is correct where a burned-in table is not.
public struct GlassMaterialFrozenStyle {
    public let baseline: GlassMaterialBaseline
    public let isClear: Bool
    public let hasMainParticipation: Bool
    public let isLightAppearance: Bool
    /// The untinted Content/Rim `vibrantColorMatrix` grades, in the same
    /// deterministic traversal order they are restamped in. The transition
    /// never animates these, but the resolver re-grades them per
    /// appearance/participation — leaving them unwritten would blend the
    /// frozen material with the window's real state after every rebuild.
    public let colorMatrices: [[Float]]

    /// Captures the currently resolved style, or nil when the tree is missing
    /// or already mutated (`inputFaceOpacity < 0.999`). Capture at
    /// `value == 1`, before dialing strength down.
    @MainActor
    public static func capture(
        from glass: NSGlassEffectView
    ) -> GlassMaterialFrozenStyle? {
        guard let baseline = GlassMaterialStrength.captureBaseline(from: glass),
              baseline.isPristine else { return nil }
        return GlassMaterialFrozenStyle(
            baseline: baseline,
            isClear: GlassMaterialStrength.isClear(glass),
            hasMainParticipation: GlassMaterialStrength
                .hasMainParticipation(glass),
            isLightAppearance: GlassMaterialStrength.isLightAppearance(glass),
            colorMatrices: GlassMaterialAccess.untintedMatrixLayers(under: glass)
                .compactMap(GlassMaterialAccess.colorMatrix)
        )
    }
}

/// Continuously dials an `NSGlassEffectView` between its system-resolved
/// material at `1` and a fully dematerialized surface at `0`, coordinating
/// every contributing pass rather than fading the composited result.
///
/// `view.alphaValue` destroys tint, blur, refraction, edge lighting, and
/// contrast simultaneously. This coordinates the underlying passes instead, so
/// intermediate values still read as glass.
///
///     let strength = GlassMaterialStrength(glass: glassView)
///     strength.value = 0.5
///
/// Endpoints are read from the live Recipe, so size, appearance, Regular/Clear,
/// window participation, and subvariant are all followed automatically. Call
/// `refresh()` after any layout pass or Recipe rebuild; `GlassMaterialEffectView`
/// does that for you.
///
/// To *stop* following the window instead — render a captured context such as
/// Main-On DarkAqua Regular regardless of the window's real state — install a
/// `GlassMaterialFrozenStyle` via `freezeStyle(_:)`. `value` then interpolates
/// against the frozen endpoints and context until `unfreezeStyle()`.
///
/// ## Scope
///
/// Measured on macOS 26.6 and macOS 27.0 for the public Regular and Clear
/// materials in a panel. Not validated on private semantic roles or on non-panel
/// hosts. Three behaviors are discrete by design and cannot be smoothed: the rim
/// and SDR holding-tone gates open at any `value > 0`, and Clear in DarkAqua
/// steps one bleed blend flag at `0.5`.
///
/// Mid-transition accuracy degrades away from a ~200pt short side, bounded by
/// `min(5%, 4 / shortSide)` for every channel at or above 200pt on both systems.
/// Endpoints stay exact at every size.
///
/// Every channel is monotonic in `value` on macOS 26. On macOS 27 one is not:
/// `inputBlurOpacity0` resolves to `g · (1 - (1 - endpoint)g)`, whose derivative
/// vanishes at `g = 1 / (2(1 - endpoint))`, so it rises and falls inside `0...1`
/// for any endpoint below 0.5 — including the flat zero Regular resolves below a
/// 64pt short side.
///
/// **Perceived blur is still monotonic**, and that is the property that matters.
/// `inputBlurOpacity2` is quadratic, so it starts slower than linear and runs a
/// deficit of `0.3 · g(1 - g)` early in the ramp; `inputBlurOpacity0` carries that
/// early load and hands off as the quadratic catches up. The two are a crossfade.
/// Their sum rises monotonically to its resting value and never steps back by
/// more than 2.9% of it, measured over 56 cells.
///
/// This is why the hump is reproduced rather than flattened. Suppressing it would
/// not buy a monotonic strength control — it would delete the compensator and
/// leave the slow-starting quadratic alone, so blur would arrive late and
/// abruptly: at `value = 0.25` on a gated endpoint the pair reads 0.26 with the
/// hump and 0.07 without, a 3.7× difference in the wrong direction. Asserted by
/// `the-blur-taps-crossfade-so-perceived-blur-stays-monotonic`.
///
/// One measured exception remains, and it is **macOS 26 only**. Below 200pt the
/// bound holds for everything except two face color-grade channels while fading
/// *out*: `inputFaceColorMatrixBlack` and `inputFaceColorMatrixWhite` reach
/// about 17% at a 48pt short side. The cause is measured rather than guessed —
/// at small sizes a long-lived glass and one that has just completed a
/// Materialize In resolve *different* face grades (0.49 versus 0.80 at 48pt), so
/// "full strength" is not a single value there and no single read endpoint can
/// replay the whole fade. Both endpoints themselves stay exact, geometry, blur,
/// refraction, and shadow stay inside the ordinary bound, and the visible effect
/// is a mid-fade tone difference rather than a pop or a wrong material. Accepted
/// as-is: see `Golden/learnings/cross-section.mjs`, which reports the diverging
/// sizes and channels on every capture.
///
/// macOS 27 resolves a single endpoint at 48, 200, and 400pt, so nothing
/// diverges there. What it adds instead is 22 new `glassBackground` inputs, 17 of
/// which animate; all 17 are linear in face progress and are in the table. Its
/// one non-linearity is the size-gated backdrop blur, reproduced exactly by the
/// saturation-deficit term in `GlassMaterialCurve`. The residual on macOS 27 is a
/// 0.05 mid-transition hump on `inputBlurOpacity1` under Regular, inside the
/// ordinary bound and deliberately left unmodelled — see
/// `gated-blur-overshoots-by-its-saturation-deficit`.
@MainActor
public final class GlassMaterialStrength {
    private weak var glass: NSGlassEffectView?
    private var baseline: GlassMaterialBaseline?
    private var appliedValue: Double = 1
    private var lastWrittenFilterIdentity: ObjectIdentifier?

    /// The installed frozen style, if any. See `freezeStyle(_:)`.
    public private(set) var frozenStyle: GlassMaterialFrozenStyle?

    /// Material strength, clamped to `0...1`. Defaults to `1`, which leaves the
    /// system Recipe untouched until the first change.
    public var value: Double {
        didSet {
            value = min(max(value, 0), 1)
            guard value != oldValue else { return }
            apply()
        }
    }

    /// The public tint currently set on the glass, if any. Tint lives in its
    /// own pass branch and receives `sourceAlpha × value²`.
    public var tintColor: NSColor? {
        didSet { apply() }
    }

    /// False when the glass has no `glassBackground` pass yet — before first
    /// layout, or for a Variant that resolves without one.
    public var isAvailable: Bool { baseline != nil || frozenStyle != nil }

    public init(glass: NSGlassEffectView, value: Double = 1) {
        self.glass = glass
        self.value = min(max(value, 0), 1)
        refresh()
    }

    /// Re-reads endpoints if the tree is pristine, then re-applies the current
    /// value. Safe and cheap to call on every layout pass.
    ///
    /// AppKit hands back a freshly resolved tree after a resize, appearance
    /// change, or Recipe rebuild. Catching it here is what moves the endpoints
    /// to the new context. Filter identity plus the last applied face opacity
    /// distinguish a fresh endpoint from this controller's own near-1 write.
    public func refresh() {
        guard let glass else { return }
        guard let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) else {
            baseline = nil
            lastWrittenFilterIdentity = nil
            return
        }

        // A frozen style never re-adopts: whatever the resolver just wrote for
        // the window's real context is exactly what the freeze exists to
        // override. Adoption would also read back our own frozen values as a
        // "pristine" live baseline and poison a later unfreeze.
        if frozenStyle == nil {
            guard let candidate = Self.captureBaseline(
                from: glass,
                target: target
            ) else {
                baseline = nil
                lastWrittenFilterIdentity = nil
                return
            }
            let observedFace = candidate.numeric["inputFaceOpacity"]
            let looksLikeOurCurrentWrite =
                appliedValue < 1
                && lastWrittenFilterIdentity == target.identity
                && observedFace.map {
                    abs($0 - appliedValue) <= 0.000_001
                } == true
            if candidate.isPristine, !looksLikeOurCurrentWrite {
                baseline = candidate
            }
        }
        apply(to: target)
    }

    /// Locks the glass to the style it is resolving right now. Returns false
    /// when the tree is absent or not pristine — freeze at `value == 1`, in
    /// the context to lock, before dialing strength down.
    @discardableResult
    public func freezeStyle() -> Bool {
        guard let glass,
              let style = GlassMaterialFrozenStyle.capture(from: glass)
        else { return false }
        freezeStyle(style)
        return true
    }

    /// Installs a style captured elsewhere — typically from a probe glass in
    /// the context to lock — and stamps it immediately. While frozen, `value`
    /// interpolates against the captured endpoints and context: participation
    /// selects the captured blur shapes, the rim gate follows the captured
    /// opacity, and the untinted color grades are restamped after every
    /// system rebuild.
    public func freezeStyle(_ style: GlassMaterialFrozenStyle) {
        frozenStyle = style
        baseline = nil
        lastWrittenFilterIdentity = nil
        apply()
    }

    /// Returns to live-read behavior. The frozen values persist on the tree
    /// until AppKit next rebuilds it, at which point the freshly resolved
    /// Recipe is adopted as the live baseline again; as everywhere else, an
    /// immediate true restore requires recreating the glass view.
    public func unfreezeStyle() {
        frozenStyle = nil
        refresh()
    }

    /// Stops tracking and returns the controller to a neutral state.
    ///
    /// This does **not** restore the system material: an installed
    /// `glassBackground` override survives until the glass is rebuilt. Discard
    /// and recreate the `NSGlassEffectView` for a true restore.
    public func invalidate() {
        baseline = nil
        frozenStyle = nil
        lastWrittenFilterIdentity = nil
    }

    // MARK: Internals

    static func captureBaseline(
        from glass: NSGlassEffectView
    ) -> GlassMaterialBaseline? {
        guard let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) else { return nil }
        return captureBaseline(from: glass, target: target)
    }

    private static func captureBaseline(
        from glass: NSGlassEffectView,
        target: GlassMaterialAccess.GlassBackgroundTarget
    ) -> GlassMaterialBaseline? {
        let numeric = GlassMaterialAccess.readNumbers(from: target)
        guard !numeric.isEmpty else { return nil }
        return GlassMaterialBaseline(
            numeric: numeric,
            colors: GlassMaterialAccess.readColors(
                from: target,
                keys: GlassMaterialCurve.colorKeys
            ),
            rimOpacity: GlassMaterialAccess.rimLayers(under: glass)
                .map(GlassMaterialAccess.rimOpacity)
                .max(),
            shortSide: min(glass.bounds.width, glass.bounds.height)
        )
    }

    private func apply(
        to suppliedTarget: GlassMaterialAccess.GlassBackgroundTarget? = nil
    ) {
        let frozen = frozenStyle
        guard let glass,
              let baseline = frozen?.baseline ?? baseline,
              let target = suppliedTarget
                ?? GlassMaterialAccess.glassBackgroundTarget(under: glass)
        else { return }

        let isClear = frozen?.isClear ?? Self.isClear(glass)
        let hasMain = frozen?.hasMainParticipation
            ?? Self.hasMainParticipation(glass)
        let isLight = frozen?.isLightAppearance ?? Self.isLightAppearance(glass)

        var numbers = GlassMaterialCurve.numericValues(
            at: value,
            baseline: baseline,
            isClear: isClear,
            hasMainParticipation: hasMain,
            isLightAppearance: isLight
        )
        // A frozen style also owns the captured inputs the curve never
        // animates. The resolver re-resolves those per participation and
        // appearance, so leaving them unwritten would blend the frozen
        // material with the window's real state after every rebuild. They are
        // constants: the system holds them through the whole transition too.
        if frozen != nil {
            for (key, endpoint) in baseline.numeric where numbers[key] == nil {
                numbers[key] = endpoint
            }
        }
        let colors = GlassMaterialCurve.colorValues(at: value, baseline: baseline)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, number) in numbers {
            GlassMaterialAccess.write(number, forKey: key, to: target)
        }
        for (key, color) in colors {
            GlassMaterialAccess.write(color.cgColor, forKey: key, to: target)
        }
        CATransaction.commit()

        // Live mode leaves the rim to the system unless Main is genuinely
        // held. A frozen style owns the gate in both directions: it opens a
        // captured Main-On rim on a window that is not main, and holds a
        // captured Subdued rim closed on one that is.
        if frozen != nil || hasMain {
            let opacity = hasMain
                ? GlassMaterialCurve.rimOpacity(at: value, baseline: baseline)
                : 0
            for layer in GlassMaterialAccess.rimLayers(under: glass) {
                GlassMaterialAccess.setRimOpacity(opacity, on: layer)
            }
        }

        if let frozen, !frozen.colorMatrices.isEmpty {
            let layers = GlassMaterialAccess.untintedMatrixLayers(under: glass)
            // Stamped pairwise in the shared traversal order; a count mismatch
            // means the topology is not the one captured (Variant change,
            // mid-rebuild sample) and nothing is guessed.
            if layers.count == frozen.colorMatrices.count {
                for (layer, matrix) in zip(layers, frozen.colorMatrices) {
                    GlassMaterialAccess.setColorMatrix(matrix, on: layer)
                }
            }
        }

        if let tintColor,
           let sourceAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent,
           let tintLayer = GlassMaterialAccess.tintMatrixLayer(under: glass),
           var matrix = GlassMaterialAccess.colorMatrix(on: tintLayer) {
            matrix[18] = Float(
                GlassMaterialCurve.tintMatrixAlpha(
                    at: value,
                    sourceAlpha: Double(sourceAlpha)
                )
            )
            GlassMaterialAccess.setColorMatrix(matrix, on: tintLayer)
        }

        appliedValue = value
        // Owning-layer writes replace the immutable CAFilter object. Record
        // the identity after the final write, not the target captured before
        // the frame, or the next layout would mistake our own near-1 output
        // for a newly resolved Recipe.
        lastWrittenFilterIdentity =
            GlassMaterialAccess.glassBackgroundFilterIdentity(on: target.layer)
    }

    /// Reads the resolved Recipe index. Regular is 1 and Clear is 2; anything
    /// else is treated as Regular-like, which is the correct fallback because
    /// only Clear selects a different `inputClamp` shape.
    static func isClear(_ glass: NSGlassEffectView) -> Bool {
        let resolved = GlassMaterialAccess.valueIfResponds(
            forKey: "_variant",
            on: glass
        ) as? NSNumber
        return resolved?.intValue == 2
    }

    /// A window that is genuinely key *or* genuinely main receives the active
    /// Recipe; neither gets the flat one. Spoofed getters do not count, so this
    /// reads the real AppKit state.
    static func hasMainParticipation(_ glass: NSGlassEffectView) -> Bool {
        guard let window = glass.window else { return false }
        return window.isMainWindow || window.isKeyWindow
    }

    static func isLightAppearance(_ glass: NSGlassEffectView) -> Bool {
        glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }
}

/// An `NSGlassEffectView` that keeps its strength controller refreshed across
/// AppKit's own layout passes.
///
/// AppKit can replace the entire private filter/effect subtree after a resize
/// or context change, and the replacement arrives with system values. Hooking
/// the end of layout is what makes the authored strength the final writer.
@MainActor
public final class GlassMaterialEffectView: NSGlassEffectView {
    public private(set) lazy var materialStrength = GlassMaterialStrength(glass: self)

    private var isRefreshing = false

    override public func layout() {
        super.layout()
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        materialStrength.refresh()
    }

    // Main/key participation and appearance changes rewrite the Recipe
    // *without* a layout pass, so the layout hook alone would leave a frozen
    // style showing the system's freshly resolved values until the next
    // resize. Live mode benefits too: re-adopting the new endpoints no longer
    // waits for an unrelated layout.

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeParticipation(of: window)
        refreshNowAndAfterSystemRestamp()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshNowAndAfterSystemRestamp()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshNowAndAfterSystemRestamp()
    }

    private func observeParticipation(of window: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(participationDidChange),
                name: name,
                object: window
            )
        }
    }

    @objc private func participationDidChange(_ note: Notification) {
        refreshNowAndAfterSystemRestamp()
    }

    /// Refreshes immediately, then once more on the next runloop turn.
    ///
    /// Whether AppKit writes an intermediate Recipe between a participation
    /// change and this restamp is the open P2 question in the research
    /// roadmap. The trailing refresh makes the authored state the final
    /// writer either way, bounding any system write to a single frame until
    /// that question is settled by capture.
    private func refreshNowAndAfterSystemRestamp() {
        materialStrength.refresh()
        Task { @MainActor [weak self] in
            self?.materialStrength.refresh()
        }
    }
}
#endif
