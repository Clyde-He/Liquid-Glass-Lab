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
/// ## Scope
///
/// Measured on macOS 26.6 for the public Regular and Clear materials in a
/// panel. Not yet validated on macOS 27, on private semantic roles, or on
/// non-panel hosts. Two behaviors are discrete by design and cannot be smoothed:
/// the rim gate opens at any `value > 0`, and Clear in DarkAqua steps one bleed
/// blend flag at `0.5`.
///
/// Mid-transition accuracy degrades away from a ~200pt short side, bounded by
/// `min(5%, 4 / shortSide)`. Endpoints stay exact and the curve stays strictly
/// monotonic at every size.
@MainActor
public final class GlassMaterialStrength {
    private weak var glass: NSGlassEffectView?
    private var baseline: GlassMaterialBaseline?
    private var appliedValue: Double = 1

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
    public var isAvailable: Bool { baseline != nil }

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
    /// to the new context. A tree this controller already wrote to reports
    /// `value < 1` and is skipped, so it never captures its own output.
    public func refresh() {
        guard let glass else { return }
        if let candidate = Self.captureBaseline(from: glass), candidate.isPristine {
            baseline = candidate
        }
        apply()
    }

    /// Stops tracking and returns the controller to a neutral state.
    ///
    /// This does **not** restore the system material: an installed
    /// `glassBackground` override survives until the glass is rebuilt. Discard
    /// and recreate the `NSGlassEffectView` for a true restore.
    public func invalidate() {
        baseline = nil
    }

    // MARK: Internals

    static func captureBaseline(
        from glass: NSGlassEffectView
    ) -> GlassMaterialBaseline? {
        guard let backdrop = GlassMaterialAccess.backdropLayer(under: glass),
              GlassMaterialAccess.glassBackgroundFilter(on: backdrop) != nil
        else { return nil }
        let numeric = GlassMaterialAccess.readNumbers(from: glass)
        guard !numeric.isEmpty else { return nil }
        return GlassMaterialBaseline(
            numeric: numeric,
            colors: GlassMaterialAccess.readColors(
                from: glass,
                keys: GlassMaterialCurve.colorKeys
            ),
            rimOpacity: GlassMaterialAccess.rimLayers(under: glass)
                .map(GlassMaterialAccess.rimOpacity)
                .max(),
            shortSide: min(glass.bounds.width, glass.bounds.height)
        )
    }

    private func apply() {
        guard let glass,
              let baseline,
              let backdrop = GlassMaterialAccess.backdropLayer(under: glass)
        else { return }

        let isClear = Self.isClear(glass)
        let hasMain = Self.hasMainParticipation(glass)
        let isLight = glass.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .aqua

        let numbers = GlassMaterialCurve.numericValues(
            at: value,
            baseline: baseline,
            isClear: isClear,
            hasMainParticipation: hasMain,
            isLightAppearance: isLight
        )
        let colors = GlassMaterialCurve.colorValues(at: value, baseline: baseline)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, number) in numbers {
            GlassMaterialAccess.write(number, forKey: key, on: backdrop)
        }
        for (key, color) in colors {
            GlassMaterialAccess.write(color.cgColor, forKey: key, on: backdrop)
        }
        CATransaction.commit()

        if hasMain {
            let opacity = GlassMaterialCurve.rimOpacity(at: value, baseline: baseline)
            for layer in GlassMaterialAccess.rimLayers(under: glass) {
                GlassMaterialAccess.setRimOpacity(opacity, on: layer)
            }
        }

        if let tintColor,
           let sourceAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent,
           let tintLayer = GlassMaterialAccess.tintMatrixLayer(under: glass),
           var matrix = GlassMaterialAccess.tintMatrix(on: tintLayer) {
            matrix[18] = Float(
                GlassMaterialCurve.tintMatrixAlpha(
                    at: value,
                    sourceAlpha: Double(sourceAlpha)
                )
            )
            GlassMaterialAccess.setTintMatrix(matrix, on: tintLayer)
        }

        appliedValue = value
    }

    /// Reads the resolved Recipe index. Regular is 1 and Clear is 2; anything
    /// else is treated as Regular-like, which is the correct fallback because
    /// only Clear selects a different `inputClamp` shape.
    private static func isClear(_ glass: NSGlassEffectView) -> Bool {
        let resolved = GlassMaterialAccess.valueIfResponds(
            forKey: "_variant",
            on: glass
        ) as? NSNumber
        return resolved?.intValue == 2
    }

    /// A window that is genuinely key *or* genuinely main receives the active
    /// Recipe; neither gets the flat one. Spoofed getters do not count, so this
    /// reads the real AppKit state.
    private static func hasMainParticipation(_ glass: NSGlassEffectView) -> Bool {
        guard let window = glass.window else { return false }
        return window.isMainWindow || window.isKeyWindow
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
}
#endif
