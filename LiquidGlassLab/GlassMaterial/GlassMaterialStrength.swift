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
import OSLog

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
/// `refresh()` after any layout pass or Recipe rebuild; `AdjustableGlassEffectView`
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
final class GlassMaterialStrength {
    enum FrozenAppearanceSelection: Equatable, Sendable {
        case system
        case light
        case dark

        func resolves(systemIsLight: Bool) -> Bool {
            switch self {
            case .system:
                systemIsLight
            case .light:
                true
            case .dark:
                false
            }
        }
    }

    private weak var glass: NSGlassEffectView?
    private var baseline: GlassMaterialBaseline?
    private var appliedValue: Double = 1
    private var lastWrittenFilterIdentity: ObjectIdentifier?
    private var frozenMainParticipation = true
    private var frozenAppearanceSelection: FrozenAppearanceSelection = .system
    private var frozenReassertTask: Task<Void, Never>?
    private var preCommitObserver: CFRunLoopObserver?
    /// The shader vector the last frozen apply wrote, kept as the reassert
    /// sentinel's reference: margin and rim can both survive a system
    /// restamp untouched (a resize carries the rim over, and Clear samples a
    /// margin equal to the flat one), so only the written inputs themselves
    /// prove the tree still holds the frozen material. Colors are tracked
    /// alongside numbers because restamps revert different subsets per
    /// event: an appearance switch was measured carrying the numerics over
    /// while reverting the color inputs and grade matrices.
    private var lastFrozenNumbers: [String: Double] = [:]
    private var lastFrozenColors: [String: NSColor] = [:]
    private var lastFrozenTintMatrix: [Float]?

    /// The installed style atlas, if any. See `freeze(atlas:)`.
    public private(set) var frozenAtlas: GlassMaterialStyleAtlas?
    /// Identifies the base payload that was validated when this material was
    /// frozen, so a color-only change can skip revalidating it.
    private var frozenBaseGeneration: Int?
    private var isStagingTintColor = false

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
    /// atlas cell's resolved Main-context matrix supplies the hue coefficients
    /// too, because a non-main window resolves the hue-suppressed variant. The
    /// matrix may come from verified capture or supported-major synthesis.
    public var tintColor: NSColor? {
        didSet {
            guard !isStagingTintColor else { return }
            apply()
        }
    }

    /// Updates the controller's requested Tint without applying the complete
    /// frozen style. The product controller uses this immediately before the
    /// narrow Tint restamp; public `tintColor` writes still take the ordinary
    /// full apply path.
    fileprivate func stageTintColor(_ color: NSColor?) {
        isStagingTintColor = true
        tintColor = color
        isStagingTintColor = false
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

    /// A readback assertion for product calibration and diagnostics. `true`
    /// means the complete currently selected frozen sample — shader, grades,
    /// render bounds, rim, and any installed tint matrix — is present on the
    /// destination tree now. It does not trigger a write.
    public var frozenStyleIsCurrentlyApplied: Bool {
        guard let frozenAtlas, let glass,
              let sample = frozenAtlas.sample(
                for: currentCell(for: glass),
                at: min(glass.bounds.width, glass.bounds.height)
              )
        else { return false }
        return frozenStateHolds(sample, on: glass)
    }

    private func currentCell(
        for glass: NSGlassEffectView
    ) -> GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: frozenAppearanceSelection.resolves(
                systemIsLight: Self.isLightAppearance(glass)
            ),
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
    /// Returns false — installing nothing — unless the atlas was captured
    /// under the current schema and macOS major and covers the complete
    /// appearance × variant cell space for the frozen participation. A
    /// destination that cannot accept the snapshot fails complete readback;
    /// the product controller then falls back to runtime calibration.
    ///
    /// Coverage is validated here rather than discovered at a later context
    /// switch: appearance and variant change at runtime by design, and a
    /// cell miss after a switch would strand the previous cell's authored
    /// values with nothing tracking `value`. Rejecting a partial atlas keeps
    /// that state unreachable in the supported domain.
    ///
    /// Participation is the frozen axis: `mainParticipation` selects which
    /// captured cells serve, independent of the window's real state.
    /// Appearance and variant remain selectable without recapture. A forced
    /// Light/Dark selection addresses the corresponding atlas cell directly;
    /// System follows the view's effective appearance. Regular/Clear still
    /// follows the native style, and size follows by interpolating each cell's
    /// samples at the current short side.
    @discardableResult
    public func freeze(
        atlas: GlassMaterialStyleAtlas,
        mainParticipation: Bool = true,
        baseGeneration: Int? = nil,
        appearanceSelection: FrozenAppearanceSelection = .system
    ) -> Bool {
        guard let glass,
              let environment = atlas.environment,
              environment.isCompatible(
                with: .current(for: glass.window?.screen)
              )
        else { return false }
        // Main-On is a semantic claim about the resolved payload, not a label
        // the producer is trusted to attach. Refuse a frozen HUD atlas unless
        // every served sample proves itself against a paired Main-Off witness.
        // This makes an incorrectly captured Provider cache fail closed rather
        // than render the flat material under a Main-On key.
        if mainParticipation, !atlas.hasVerifiedMainOnPayload() {
            return false
        }
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
        frozenBaseGeneration = baseGeneration
        frozenMainParticipation = mainParticipation
        frozenAppearanceSelection = appearanceSelection
        baseline = nil
        lastWrittenFilterIdentity = nil
        installPreCommitObserver()
        apply()
        return true
    }

    /// Fast path for a color change on an already frozen material: swaps only
    /// the color-bound Tint overlay and restamps just the Tint branch.
    ///
    /// A tint color changes 20 coefficients; the base payload — shader, grades,
    /// geometry, rim — is bit-identical. Running the full `freeze` for every
    /// color therefore revalidated every sample and rewrote the whole style,
    /// which saturates the main thread while a color picker streams values.
    ///
    /// This refuses unless the caller's `baseGeneration` matches the base that
    /// was validated at freeze time, so any base change still goes through the
    /// full transaction.
    ///
    /// Returning false still leaves the requested color staged on `tintColor`,
    /// because the write is what proves the branch exists — a tint being
    /// inserted for the first time legitimately fails here. A caller that
    /// discards the result therefore holds a staged color against a base that
    /// was never restamped; every caller must answer false with the full
    /// install path.
    @discardableResult
    public func restampTintOverlay(
        _ atlas: GlassMaterialStyleAtlas,
        baseGeneration: Int,
        mainParticipation: Bool,
        tintColor newTintColor: NSColor?
    ) -> Bool {
        guard frozenAtlas != nil,
              frozenBaseGeneration == baseGeneration,
              frozenMainParticipation == mainParticipation,
              glass != nil
        else { return false }
        stageTintColor(newTintColor)
        guard applyFrozenTintOnly(
            from: atlas,
            tintColor: newTintColor
        ) else { return false }
        frozenAtlas = atlas
        return true
    }

    private func applyFrozenTintOnly(
        from atlas: GlassMaterialStyleAtlas,
        tintColor: NSColor?
    ) -> Bool {
        guard let tintColor else {
            lastFrozenTintMatrix = nil
            return true
        }
        guard let glass,
              let sourceAlpha = tintColor
                .usingColorSpace(.deviceRGB)?.alphaComponent
        else { return false }
        guard let tintLayer = GlassMaterialAccess.tintMatrixLayer(under: glass)
        else {
            // Normal exactly once per Tint session: the branch does not exist
            // until AppKit inserts it, and the full install path answers that.
            GlassMaterialTintLog.signposts.notice(
                "restamp refused: tint layer not materialized"
            )
            return false
        }
        guard var matrix = atlas.tintMatrix(
            for: currentCell(for: glass),
            matching: tintColor
        ), matrix.count == 20 else {
            GlassMaterialTintLog.signposts.notice(
                "restamp refused: no atlas matrix for the current cell"
            )
            return false
        }
        matrix[18] = Float(GlassMaterialCurve.tintMatrixAlpha(
            at: value,
            sourceAlpha: Double(sourceAlpha)
        ))
        GlassMaterialAccess.setColorMatrix(matrix, on: tintLayer)
        guard let written = GlassMaterialAccess.colorMatrix(on: tintLayer),
              written.count == matrix.count,
              zip(written, matrix).allSatisfy({ abs($0 - $1) < 1e-5 })
        else {
            GlassMaterialTintLog.signposts.notice(
                "restamp refused: readback does not match the write"
            )
            return false
        }
        lastFrozenTintMatrix = matrix
        return true
    }

    /// The frame-order weapon. The private subtree lays out *after* the
    /// hosting view, so a restamp during a resize lands later in the same
    /// layout pass than any write our own `layout()` hook can make — during
    /// a short-side drag the system wins every frame and the correction
    /// always paints one frame late. Core Animation commits the transaction
    /// from a `.beforeWaiting` run-loop observer at order 2,000,000; running
    /// the sentinel just below that order places the frozen rewrite after
    /// every layout of the turn and before the commit, making it the frame's
    /// final model state. The check is a few dozen KVC reads per turn and
    /// writes only on mismatch.
    private func installPreCommitObserver() {
        guard preCommitObserver == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            1_999_999
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.preCommitReassertIfNeeded()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        preCommitObserver = observer
    }

    private func removePreCommitObserver() {
        if let preCommitObserver {
            CFRunLoopObserverInvalidate(preCommitObserver)
        }
        preCommitObserver = nil
    }

    private func preCommitReassertIfNeeded() {
        guard let frozenAtlas, let glass else { return }
        guard let sample = frozenAtlas.sample(
            for: currentCell(for: glass),
            at: min(glass.bounds.width, glass.bounds.height)
        ) else { return }
        if frozenStateHolds(sample, on: glass) { return }
        apply()
    }

    /// Returns to live-read behavior. The frozen values persist on the tree
    /// until AppKit next rebuilds it, at which point the freshly resolved
    /// Recipe is adopted as the live baseline again; as everywhere else, an
    /// immediate true restore requires recreating the glass view.
    public func unfreeze() {
        removePreCommitObserver()
        frozenReassertTask?.cancel()
        frozenReassertTask = nil
        lastFrozenNumbers = [:]
        lastFrozenColors = [:]
        lastFrozenTintMatrix = nil
        frozenAtlas = nil
        frozenAppearanceSelection = .system
        refresh()
    }

    /// Stops tracking and returns the controller to a neutral state.
    ///
    /// This does **not** restore the system material: an installed
    /// `glassBackground` override survives until the glass is rebuilt. Discard
    /// and recreate the `NSGlassEffectView` for a true restore.
    public func invalidate() {
        removePreCommitObserver()
        frozenReassertTask?.cancel()
        frozenReassertTask = nil
        lastFrozenNumbers = [:]
        lastFrozenColors = [:]
        lastFrozenTintMatrix = nil
        baseline = nil
        frozenAtlas = nil
        frozenAppearanceSelection = .system
        lastWrittenFilterIdentity = nil
    }

    deinit {
        if let preCommitObserver {
            CFRunLoopObserverInvalidate(preCommitObserver)
        }
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
        let isLight = frozenAppearanceSelection.resolves(
            systemIsLight: Self.isLightAppearance(glass)
        )
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
        lastFrozenNumbers = numbers
        lastFrozenColors = colors

        // Grades and payloads are stamped pairwise in the shared traversal
        // order, against the topology validated above.
        for (layer, slot) in zip(matrixLayers, sample.matrices) {
            GlassMaterialAccess.setColorMatrix(slot.matrix, on: layer)
            GlassMaterialAccess.setMatrixScalarInputs(
                slot.inputs,
                nilKeys: slot.nilInputKeys,
                on: layer
            )
        }

        // The frozen rim owns both the payload and the gate, in both
        // directions: it opens a captured Main-On rim on a window that is not
        // main, and holds a captured flat rim closed on one that is.
        //
        // The payload is only replaced when it differs: replacing the SDF
        // effect makes AppKit re-derive `marginWidth` for the window's real
        // participation one cycle later, so an unconditional replace on every
        // G change would hand the margin back to the system after each scrub
        // step (and pay an effect copy per frame for nothing).
        for (layer, rim) in zip(rimLayers, sample.rims) {
            var rimColors: [String: NSColor] = [:]
            for (key, color) in rim.colors { rimColors[key] = color.nsColor }
            if !GlassMaterialAccess.rimPayloadMatches(
                values: rim.values,
                colors: rimColors,
                on: layer
            ) {
                GlassMaterialAccess.setRimPayload(
                    values: rim.values,
                    colors: rimColors,
                    on: layer
                )
            }
            GlassMaterialAccess.setRimOpacity(
                value > 0 ? rim.layerOpacity : 0,
                on: layer
            )
        }

        if let tintColor,
           let sourceAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent,
           let tintLayer = GlassMaterialAccess.tintMatrixLayer(under: glass) {
            // The resolved cell matrix carries the requested-context hue, and
            // only serves while it matches the current Tint color. Without a
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
                    lastFrozenTintMatrix = matrix
                }
            }
        }
        if tintColor == nil { lastFrozenTintMatrix = nil }

        // Render bounds do not animate with the transition; they are part of
        // the context and held constant across `value`.
        GlassMaterialAccess.setMarginWidth(sample.marginWidth, under: glass)
        GlassMaterialAccess.setOutputBounds(
            minimum: sample.outputMinimum,
            maximum: sample.outputMaximum,
            under: glass
        )

        finishApply(to: target)

        // AppKit re-derives `CABackdropLayer.marginWidth` for the window's
        // real participation one cycle *after* certain events — measured on a
        // never-main panel: replacing the rim's SDF effect provokes it, and a
        // resize provokes it on its own even when the rim payload carries
        // over unchanged. The re-derivation lands after every write above
        // regardless of ordering, and its delay varies with size, so any
        // single write can lose the race — after which a static panel has no
        // further event to heal on. Every frozen apply therefore arms a
        // trailing verify-and-repeat: each beat checks the margin against
        // the frozen sample and re-applies only on mismatch, for a bounded
        // number of beats. Re-applies inside the loop find the rim already
        // matching, so they replace nothing and provoke no new reaction —
        // the loop converges instead of oscillating, and when the margin
        // already reads back correctly the first beat exits immediately.
        scheduleFrozenReassert()
    }

    /// The beats open at frame cadence — the system paints its own
    /// resolution for the frame(s) between its restamp and our next check,
    /// so the visible Main-Off flash lasts exactly until the beat that
    /// catches it; at 16–33ms it is one or two frames instead of a visible
    /// blink. The cadence then decays and settles into a slow perpetual
    /// guard: compact sizes were measured churning past any fixed budget,
    /// and a static panel that exhausts a bounded loop mid-storm has no
    /// later event to heal on. A guard beat is a few dozen KVC reads and
    /// only re-applies on mismatch.
    private static let frozenReassertBeats: [Int] = [
        16, 16, 16, 16, 33, 33, 33, 33, 50, 50, 80, 80,
        120, 160, 250, 250, 500, 500,
    ]
    private static let frozenGuardBeatMilliseconds = 1000

    private func scheduleFrozenReassert() {
        frozenReassertTask?.cancel()
        frozenReassertTask = Task { @MainActor [weak self] in
            var beat = 0
            while true {
                let delay = beat < Self.frozenReassertBeats.count
                    ? Self.frozenReassertBeats[beat]
                    : Self.frozenGuardBeatMilliseconds
                beat += 1
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, self.frozenAtlas != nil,
                      let glass = self.glass else { return }
                if let sample = self.frozenAtlas?.sample(
                    for: self.currentCell(for: glass),
                    at: min(glass.bounds.width, glass.bounds.height)
                ), self.frozenStateHolds(sample, on: glass) {
                    continue
                }
                self.apply()
                beat = 0
            }
        }
    }

    /// The reassert sentinel, layered because every partial check has a
    /// measured blind spot: margin alone misses Clear (its sampled margin is
    /// 0, exactly the flat value), and margin + rim together still miss the
    /// drag-burst restamp that carries the rim over while reverting the
    /// shader inputs. The written numeric vector is the authoritative check
    /// — the system cannot reproduce it at any `value` on a flat window —
    /// with margin and rim kept as cheaper leading checks.
    /// Every leg of `frozenStateHolds` used to fail silently, so a transient
    /// `frozenInstallFailed` on an untested OS major named nothing. Name the
    /// broken invariant instead; the healthy path still logs zero lines.
    ///
    /// A persistent break is re-checked by the pre-commit observer and the
    /// 16 ms reassert cadence, so an identical reason is logged once and then
    /// counted; recovery logs the count. A flicker therefore reads as
    /// break/recovered pairs at its visible cadence, and a wedged state as
    /// one line — not a flooded log on the exact main-thread path being
    /// diagnosed.
    private var lastFrozenBreakReason: String?
    private var suppressedFrozenBreakCount = 0

    private func frozenStateBroke(_ reason: String) -> Bool {
        guard reason != lastFrozenBreakReason else {
            suppressedFrozenBreakCount += 1
            return false
        }
        lastFrozenBreakReason = reason
        suppressedFrozenBreakCount = 0
        GlassMaterialTintLog.signposts.notice(
            "frozen state broke: \(reason, privacy: .public)"
        )
        return false
    }

    private func noteFrozenStateHolds() {
        guard let reason = lastFrozenBreakReason else { return }
        GlassMaterialTintLog.signposts.notice(
            "frozen state recovered from: \(reason, privacy: .public) (\(self.suppressedFrozenBreakCount, privacy: .public) repeats suppressed)"
        )
        lastFrozenBreakReason = nil
        suppressedFrozenBreakCount = 0
    }

    private static func worstCoefficient(
        _ current: [Float],
        _ written: [Float]
    ) -> (index: Int, current: Float, written: Float) {
        var worst = (index: 0, current: current[0], written: written[0])
        for (index, pair) in zip(current, written).enumerated()
        where abs(pair.0 - pair.1) > abs(worst.current - worst.written) {
            worst = (index, pair.0, pair.1)
        }
        return worst
    }

    private func frozenStateHolds(
        _ sample: GlassMaterialStyleSample,
        on glass: NSGlassEffectView
    ) -> Bool {
        guard let margin = GlassMaterialAccess.marginWidth(under: glass) else {
            return frozenStateBroke("margin unreadable")
        }
        guard abs(margin - sample.marginWidth) < 0.25 else {
            return frozenStateBroke(
                "margin drifted: \(margin) vs \(sample.marginWidth)"
            )
        }
        guard let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) else {
            return frozenStateBroke("no glassBackground target")
        }
        let currentInputs = GlassMaterialAccess.readTypedInputs(from: target)
        for (key, written) in lastFrozenNumbers {
            let current = currentInputs.numeric[key]
            guard let current, abs(current - written) < 1e-3 else {
                let read = current.map { "\($0)" } ?? "nil"
                return frozenStateBroke(
                    "shader numeric \(key): \(read) vs \(written)"
                )
            }
        }
        for (key, written) in lastFrozenColors {
            guard let current = currentInputs.colors[key],
                  GlassMaterialAccess.colorsMatch(current, written)
            else {
                return frozenStateBroke("shader color \(key) drifted")
            }
        }
        let matrixLayersNow = GlassMaterialAccess.untintedMatrixLayers(
            under: glass
        )
        guard matrixLayersNow.count == sample.matrices.count else {
            return frozenStateBroke(
                "untinted matrix layers: \(matrixLayersNow.count)"
                    + " vs \(sample.matrices.count)"
            )
        }
        for (slotIndex, (layer, slot)) in zip(
            matrixLayersNow,
            sample.matrices
        ).enumerated() {
            guard let current = GlassMaterialAccess.colorMatrix(on: layer),
                  current.count == slot.matrix.count
            else {
                return frozenStateBroke(
                    "grade matrix \(slotIndex) unreadable"
                )
            }
            guard zip(current, slot.matrix).allSatisfy({
                abs($0 - $1) < 1e-3
            }) else {
                let worst = Self.worstCoefficient(current, slot.matrix)
                return frozenStateBroke(
                    "grade matrix \(slotIndex) coefficient \(worst.index):"
                        + " \(worst.current) vs \(worst.written)"
                )
            }
        }
        if tintColor != nil, let written = lastFrozenTintMatrix {
            guard let tintLayer = GlassMaterialAccess.tintMatrixLayer(
                under: glass
            ) else {
                return frozenStateBroke("tint layer missing")
            }
            guard let current = GlassMaterialAccess.colorMatrix(on: tintLayer),
                  current.count == written.count
            else {
                return frozenStateBroke("tint matrix unreadable")
            }
            guard zip(current, written).allSatisfy({ abs($0 - $1) < 1e-3 })
            else {
                let worst = Self.worstCoefficient(current, written)
                return frozenStateBroke(
                    "tint matrix coefficient \(worst.index):"
                        + " \(worst.current) on layer vs \(worst.written) written"
                )
            }
        }
        let rimLayers = GlassMaterialAccess.rimLayers(under: glass)
        guard rimLayers.count == sample.rims.count else {
            return frozenStateBroke(
                "rim layers: \(rimLayers.count) vs \(sample.rims.count)"
            )
        }
        for (rimIndex, (layer, rim)) in zip(
            rimLayers,
            sample.rims
        ).enumerated() {
            var rimColors: [String: NSColor] = [:]
            for (key, color) in rim.colors { rimColors[key] = color.nsColor }
            if !GlassMaterialAccess.rimPayloadMatches(
                values: rim.values,
                colors: rimColors,
                on: layer
            ) {
                return frozenStateBroke("rim payload \(rimIndex) drifted")
            }
        }
        noteFrozenStateHolds()
        return true
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

/// An `NSGlassEffectView` whose visual effect can be adjusted without exposing
/// the calibration and frozen-material machinery that maintains it.
@MainActor
public final class AdjustableGlassEffectView: NSGlassEffectView {
    public enum EffectState: Equatable, Sendable {
        case active
        case inactive
    }

    public enum UnavailabilityReason: Equatable, Sendable {
        case calibrationFailed(String)
        case materialInstallationFailed
        case tintResolutionFailed
    }

    public enum Status: Equatable, Sendable {
        case idle
        case waitingForReferenceWindow
        case preparing
        case ready
        /// The material is currently unavailable, but this is not necessarily
        /// terminal. Readiness retries and reference-window recovery can move
        /// the view back to `preparing` or `ready` without product intervention.
        case unavailable(UnavailabilityReason)
    }

    /// The ordinary app window whose verified material is held on this view.
    ///
    /// A nonactivating HUD cannot become main or key itself, so readiness is
    /// derived from this reference window.
    public private(set) weak var referenceWindow: NSWindow?

    /// Product-facing strength in the closed range `0...1`.
    public var effectAmount: CGFloat {
        get {
            if let controller = effectController {
                return CGFloat(controller.configuration.visibility)
            }
            return CGFloat(materialStrength.value)
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            guard let controller = effectController else {
                materialStrength.value = Double(clamped)
                return
            }
            controller.configuration.visibility = Double(clamped)
        }
    }

    /// Selects the verified active or inactive material independently of the
    /// HUD window's own main/key participation.
    public var effectState: EffectState = .active {
        didSet {
            guard effectState != oldValue,
                  let controller = effectController
            else { return }
            controller.configuration.emphasis = effectState == .active
                ? .normal
                : .muted
        }
    }

    public private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    public var onStatusChange: ((Status) -> Void)?

    /// Creates an adjustable glass view tied to the app window that provides
    /// its verified material context.
    public init(
        referenceWindow: NSWindow,
        frame frameRect: NSRect = .zero
    ) {
        self.referenceWindow = referenceWindow
        super.init(frame: frameRect)
        rebuildEffectController()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable, message: "Use init(referenceWindow:frame:)")
    required init?(coder: NSCoder) {
        fatalError("Use init(referenceWindow:frame:)")
    }

    isolated deinit {
        effectController?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Rechecks cached or runtime readiness after the reference window or
    /// display environment changes.
    public func prepareIfNeeded() {
        if effectController == nil, referenceWindow != nil {
            rebuildEffectController()
        }
        effectController?.ensureReady()
    }

    private(set) lazy var materialStrength = GlassMaterialStrength(glass: self)

    private var isRefreshing = false
    private var isApplyingControlledConfiguration = false
    private var requestedTintColor: NSColor?
    private var effectController: GlassEffectController?

    /// Internal product-controller hook. `NSView` has no did-move-to-window
    /// notification a separate owner can reliably observe.
    var materialWindowDidChange: (() -> Void)?

    override public var style: NSGlassEffectView.Style {
        didSet {
            guard style != oldValue else { return }
            materialStrength.refresh()
            guard !isApplyingControlledConfiguration,
                  let controller = effectController
            else { return }
            controller.configuration.variant = style == .clear
                ? .clear
                : .regular
        }
    }

    override public var appearance: NSAppearance? {
        didSet {
            guard appearance !== oldValue,
                  !isApplyingControlledConfiguration,
                  let controller = effectController
            else { return }
            controller.configuration.appearance =
                Self.controlledAppearance(for: appearance)
        }
    }

    override public var tintColor: NSColor? {
        get { requestedTintColor }
        set {
            requestedTintColor = newValue
            guard let controller = effectController else {
                super.tintColor = newValue
                materialStrength.tintColor = newValue
                return
            }
            controller.configuration.tint = newValue
        }
    }

    /// Applies the controlled style and continuous strength without feeding
    /// the resulting writes back into the owning controller. Appearance stays
    /// owned by the native view so semantic variants such as Vibrant are not
    /// replaced by a plain Light/Dark reconstruction.
    func applyControlledConfiguration(
        style: NSGlassEffectView.Style,
        amount: Double
    ) {
        isApplyingControlledConfiguration = true
        self.style = style
        materialStrength.value = amount
        isApplyingControlledConfiguration = false
    }

    /// Separates Tint-branch materialization from the frozen writer's
    /// controlled color.
    ///
    /// The native color is pinned by RGB: assigning `tintColor` makes the
    /// system re-resolve the Tint pass and rewrite its matrix at commit, so
    /// an opacity drag — which streams colors differing only in alpha — was
    /// feeding the system's own tint writer a reason to race the frozen
    /// restamp on every tick. The native color's only jobs are materializing
    /// the branch and being the fallback visual; the displayed alpha lives in
    /// coefficient 18 of the frozen writer's matrix, so alpha-only changes
    /// carry no information the native assignment needs to deliver.
    func stageMaterialTint(
        nativeColor: NSColor?,
        controlledColor: NSColor?
    ) {
        if !Self.nativeTintAssignmentIsChurn(
            from: super.tintColor,
            to: nativeColor
        ) {
            super.tintColor = nativeColor
        }
        materialStrength.stageTintColor(controlledColor)
    }

    private func rebuildEffectController() {
        effectController?.invalidate()
        effectController = nil

        guard let referenceWindow else {
            status = .idle
            return
        }

        let controller = GlassEffectController(
            hostWindow: referenceWindow,
            configuration: .init(
                variant: style == .clear ? .clear : .regular,
                visibility: Double(effectAmount),
                appearance: Self.controlledAppearance(for: appearance),
                tint: requestedTintColor,
                emphasis: effectState == .active ? .normal : .muted
            )
        )
        status = .preparing
        controller.onStatusChanged = { [weak self, weak controller] value in
            guard let self, self.effectController === controller else { return }
            self.status = Self.publicStatus(for: value)
        }
        effectController = controller
        controller.attach(to: self)
        status = Self.publicStatus(for: controller.status)
    }

    private static func controlledAppearance(
        for appearance: NSAppearance?
    ) -> GlassEffectController.Appearance {
        guard let appearance else { return .system }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark
            : .light
    }

    private static func publicStatus(
        for status: GlassEffectController.Status
    ) -> Status {
        switch status {
        case .idle:
            .preparing
        case .waitingForMainWindow:
            .waitingForReferenceWindow
        case .calibrating, .lockingTint:
            .preparing
        case .ready:
            .ready
        case let .fallback(reason):
            switch reason {
            case let .calibrationFailed(message):
                .unavailable(.calibrationFailed(message))
            case .frozenInstallFailed:
                .unavailable(.materialInstallationFailed)
            case .tintNotYetVerified:
                .unavailable(.tintResolutionFailed)
            }
        }
    }

    /// True only for the assignments the pin exists to absorb: an opacity drag
    /// streaming the same RGB between *nonzero* alphas. Alpha `0` is not part
    /// of that stream — it is the placeholder that materializes the branch
    /// before a color is verified — so transitions into or out of it must
    /// reach the setter, or the placeholder would pin the native fallback
    /// transparent for as long as the RGB survives.
    private static func nativeTintAssignmentIsChurn(
        from current: NSColor?,
        to requested: NSColor?
    ) -> Bool {
        switch (current, requested) {
        case (nil, nil):
            return true
        case let (current?, requested?):
            guard let a = GlassMaterialColorValue(current),
                  let b = GlassMaterialColorValue(requested)
            else { return false }
            guard abs(a.red - b.red) <= 0.0005,
                  abs(a.green - b.green) <= 0.0005,
                  abs(a.blue - b.blue) <= 0.0005
            else { return false }
            if abs(a.alpha - b.alpha) <= 0.0005 { return true }
            return a.alpha > 0.0005 && b.alpha > 0.0005
        default:
            return false
        }
    }

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
        materialWindowDidChange?()
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
