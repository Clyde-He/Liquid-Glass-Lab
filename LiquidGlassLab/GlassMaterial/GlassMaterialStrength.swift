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
/// To *stop* following the window's participation instead — render the Main-On
/// material on a window that is never main — freeze a captured
/// `GlassMaterialStyleAtlas` with `freeze(atlas:)`. Appearance and variant stay
/// live (Light/Dark/Auto and Regular/Clear switch by selecting atlas cells),
/// size follows by interpolating the atlas samples, and `value` interpolates
/// the selected style until `unfreeze()`.
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
    private var frozenMainParticipation = true
    /// The destination `inputKeys` set whose managed inputs were last
    /// verified as covered by the frozen sample. See
    /// `sampleCoversDestination(_:target:)`.
    private var coverageVerifiedInputKeys: Set<String>?

    /// The installed style atlas, if any. See `freeze(atlas:)`.
    public private(set) var frozenAtlas: GlassMaterialStyleAtlas?

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
    /// own pass branch and receives `sourceAlpha × value²`. While frozen, the
    /// atlas cell's captured Main-context matrix supplies the hue coefficients
    /// too, because a non-main window resolves the hue-suppressed variant.
    public var tintColor: NSColor? {
        didSet { apply() }
    }

    /// True when the glass currently has a `glassBackground` pass and this
    /// controller has values to drive it — a live baseline, or a frozen atlas
    /// whose selected cell can be stamped onto the *complete* current tree.
    /// While the destination is partially rebuilt, the frozen restamp writes
    /// nothing (see `frozenDestination(for:target:on:)`) and this reports false for
    /// the same window, rather than active-but-unwritten. The cell check is
    /// defensive: `freeze(atlas:)` refuses an atlas that could miss one.
    public var isAvailable: Bool {
        guard let glass,
              let target = GlassMaterialAccess.glassBackgroundTarget(
                under: glass
              )
        else { return false }
        if let frozenAtlas {
            guard let sample = frozenAtlas.sample(
                for: currentCell(for: glass),
                at: min(glass.bounds.width, glass.bounds.height)
            ) else { return false }
            return frozenDestination(
                for: sample,
                target: target,
                on: glass
            ) != nil
        }
        return baseline != nil
    }

    private func currentCell(
        for glass: NSGlassEffectView
    ) -> GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: Self.isLightAppearance(glass),
            isClear: Self.isClear(glass),
            hasMainParticipation: frozenMainParticipation
        )
    }

    /// The complete destination topology a frozen restamp writes to, or nil
    /// while any part of it is missing. A partially rebuilt tree can expose
    /// `glassBackground` while the grade, rim, output, or tint layers are
    /// still absent; stamping the groups that do exist and skipping the rest
    /// would leave a hybrid material on screen until another context event.
    /// Writing nothing keeps the tree consistently system-resolved for the
    /// next refresh — and `isAvailable` runs the same check, so callers see
    /// the frozen material as inactive during that window rather than active
    /// but unwritten.
    private func frozenDestination(
        for sample: GlassMaterialStyleSample,
        target: GlassMaterialAccess.GlassBackgroundTarget,
        on glass: NSGlassEffectView
    ) -> (matrixLayers: [CALayer], rimLayers: [CALayer])? {
        guard sampleCoversDestination(sample, target: target) else {
            return nil
        }
        let matrixLayers = GlassMaterialAccess.untintedMatrixLayers(under: glass)
        let rimLayers = GlassMaterialAccess.rimLayers(under: glass)
        guard matrixLayers.count == sample.matrices.count,
              rimLayers.count == sample.rims.count,
              GlassMaterialAccess.marginWidth(under: glass) != nil,
              GlassMaterialAccess.outputBounds(under: glass) != nil
        else { return nil }
        if tintColor != nil {
            guard let tintLayer = GlassMaterialAccess.tintMatrixLayer(
                under: glass
            ), GlassMaterialAccess.colorMatrix(on: tintLayer) != nil
            else { return nil }
        }
        return (matrixLayers, rimLayers)
    }

    /// True when every *managed* input the destination declares — one that
    /// resolves a number, color, pair, or nil — is a key the sample captured.
    /// A destination with managed inputs the sample never saw was resolved by
    /// a different shader generation (an atlas persisted across an OS
    /// upgrade); replaying onto it would hold the unknown inputs at the
    /// window's real-context values, the exact bug class the macOS 27 landing
    /// documented. Coverage is deliberately one-directional: sample keys the
    /// destination lacks are harmless, since writes are capability-guarded.
    ///
    /// The typed classification costs one full read, so the verdict is cached
    /// against the destination's `inputKeys` set — stable for a given shader
    /// generation, and revalidated automatically if a rebuild changes it.
    private func sampleCoversDestination(
        _ sample: GlassMaterialStyleSample,
        target: GlassMaterialAccess.GlassBackgroundTarget
    ) -> Bool {
        if coverageVerifiedInputKeys == target.inputKeys { return true }
        let typed = GlassMaterialAccess.readTypedInputs(from: target)
        let managed = Set(typed.numeric.keys)
            .union(typed.colors.keys)
            .union(typed.points.keys)
            .union(typed.nilKeys)
        guard managed.subtracting(sample.capturedKeys).isEmpty else {
            return false
        }
        coverageVerifiedInputKeys = target.inputKeys
        return true
    }

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

        // A frozen controller never re-adopts: whatever the resolver just
        // wrote for the window's real context is exactly what the freeze
        // exists to override. Adoption would also read back our own frozen
        // values as a "pristine" live baseline and poison a later unfreeze.
        if frozenAtlas == nil {
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

    /// Locks the glass to the captured atlas and stamps it immediately.
    /// Returns false — installing nothing — unless the atlas covers the
    /// complete appearance × variant cell space for the frozen participation.
    ///
    /// Coverage is validated here rather than discovered at a later context
    /// switch: appearance and variant change at runtime by design, and a
    /// cell miss after a switch would strand the previous cell's authored
    /// values with nothing tracking `value`. Rejecting a partial atlas keeps
    /// that state unreachable in the supported domain.
    ///
    /// Participation is the frozen axis: `mainParticipation` selects which
    /// captured cells serve, independent of the window's real state.
    /// Appearance and variant remain live — changing the view's
    /// `NSAppearance` (or following the system for Auto) and switching
    /// Regular/Clear select different atlas cells with no recapture — and
    /// size follows by interpolating each cell's samples at the current
    /// short side.
    @discardableResult
    public func freeze(
        atlas: GlassMaterialStyleAtlas,
        mainParticipation: Bool = true
    ) -> Bool {
        // Every sample is re-validated, not merely counted: a persisted atlas
        // decodes without running `capture`'s completeness guard, so a stale
        // or hand-edited file could otherwise install cells the restamp
        // would later skip against the live topology.
        for isLight in [true, false] {
            for isClear in [true, false] {
                let cell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: mainParticipation
                )
                guard atlas.cellMatchesSupportedTopology(cell) else {
                    return false
                }
            }
        }
        frozenAtlas = atlas
        frozenMainParticipation = mainParticipation
        baseline = nil
        lastWrittenFilterIdentity = nil
        coverageVerifiedInputKeys = nil
        apply()
        return true
    }

    /// Returns to live-read behavior. The frozen values persist on the tree
    /// until AppKit next rebuilds it, at which point the freshly resolved
    /// Recipe is adopted as the live baseline again; as everywhere else, an
    /// immediate true restore requires recreating the glass view.
    public func unfreeze() {
        frozenAtlas = nil
        coverageVerifiedInputKeys = nil
        refresh()
    }

    /// Stops tracking and returns the controller to a neutral state.
    ///
    /// This does **not** restore the system material: an installed
    /// `glassBackground` override survives until the glass is rebuilt. Discard
    /// and recreate the `NSGlassEffectView` for a true restore.
    public func invalidate() {
        baseline = nil
        frozenAtlas = nil
        lastWrittenFilterIdentity = nil
        coverageVerifiedInputKeys = nil
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
        guard let glass,
              let target = suppliedTarget
                ?? GlassMaterialAccess.glassBackgroundTarget(under: glass)
        else { return }
        if let frozenAtlas {
            applyFrozen(frozenAtlas, to: target, on: glass)
        } else {
            applyLive(to: target, on: glass)
        }
    }

    private func applyLive(
        to target: GlassMaterialAccess.GlassBackgroundTarget,
        on glass: NSGlassEffectView
    ) {
        guard let baseline else { return }

        let isClear = Self.isClear(glass)
        let hasMain = Self.hasMainParticipation(glass)

        let numbers = GlassMaterialCurve.numericValues(
            at: value,
            baseline: baseline,
            isClear: isClear,
            hasMainParticipation: hasMain,
            isLightAppearance: Self.isLightAppearance(glass)
        )
        let colors = GlassMaterialCurve.colorValues(at: value, baseline: baseline)
        writeShader(numbers: numbers, colors: colors, to: target)

        if hasMain {
            let opacity = GlassMaterialCurve.rimOpacity(at: value, baseline: baseline)
            for layer in GlassMaterialAccess.rimLayers(under: glass) {
                GlassMaterialAccess.setRimOpacity(opacity, on: layer)
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

        finishApply(to: target)
    }

    /// Stamps the interpolated atlas style: the interpolated shader vector
    /// driven by the curve, the captured inputs the curve never animates, the
    /// captured nils, the render-bounds group, both untinted color grades,
    /// and the complete rim payload. Anything short of the full transplant
    /// set blends the frozen material with the window's real state after
    /// every system rebuild.
    private func applyFrozen(
        _ atlas: GlassMaterialStyleAtlas,
        to target: GlassMaterialAccess.GlassBackgroundTarget,
        on glass: NSGlassEffectView
    ) {
        let isClear = Self.isClear(glass)
        let isLight = Self.isLightAppearance(glass)
        let cell = currentCell(for: glass)
        let shortSide = min(glass.bounds.width, glass.bounds.height)
        // Defensive only: freeze(atlas:) rejects an atlas that could miss a
        // cell, so in the supported domain this lookup always succeeds.
        guard let sample = atlas.sample(for: cell, at: shortSide) else { return }

        // Validate the complete destination topology before the first write;
        // an incomplete tree receives nothing at all. See
        // `frozenDestination(for:target:on:)`.
        guard let destination = frozenDestination(
            for: sample,
            target: target,
            on: glass
        ) else { return }
        let matrixLayers = destination.matrixLayers
        let rimLayers = destination.rimLayers

        var sampleColors: [String: NSColor] = [:]
        for (key, color) in sample.colors { sampleColors[key] = color.nsColor }
        let baseline = GlassMaterialBaseline(
            numeric: sample.numeric,
            colors: sampleColors.filter {
                GlassMaterialCurve.colorKeys.contains($0.key)
            },
            rimOpacity: sample.rims.map(\.layerOpacity).max(),
            shortSide: shortSide
        )

        var numbers = GlassMaterialCurve.numericValues(
            at: value,
            baseline: baseline,
            isClear: isClear,
            hasMainParticipation: frozenMainParticipation,
            isLightAppearance: isLight
        )
        // The captured inputs the curve never animates are constants: the
        // system holds them through the whole transition too, and the
        // resolver re-resolves them per participation on every rebuild.
        for (key, endpoint) in sample.numeric where numbers[key] == nil {
            numbers[key] = endpoint
        }
        var colors = GlassMaterialCurve.colorValues(at: value, baseline: baseline)
        for (key, color) in sampleColors where colors[key] == nil {
            colors[key] = color
        }
        writeShader(
            numbers: numbers,
            colors: colors,
            points: sample.points,
            nilKeys: sample.nilKeys,
            to: target
        )

        // Render bounds do not animate with the transition; they are part of
        // the context. Held constant across `value` — at 0 every visible
        // channel is already at its dematerialized endpoint.
        GlassMaterialAccess.setMarginWidth(sample.marginWidth, under: glass)
        GlassMaterialAccess.setOutputBounds(
            minimum: sample.outputMinimum,
            maximum: sample.outputMaximum,
            under: glass
        )

        // Grades and payloads are stamped pairwise in the shared traversal
        // order, against the topology validated above.
        for (layer, slot) in zip(matrixLayers, sample.matrices) {
            GlassMaterialAccess.setColorMatrix(slot.matrix, on: layer)
            GlassMaterialAccess.setMatrixScalarInputs(slot.inputs, on: layer)
        }

        // The frozen rim owns both the payload and the gate, in both
        // directions: it opens a captured Main-On rim on a window that is not
        // main, and holds a captured flat rim closed on one that is.
        for (layer, rim) in zip(rimLayers, sample.rims) {
            var rimColors: [String: NSColor] = [:]
            for (key, color) in rim.colors { rimColors[key] = color.nsColor }
            GlassMaterialAccess.setRimPayload(
                values: rim.values,
                colors: rimColors,
                on: layer
            )
            GlassMaterialAccess.setRimOpacity(
                value > 0 ? rim.layerOpacity : 0,
                on: layer
            )
        }

        if let tintColor,
           let sourceAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent,
           let tintLayer = GlassMaterialAccess.tintMatrixLayer(under: glass) {
            // The captured cell matrix carries the Main-context hue, and only
            // serves while it matches the current tint color. Without a
            // match, the live matrix serves with our alpha — hue-suppressed
            // as the window's real participation resolves it — until the new
            // color's matrix is captured and the atlas refrozen.
            var matrix = atlas.tintMatrix(for: cell, matching: tintColor)
                ?? GlassMaterialAccess.colorMatrix(on: tintLayer)
            if matrix?.count == 20 {
                matrix?[18] = Float(
                    GlassMaterialCurve.tintMatrixAlpha(
                        at: value,
                        sourceAlpha: Double(sourceAlpha)
                    )
                )
                if let matrix {
                    GlassMaterialAccess.setColorMatrix(matrix, on: tintLayer)
                }
            }
        }

        finishApply(to: target)
    }

    private func writeShader(
        numbers: [String: Double],
        colors: [String: NSColor],
        points: [String: CGPoint] = [:],
        nilKeys: Set<String> = [],
        to target: GlassMaterialAccess.GlassBackgroundTarget
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, number) in numbers {
            GlassMaterialAccess.write(number, forKey: key, to: target)
        }
        for (key, color) in colors {
            GlassMaterialAccess.write(color.cgColor, forKey: key, to: target)
        }
        for (key, point) in points {
            GlassMaterialAccess.writePair(point, forKey: key, to: target)
        }
        for key in nilKeys {
            GlassMaterialAccess.write(nil, forKey: key, to: target)
        }
        CATransaction.commit()
    }

    private func finishApply(
        to target: GlassMaterialAccess.GlassBackgroundTarget
    ) {
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

    // Participation and appearance changes rewrite the Recipe *without* a
    // layout pass, so the layout hook alone would leave a frozen style
    // showing the system's freshly resolved values until the next resize.
    // Application-level activation is observed too: the motivating
    // nonactivating HUD is never key or main, so its window emits none of the
    // window notifications when the app deactivates, yet that transition is
    // exactly where the resolver rewrites (the open P2 roadmap question).
    // Live mode benefits as well: re-adopting new endpoints no longer waits
    // for an unrelated layout.

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeContext(of: window)
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

    private func observeContext(of window: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self)
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(contextDidChange),
                name: name,
                object: NSApp
            )
        }
        guard let window else { return }
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(contextDidChange),
                name: name,
                object: window
            )
        }
    }

    @objc private func contextDidChange(_ note: Notification) {
        refreshNowAndAfterSystemRestamp()
    }

    /// Refreshes immediately, then once more from a follow-up main-actor job.
    ///
    /// This does **not** establish ordering against AppKit's own Recipe
    /// rebuild — whether the resolver writes before, between, or after these
    /// two refreshes is the open P2 question in the research roadmap, and no
    /// fixed enqueueing can make the authored state a deterministic final
    /// writer. The follow-up covers the common case where the system's write
    /// lands in the same turn as the notification; anything later is caught
    /// by the layout hook and the next context notification.
    private func refreshNowAndAfterSystemRestamp() {
        materialStrength.refresh()
        Task { @MainActor [weak self] in
            self?.materialStrength.refresh()
        }
    }
}
#endif
