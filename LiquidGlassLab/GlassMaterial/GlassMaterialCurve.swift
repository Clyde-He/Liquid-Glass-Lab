//
//  GlassMaterialCurve.swift
//  GlassMaterial
//
//  The measured Materialize curve, expressed as read endpoints times
//  dimensionless shapes.
//
//  Evidence behind every constant in this file lives in
//  Golden/macOS-26/materialize-environment-matrix.json (64 runs, 576 samples)
//  and materialize-geometry-sweep.json (12 runs, 108 samples), with the
//  analysis written up under "P1.1" in Documentation/GlassResearchRoadmap.md.
//  Measured on macOS 26.6 (25G5065a); macOS 27 is not yet validated.
//

#if os(macOS)
import AppKit

/// Normalized progress shapes. Each satisfies `shape(0) = 0` and
/// `shape(1) = 1`, so a channel resolves as
/// `start + (endpoint - start) * shape(g)`.
///
/// These are invariant across appearance, backdrop, Tint, and direction. They
/// are *not* invariant across size — see `GlassMaterialBaseline`.
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
    /// The resolved value at `g = 0`, measured as exactly 0 or 1 everywhere.
    public let start: Double
    public let shape: GlassMaterialShape
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

    /// A baseline is only meaningful on an unmutated tree. Applying any
    /// strength below 1 drives `inputFaceOpacity` down, so a settled value of 1
    /// is a reliable "system still owns this" sentinel.
    public var isPristine: Bool {
        (numeric["inputFaceOpacity"] ?? 0) >= 0.999
    }

    /// Materialize inflates the SDF element's short side by
    /// `min(0.2 · shortSide, 16)` points and retracts it linearly with `g`.
    /// Measured on `CASDFElementLayer` at shortSide 48, 200, and 400, matching
    /// within 0.05 pt at every sampled progress.
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
            values[key] = channel.start
                + (endpoint - channel.start)
                * channel.shape.value(at: g, geometryInflation: inflation)
        }
        // The one measured discrete edge: Clear in DarkAqua flips at the
        // midpoint, every other context holds its captured value.
        if let darkenBlend = baseline.numeric["inputBleedDarkenBlend"] {
            values["inputBleedDarkenBlend"] =
                (isClear && !isLightAppearance)
                    ? (g < 0.5 ? 0 : darkenBlend)
                    : darkenBlend
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
