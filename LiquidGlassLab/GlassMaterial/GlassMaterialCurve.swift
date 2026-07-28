//
//  GlassMaterialCurve.swift
//  GlassMaterial
//
//  The measured Materialize curve, expressed as read endpoints times
//  dimensionless shapes.
//
//  Evidence behind every constant in this file lives in the direct canonical
//  Golden/macOS-26/unified and Golden/macOS-27/unified archives (104 runs and
//  936 samples each), with the analysis written up under "P1.1" in
//  Documentation/GlassResearchRoadmap.md. Measured on macOS 26.6 (25G5065a) and
//  macOS 27.0 (26A5388g).
//
//  Both systems are served by one table with no version branch. The shapes are
//  identical; macOS 27 only adds channels and retunes endpoints, and endpoints
//  are read from the live tree rather than authored here. Two measured
//  exceptions are documented and deliberately not reproduced, both confined to
//  mid-transition values at a small short side: see `GlassMaterialStrength`.
//

#if os(macOS)
import AppKit

/// Normalized progress shapes. Each satisfies `shape(0) = 0` and
/// `shape(1) = 1`, so a channel resolves as
/// `start + (endpoint - start) * shape(g)`.
///
/// These are invariant across appearance, backdrop, Tint, and direction at the
/// 200pt reference geometry, and unchanged between macOS 26 and 27. They are
/// *not* invariant across size — see `GlassMaterialBaseline`. On macOS 26 the
/// 48pt face grade is additionally a measured dual-endpoint exception; macOS 27
/// resolves one endpoint at every captured size. Discrete gates are handled
/// separately from this continuous shape vocabulary.
public enum GlassMaterialShape: Sendable {
    /// `g`. The majority of channels.
    case linear
    /// `0.2g + 0.8g²`. Blur opacity 1/2 without Main participation.
    case quadraticFlat
    /// `0.4g + 0.6g²`. Blur opacity 1/2 under Main, and 3/4 always.
    case quadratic
    /// `g + c·g(1 - g)`, `c` being the geometry inflation ratio. The
    /// shadow-height family tracks the inflating SDF element.
    case height
    /// `(0.34g + 0.036g²) / 0.376`. Clear's `inputClamp`.
    case clamp

    public func value(at progress: Double, geometryInflation: Double) -> Double {
        let g = progress
        switch self {
        case .linear: return g
        case .quadraticFlat: return 0.2 * g + 0.8 * g * g
        case .quadratic: return 0.4 * g + 0.6 * g * g
        case .height: return g + geometryInflation * g * (1 - g)
        case .clamp: return (0.34 * g + 0.036 * g * g) / 0.376
        }
    }
}

public struct GlassMaterialChannel: Sendable {
    /// The resolved value at `g = 0`. Exactly 0 or 1 on every macOS 26 channel;
    /// macOS 27's key fill highlight added measured starts that are neither.
    public let start: Double
    public let shape: GlassMaterialShape
    /// Adds `(1 - endpoint) · g(1 - g)` on top of the shape: a mid-transition
    /// overshoot whose amplitude is exactly the amount the resolved endpoint
    /// falls short of full opacity. Only meaningful for a channel that
    /// saturates at 1, and only `inputBlurOpacity0` measures this way.
    public let saturationDeficitHump: Bool

    public init(
        start: Double,
        shape: GlassMaterialShape,
        saturationDeficitHump: Bool = false
    ) {
        self.start = start
        self.shape = shape
        self.saturationDeficitHump = saturationDeficitHump
    }
}

/// The system-resolved endpoints of one live Recipe.
///
/// Reading endpoints instead of authoring them is what lets a single scalar
/// follow size, appearance, Variant, participation, and subvariant with no
/// per-axis table: `g = 1` reproduces the captured Recipe by construction.
public struct GlassMaterialBaseline: Equatable, Sendable {
    public let numeric: [String: Double]
    public let colors: [String: NSColor]
    public let rimOpacity: Double?
    /// `min(width, height)` of the glass this was captured from.
    public let shortSide: Double

    /// A baseline is only meaningful on an unmutated tree. Values near 1 are
    /// candidates; the controller additionally checks filter identity and its
    /// last authored face opacity so a user value such as 0.9995 is not
    /// mistaken for a new system endpoint.
    public var isPristine: Bool {
        (numeric["inputFaceOpacity"] ?? 0) >= 0.999
    }

    /// Materialize inflates the SDF element's short side by
    /// `min(0.2 · shortSide, 16)` points and retracts it with the outer
    /// transaction. The View Envelope clock is distinct from face-opacity `g`.
    /// Measured on `CASDFElementLayer` at shortSide 48, 200, and 400.
    ///
    /// As a fraction of the resting side that is `min(0.2, 16 / shortSide)`,
    /// the quadratic coefficient every geometry-tracking channel inherits.
    public var geometryInflation: Double {
        shortSide > 0 ? min(0.2, 16 / shortSide) : 0
    }
}

public enum GlassMaterialCurve {
    /// Fill colors interpolate alpha and keep the system-resolved RGB, so the
    /// Aqua-white / DarkAqua-black split needs no appearance branch.
    public static let colorKeys = [
        "inputFaceColorMatrixFillColor",
        "inputShadowColorMatrixFillColor",
    ]

    /// Channels whose `(start, shape)` never depends on context.
    private static let sharedChannels: [String: GlassMaterialChannel] = {
        var table: [String: GlassMaterialChannel] = [:]
        for key in [
            "inputBleedColorMatrixBlack", "inputBleedDistance0",
            "inputBleedOpacity", "inputBlurDistance1", "inputBlurOpacity0",
            "inputBlurRadius", "inputFaceColorMatrixBlack", "inputFaceOpacity",
            "inputInnerRefractionAmount", "inputInnerRefractionHeight",
            "inputRefractionDistance0", "inputRefractionDistance1",
            "inputRefractionOpacity", "inputSDRGradientDistance0",
            "inputSDRGradientDistance1", "inputSDRShadowOpacity",
            "inputShadowAmount", "inputShadowBlurRadius", "inputShadowOpacity",
            "inputShadowRadius", "inputShadowVibrancyContribution",
        ] {
            table[key] = GlassMaterialChannel(start: 0, shape: .linear)
        }
        for key in [
            "inputBleedColorMatrixSaturation", "inputBleedColorMatrixWhite",
            "inputFaceColorMatrixSaturation", "inputFaceColorMatrixWhite",
            "inputMaxHeadroom", "inputSDRHoldingToneWhite",
            "inputShadowColorMatrixSaturation", "inputShadowColorMatrixWhite",
        ] {
            table[key] = GlassMaterialChannel(start: 1, shape: .linear)
        }
        for key in [
            "inputBleedAmount", "inputBleedBlurRadius", "inputBleedHeight",
            "inputBlurDistance0", "inputBlurDistance4",
            "inputOuterRefractionAmount", "inputOuterRefractionHeight",
            "inputShadowHeight",
        ] {
            table[key] = GlassMaterialChannel(start: 0, shape: .height)
        }
        table["inputBlurOpacity3"] = GlassMaterialChannel(start: 0, shape: .quadratic)
        table["inputBlurOpacity4"] = GlassMaterialChannel(start: 0, shape: .quadratic)

        // macOS 27 rebuilt Regular's shadow: `inputShadowHeight` resolves to 0
        // and a size-invariant ring shadow takes over, arriving alongside a blur
        // fill and a key fill highlight — 22 new inputs, 17 of which animate.
        //
        // Every one of them rides the same clock as `inputFaceOpacity`.
        // Normalized against its own start, each traces the face profile to
        // within 1e-3 across all 52 insertion runs, so all 17 are linear and
        // only the start values are new. A shape that merely fits better on
        // average — `clamp` beat linear by 40% on mean error here — was the
        // sampling lag every channel shares, not a different curve.
        //
        // These keys are absent on macOS 26, where `numericValues` skips them
        // for want of an endpoint. That is why one table serves both systems
        // with no version branch.
        for key in [
            "inputBlurFillBlurRadius", "inputBlurFillDarkenOpacity",
            "inputBlurFillLightenOpacity", "inputBlurFillNormalOpacity",
            "inputKeyFillHighlightEffectOffset", "inputKeyFillHighlightHeight",
            "inputRingShadowOffset", "inputRingShadowOpacity",
            "inputRingShadowStrokeWidth",
        ] {
            table[key] = GlassMaterialChannel(start: 0, shape: .linear)
        }
        for key in [
            "inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR",
            "inputRingShadowBlurRadius", "inputRingShadowMask",
        ] {
            table[key] = GlassMaterialChannel(start: 1, shape: .linear)
        }
        // The starts macOS 27 introduced that are neither 0 nor 1. Measured
        // constants, invariant across size, participation, appearance, and
        // Variant; a wrong start bows the normalized profile away from the face
        // curve, and none of these do.
        for (key, start) in [
            ("inputKeyFillHighlightAmount", 0.4),
            ("inputKeyFillHighlightColorBias", -0.25),
            ("inputKeyFillHighlightSpread", 1.309),
            ("inputKeyFillHighlightSpreadSDR", 1.309),
        ] {
            table[key] = GlassMaterialChannel(start: start, shape: .linear)
        }
        return table
    }()

    /// The two channels whose shape, not merely endpoint, depends on context.
    public static func channels(
        isClear: Bool,
        hasMainParticipation: Bool
    ) -> [String: GlassMaterialChannel] {
        var table = sharedChannels
        let blurShape: GlassMaterialShape =
            hasMainParticipation ? .quadratic : .quadraticFlat
        table["inputBlurOpacity1"] = GlassMaterialChannel(start: 0, shape: blurShape)
        table["inputBlurOpacity2"] = GlassMaterialChannel(start: 0, shape: blurShape)
        table["inputClamp"] = GlassMaterialChannel(
            start: 1,
            shape: isClear ? .clamp : .linear
        )
        // macOS 27 gates the backdrop blur by size: Regular resolves
        // `inputBlurOpacity0` to zero below a 64pt short side, then ramps to 0.8
        // over 64...160pt. Mid-transition the channel overshoots that gated
        // endpoint by exactly the amount it falls short of full opacity:
        //
        //     value(g) = endpoint · g + (1 - endpoint) · g(1 - g)
        //
        // Measured across all 448 samples on both systems: worst absolute error
        // 0.00008, against 0.24980 for a plain linear ramp. The coefficient on
        // the deficit is exactly 1 — nothing is fitted here.
        //
        // The term is self-cancelling where it should be. Clear resolves an
        // endpoint of 1 on both systems, and macOS 26 resolves 1 for Regular at
        // every size, so `(1 - endpoint)` is zero and this reduces to the linear
        // ramp that was measured there. No variant or version branch is needed.
        table["inputBlurOpacity0"] = GlassMaterialChannel(
            start: 0,
            shape: .linear,
            saturationDeficitHump: true
        )
        return table
    }

    /// Resolves every numeric channel for one progress value.
    public static func numericValues(
        at progress: Double,
        baseline: GlassMaterialBaseline,
        isClear: Bool,
        hasMainParticipation: Bool,
        isLightAppearance: Bool
    ) -> [String: Double] {
        let g = min(max(progress, 0), 1)
        let inflation = baseline.geometryInflation
        var values: [String: Double] = [:]
        for (key, channel) in channels(
            isClear: isClear,
            hasMainParticipation: hasMainParticipation
        ) {
            guard let endpoint = baseline.numeric[key] else { continue }
            var value = channel.start
                + (endpoint - channel.start)
                * channel.shape.value(at: g, geometryInflation: inflation)
            if channel.saturationDeficitHump {
                value += (1 - endpoint) * g * (1 - g)
            }
            values[key] = value
        }
        // The one measured discrete edge: Clear in DarkAqua flips at the
        // midpoint, every other context holds its captured value.
        if let darkenBlend = baseline.numeric["inputBleedDarkenBlend"] {
            values["inputBleedDarkenBlend"] =
                (isClear && !isLightAppearance)
                    ? (g < 0.5 ? 0 : darkenBlend)
                    : darkenBlend
        }
        // The holding-tone flag is a gate, not a fractional strength. It is
        // zero only at the fully dematerialized endpoint, then immediately
        // adopts the system-resolved Recipe value.
        if let holdingTone = baseline.numeric["inputSDRHoldingToneEnabled"] {
            values["inputSDRHoldingToneEnabled"] = g > 0 ? holdingTone : 0
        }
        return values
    }

    /// Fill colors keep their captured RGB and scale alpha linearly.
    public static func colorValues(
        at progress: Double,
        baseline: GlassMaterialBaseline
    ) -> [String: NSColor] {
        let g = min(max(progress, 0), 1)
        var values: [String: NSColor] = [:]
        for key in colorKeys {
            guard let endpoint = baseline.colors[key] else { continue }
            let base = endpoint.usingColorSpace(.deviceRGB) ?? endpoint
            values[key] = base.withAlphaComponent(
                base.alphaComponent * CGFloat(g)
            )
        }
        return values
    }

    /// The rim owner gate is discrete, not continuous: it opens to its captured
    /// opacity on the first active frame and stays there.
    public static func rimOpacity(
        at progress: Double,
        baseline: GlassMaterialBaseline
    ) -> Double {
        progress > 0 ? (baseline.rimOpacity ?? 1) : 0
    }

    /// Tint alpha follows `sourceAlpha × g²`, not a linear ramp. Across 256
    /// tinted samples the quadratic fit holds within 9.5e-5 while a linear
    /// model misses by up to 0.25.
    public static func tintMatrixAlpha(
        at progress: Double,
        sourceAlpha: Double
    ) -> Double {
        let g = min(max(progress, 0), 1)
        return sourceAlpha * g * g
    }
}
#endif
