//
//  GlassMaterialTintMatrixSynthesizer.swift
//  AdjustableGlass
//
//  Closed-form macOS 26/27 synthesis for NSGlassEffectView's Tint-owned
//  vibrantColorMatrix. The unit-domain model is derived from the accepted
//  full-grid, focused-boundary, and hue-fraction sweeps. macOS 26 and 27 also
//  certify the complete Display P3 gamut through independent boundary /
//  holdout sweeps under their respective Golden directories.
//

#if os(macOS)
import AppKit

enum GlassMaterialTintMatrixSynthesizer {
    enum Family: String, Equatable, Sendable {
        case standard
        case pastel
        case neutralSuppression
        case achromatic
        /// macOS 26's achromatic Main-On grade: a saturation-complement
        /// `I − s(x)·(1⊗w)` with a linear bias ramp, shared by all four
        /// Main-On cells. macOS 27 replaced it with the channel-affine form.
        case achromaticSaturationBoost
    }

    /// Majors whose complete selection table and endpoint transforms are
    /// certified by an accepted Golden sweep. The chromatic transforms are
    /// bit-identical across both majors; the majors differ only in context
    /// selection and the achromatic family.
    static let supportedOSMajorVersions: Set<Int> = [26, 27]

    // The accepted boundary probes resolve chroma 0.0003 as achromatic and
    // 0.0004 as chromatic. Keep the decision between those observations
    // instead of relying on a bright-endpoint residual, which mislabels
    // near-white pastel rows as standard.
    private static let achromaticChromaThreshold = 0.00035
    private static let rec709Luma = [0.2126, 0.7152, 0.0722]
    /// `NSColor`'s P3 → extended-sRGB conversion is Float-backed on the
    /// certified systems. A round trip can therefore move a boundary
    /// component by several ulps. This tolerance admits that representation
    /// noise, not nearby colors outside Display P3.
    private static let displayP3RoundTripTolerance = 0.000002

    static func matrix(
        for color: NSColor,
        cell: GlassMaterialStyleAtlas.Cell,
        osMajorVersion: Int
    ) -> [Float]? {
        guard let source = GlassMaterialColorValue(color) else { return nil }
        return matrix(
            for: source,
            cell: cell,
            osMajorVersion: osMajorVersion
        )
    }

    static func matrix(
        for source: GlassMaterialColorValue,
        cell: GlassMaterialStyleAtlas.Cell,
        osMajorVersion: Int
    ) -> [Float]? {
        guard supportedOSMajorVersions.contains(osMajorVersion) else {
            return nil
        }
        let rgb = [source.red, source.green, source.blue]
        guard rgb.allSatisfy(\.isFinite), source.alpha.isFinite,
        source.alpha >= 0, source.alpha <= 1 else {
            return nil
        }
        guard isWithinCertifiedSynthesisDomain(
            source,
            osMajorVersion: osMajorVersion
        ) else { return nil }

        switch family(
            for: rgb,
            cell: cell,
            osMajorVersion: osMajorVersion
        ) {
        case .standard:
            return lumaEndpointMatrix(
                bright: rgb,
                dark: standardDarkEndpoint(for: rgb),
                alpha: source.alpha
            )
        case .pastel:
            return lumaEndpointMatrix(
                bright: pastelEndpoint(for: rgb, isBright: true),
                dark: pastelEndpoint(for: rgb, isBright: false),
                alpha: source.alpha
            )
        case .neutralSuppression:
            return neutralSuppressionMatrix(
                isLightAppearance: cell.isLightAppearance,
                alpha: source.alpha
            )
        case .achromatic:
            return achromaticMatrix(
                value: rgb.reduce(0, +) / 3,
                alpha: source.alpha
            )
        case .achromaticSaturationBoost:
            return achromaticSaturationBoostMatrix(
                value: rgb.reduce(0, +) / 3,
                alpha: source.alpha
            )
        }
    }

    /// The original closed form is certified over the extended-sRGB unit
    /// cube on macOS 26 and 27. The wider per-major studies certify exactly
    /// the colors representable by Display P3 — not an axis-aligned
    /// extended-RGB box. Round-tripping through bounded Display P3 keeps
    /// arbitrary HDR or other-gamut values fail-closed even when one component
    /// happens to sit inside the observed P3 extrema.
    static func isWithinCertifiedSynthesisDomain(
        _ source: GlassMaterialColorValue,
        osMajorVersion: Int
    ) -> Bool {
        guard supportedOSMajorVersions.contains(osMajorVersion) else {
            return false
        }
        let sourceRGB = [source.red, source.green, source.blue]
        guard sourceRGB.allSatisfy(\.isFinite) else { return false }
        if sourceRGB.allSatisfy({ $0 >= 0 && $0 <= 1 }) {
            return true
        }

        // Both supported majors have complete Display P3 boundary/holdout
        // certification. Exact cache/live resolution remains the fallback for
        // colors outside that gamut.
        guard let displayP3 = source.nsColor.usingColorSpace(.displayP3),
              let roundTrip = displayP3.usingColorSpace(.extendedSRGB)
        else { return false }

        let p3 = [
            Double(displayP3.redComponent),
            Double(displayP3.greenComponent),
            Double(displayP3.blueComponent),
        ]
        let reconstructed = [
            Double(roundTrip.redComponent),
            Double(roundTrip.greenComponent),
            Double(roundTrip.blueComponent),
        ]
        let tolerance = displayP3RoundTripTolerance
        guard p3.allSatisfy({
            $0.isFinite && $0 >= -tolerance && $0 <= 1 + tolerance
        }) else { return false }
        return zip(sourceRGB, reconstructed).allSatisfy {
            abs($0 - $1) <= tolerance
        }
    }

    static func family(
        for sourceRGB: [Double],
        cell: GlassMaterialStyleAtlas.Cell,
        osMajorVersion: Int
    ) -> Family {
        precondition(sourceRGB.count == 3)
        precondition(supportedOSMajorVersions.contains(osMajorVersion))

        // Regular Main-Off suppresses on both certified majors; macOS 26
        // additionally suppresses Clear Main-Off (the accepted 26 sweep shows
        // all four Main-Off cells resolving the same neutral coefficients).
        let mainOffSuppresses = osMajorVersion == 26
            ? !cell.hasMainParticipation
            : !cell.isClear && !cell.hasMainParticipation
        if mainOffSuppresses {
            return .neutralSuppression
        }

        let chroma = (sourceRGB.max() ?? 0) - (sourceRGB.min() ?? 0)
        if chroma <= achromaticChromaThreshold {
            return osMajorVersion == 26
                ? .achromaticSaturationBoost
                : .achromatic
        }

        // Pastel contexts: Dark Regular Main-On on macOS 27; both Dark
        // Main-On variants on macOS 26 (Dark Clear switched to standard in 27).
        let isPastel = osMajorVersion == 26
            ? !cell.isLightAppearance && cell.hasMainParticipation
            : !cell.isLightAppearance
                && !cell.isClear
                && cell.hasMainParticipation
        if isPastel {
            return .pastel
        }
        return .standard
    }

    private static func standardDarkEndpoint(
        for source: [Double]
    ) -> [Double] {
        let minimum = source.min() ?? 0
        let maximum = source.max() ?? 0
        let lightness = (minimum + maximum) / 2
        let chromaScale: Double
        if lightness <= 0.5 {
            chromaScale = 57.0 / 85.0
        } else if lightness <= 5.0 / 6.0 {
            chromaScale = (
                (87.0 / 5.0) * lightness - 3.0
            ) / (17.0 * (1.0 - lightness))
        } else {
            chromaScale = (
                21.0 / 17.0 - (57.0 / 85.0) * lightness
            ) / (1.0 - lightness)
        }

        let targetLightness = 9.0 / 17.0 * lightness
        return source.map { component in
            let provisional = targetLightness
                + chromaScale * (component - lightness)
            let lowerBound = -3.0 / 17.0 * component
            let upperBound = (20.0 - 3.0 * component) / 17.0
            return min(max(provisional, lowerBound), upperBound)
        }
    }

    private static func pastelEndpoint(
        for source: [Double],
        isBright: Bool
    ) -> [Double] {
        let minimum = source.min() ?? 0
        let maximum = source.max() ?? 0
        let chroma = maximum - minimum
        let lightness = (minimum + maximum) / 2

        let targetLightness: Double
        let chromaScale: Double
        if isBright {
            if lightness <= 10.0 / 11.0 {
                targetLightness = 137.0 / 120.0 * lightness
            } else {
                targetLightness = 17.0 / 12.0
                    - 5.0 / 12.0 * lightness
            }

            if lightness <= 5.0 / 11.0 {
                chromaScale = 851.0 / 800.0
            } else if lightness <= 0.5 {
                chromaScale = -4553.0 / 2400.0
                    + (323.0 / 240.0) / lightness
            } else if lightness <= 10.0 / 11.0 {
                chromaScale = (
                    223.0 / 240.0
                        - 851.0 / 800.0 * lightness
                ) / (1.0 - lightness)
            } else {
                chromaScale = -5.0 / 12.0
            }
        } else {
            if lightness <= 10.0 / 11.0 {
                targetLightness = 39.0 / 40.0 * lightness
            } else {
                targetLightness = 5.0 / 4.0 * lightness - 1.0 / 4.0
            }

            if lightness <= 5.0 / 11.0 {
                chromaScale = 791.0 / 800.0
            } else if lightness <= 0.5 {
                chromaScale = 1209.0 / 800.0
                    - (19.0 / 80.0) / lightness
            } else if lightness <= 10.0 / 11.0 {
                chromaScale = (
                    81.0 / 80.0
                        - 791.0 / 800.0 * lightness
                ) / (1.0 - lightness)
            } else {
                chromaScale = 5.0 / 4.0
            }
        }

        return source.map { component in
            let hueFraction = (component - minimum) / chroma
            let provisional = targetLightness
                + chroma * chromaScale * (hueFraction - 0.5)
            // These channel-relative endpoint bounds are dormant throughout
            // the unit cube, which is why the original sweeps could not
            // identify them. Display P3 boundary probes activate both sides:
            // negative extended-sRGB components hit the zero-side bound and
            // components above one hit the one-side bound. All 51 boundary /
            // holdout colors match the live macOS 27 matrix within 9.2e-7.
            let lowerBound: Double
            let upperBound: Double
            if isBright {
                lowerBound = -5.0 / 12.0 * component
                upperBound = (17.0 - 5.0 * component) / 12.0
            } else {
                lowerBound = 5.0 / 4.0 * component - 1.0 / 4.0
                upperBound = 5.0 / 4.0 * component
            }
            return min(max(provisional, lowerBound), upperBound)
        }
    }

    private static func lumaEndpointMatrix(
        bright: [Double],
        dark: [Double],
        alpha: Double
    ) -> [Float] {
        var matrix = [Float](repeating: 0, count: 20)
        for row in 0..<3 {
            let scale = bright[row] - dark[row]
            for column in 0..<3 {
                matrix[row * 5 + column] = Float(
                    scale * rec709Luma[column]
                )
            }
            matrix[row * 5 + 4] = Float(dark[row])
        }
        matrix[18] = Float(alpha)
        return matrix
    }

    private static func neutralSuppressionMatrix(
        isLightAppearance: Bool,
        alpha: Double
    ) -> [Float] {
        var matrix = [Float](repeating: 0, count: 20)
        // All 874 macOS 27 Regular Main-Off rows resolve these exact,
        // color-independent coefficients. They are the system's
        // color-space-adjusted neutral grade, not the idealized
        // 0.7 Identity + 0.3 Rec.709 approximation.
        matrix[0] = 0.76378
        matrix[1] = 0.21450812
        matrix[2] = 0.021711912
        matrix[5] = 0.0637902
        matrix[6] = 0.9145575
        matrix[7] = 0.021652289
        matrix[10] = 0.06374377
        matrix[11] = 0.21459627
        matrix[12] = 0.72166
        if isLightAppearance {
            matrix[4] = -0.100000024
            matrix[9] = -0.100000024
            matrix[14] = -0.100000024
        } else {
            matrix[4] = 0.100000024
            matrix[9] = 0.099999964
            matrix[14] = 0.099999964
        }
        matrix[18] = Float(alpha)
        return matrix
    }

    private static func achromaticMatrix(
        value: Double,
        alpha: Double
    ) -> [Float] {
        let denominator = 1.0 + 0.05 * value * (1.0 - value)
        let diagonal = 0.3125 / denominator
        let bias = (1.1875 * value - 0.25) / denominator
        var matrix = [Float](repeating: 0, count: 20)
        for row in 0..<3 {
            matrix[row * 5 + row] = Float(diagonal)
            matrix[row * 5 + 4] = Float(bias)
        }
        matrix[18] = Float(alpha)
        return matrix
    }

    /// The macOS 26 achromatic Main-On grade, shared by all four Main-On
    /// cells: `I − s(x)·(1⊗w)` with `s(x) = 0.9 + 0.05x` and `bias = 0.95x`.
    /// `w` is the system's color-space-adjusted luminance vector fitted from
    /// all 24 accepted gray rows (worst coefficient residual 6.6e-5).
    private static let achromaticSaturationBoostLuma = [
        0.2126134, 0.7152094, 0.0721772,
    ]

    private static func achromaticSaturationBoostMatrix(
        value: Double,
        alpha: Double
    ) -> [Float] {
        let strength = 0.9 + 0.05 * value
        let bias = 0.95 * value
        var matrix = [Float](repeating: 0, count: 20)
        for row in 0..<3 {
            for column in 0..<3 {
                let identity = row == column ? 1.0 : 0.0
                matrix[row * 5 + column] = Float(
                    identity - strength
                        * achromaticSaturationBoostLuma[column]
                )
            }
            matrix[row * 5 + 4] = Float(bias)
        }
        matrix[18] = Float(alpha)
        return matrix
    }
}
#endif
