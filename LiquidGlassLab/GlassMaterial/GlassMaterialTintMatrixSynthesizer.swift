//
//  GlassMaterialTintMatrixSynthesizer.swift
//  GlassHUDMaterial
//
//  Closed-form macOS 27 synthesis for NSGlassEffectView's Tint-owned
//  vibrantColorMatrix. The model is derived from the accepted full-grid,
//  focused-boundary, and hue-fraction sweeps under Golden/macOS-27.
//

#if os(macOS)
import AppKit

enum GlassMaterialTintMatrixSynthesizer {
    enum Family: String, Equatable, Sendable {
        case standard
        case pastel
        case neutralSuppression
        case achromatic
    }

    static let supportedOSMajorVersion = 27

    // The accepted boundary probes resolve chroma 0.0003 as achromatic and
    // 0.0004 as chromatic. Keep the decision between those observations
    // instead of relying on a bright-endpoint residual, which mislabels
    // near-white pastel rows as standard.
    private static let achromaticChromaThreshold = 0.00035
    private static let rec709Luma = [0.2126, 0.7152, 0.0722]

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
        guard osMajorVersion == supportedOSMajorVersion else { return nil }
        let rgb = [source.red, source.green, source.blue]
        guard rgb.allSatisfy({
            $0.isFinite && $0 >= 0 && $0 <= 1
        }), source.alpha.isFinite,
        source.alpha >= 0, source.alpha <= 1 else {
            return nil
        }

        switch family(for: rgb, cell: cell) {
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
        }
    }

    static func family(
        for sourceRGB: [Double],
        cell: GlassMaterialStyleAtlas.Cell
    ) -> Family {
        precondition(sourceRGB.count == 3)

        // Regular Main-Off is color-independent neutral suppression on 27.
        if !cell.isClear && !cell.hasMainParticipation {
            return .neutralSuppression
        }

        let chroma = (sourceRGB.max() ?? 0) - (sourceRGB.min() ?? 0)
        if chroma <= achromaticChromaThreshold {
            return .achromatic
        }

        // Dark Regular Main-On is the sole pastel context on macOS 27.
        if !cell.isLightAppearance
            && !cell.isClear
            && cell.hasMainParticipation {
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
            return targetLightness
                + chroma * chromaScale * (hueFraction - 0.5)
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
}
#endif
