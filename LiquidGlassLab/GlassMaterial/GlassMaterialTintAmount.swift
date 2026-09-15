#if os(macOS)
import AppKit

/// Measured macOS 27 diffusion channels. These replace only the inputs that
/// depend on the system slider; the atlas remains an immutable base and Tint
/// matrix cache. Resolve diffusion before applying Materialize progress.
enum GlassMaterialTintAmount {
    static var isSupported: Bool {
        isSupported(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    static func isSupported(osMajor: Int) -> Bool {
        osMajor == 27
    }

    /// macOS 27's native Regular recipe uses DesignLibrary's perceptual
    /// estimator. Its inputs come from the resolved endpoint, BEFORE
    /// Materialize animation: native insertion/removal keeps this scale even
    /// while the presentation shader's radii and opacities animate.
    /// Clear uses a fixed 0.5 recipe. See GlassTransparencyStudy.md for native
    /// input traces, the independent scale grid and transition evidence.
    static func backdropScale(for sample: GlassMaterialStyleSample, isClear: Bool) -> Double? {
        if isClear { return 0.5 }
        guard let radius = sample.numeric["inputBlurRadius"],
              let opacity = sample.numeric["inputBlurOpacity0"],
              let fillRadius = sample.numeric["inputBlurFillBlurRadius"],
              let fillOpacity = sample.numeric["inputBlurFillNormalOpacity"],
              let faceOpacity = sample.colors["inputFaceColorMatrixFillColor"]?.alpha,
              [radius, opacity, fillRadius, fillOpacity, faceOpacity].allSatisfy(\.isFinite)
        else { return nil }

        let blur = max(0, Float(radius) * Float(opacity))
        let fillBlur = max(0, Float(fillRadius))
        let face = min(max(Float(faceOpacity), 0), 1)
        let fill = min(max(Float(fillOpacity), 0), 1)
        for scale: Float in [0.125, 0.25, 0.5] {
            func leak(_ radius: Float) -> Float {
                // Preserve the native Float constant and multiplication order
                // at the discrete bucket boundaries (approximately -pi²).
                var exponent = Float(bitPattern: 0xc11de9e5) * radius
                exponent *= radius
                exponent *= scale
                exponent *= scale
                exponent *= 0.25
                return expf(exponent)
            }
            let visibleAlias = (1 - face) * (fill * leak(fillBlur) + (1 - fill) * leak(blur))
            if visibleAlias <= Float(0.05) { return Double(scale) }
        }
        return 0.5
    }

    struct Anchor: Codable {
        var numeric: [String: Double]
        var colors: [String: GlassMaterialColorValue]
        var marginWidth: Double
    }

    struct Entry: Codable {
        var cell: GlassMaterialStyleAtlas.Cell
        var shortSide: Double
        var anchors: [Anchor] // 0, 0.5, 1
    }

    struct Model: Codable {
        var schemaVersion: Int
        var osMajorVersion: Int
        var entries: [Entry]

        var isValid: Bool {
            guard schemaVersion == 1, osMajorVersion == 27,
                  entries.count == 56 else { return false }
            let sizes: Set<Double> = [48, 64, 96, 128, 160, 200, 320]
            for cell in GlassMaterialStyleAtlas.allTintCells {
                let group = entries.filter { $0.cell == cell }
                guard group.count == sizes.count,
                      Set(group.map(\.shortSide)) == sizes else { return false }
            }
            return entries.allSatisfy { entry in
                entry.anchors.count == 3 && entry.anchors.allSatisfy { anchor in
                    Set(anchor.numeric.keys) == numericKeys
                        && Set(anchor.colors.keys) == colorKeys
                        && anchor.numeric.values.allSatisfy(\.isFinite)
                        && anchor.marginWidth.isFinite
                        && anchor.marginWidth >= 0
                        && anchor.colors.values.allSatisfy {
                            [$0.red, $0.green, $0.blue, $0.alpha].allSatisfy(\.isFinite)
                        }
                }
            }
        }

        func applying(
            to sample: GlassMaterialStyleSample,
            cell: GlassMaterialStyleAtlas.Cell,
            amount: Double
        ) -> GlassMaterialStyleSample? {
            guard amount.isFinite,
                  numericKeys.isSubset(of: Set(sample.numeric.keys)),
                  colorKeys.isSubset(of: Set(sample.colors.keys)) else { return nil }
            let group = entries.filter { $0.cell == cell }.sorted { $0.shortSide < $1.shortSide }
            guard let first = group.first, let last = group.last else { return nil }
            let lower = group.last { $0.shortSide <= sample.shortSide } ?? first
            let upper = group.first { $0.shortSide >= sample.shortSide } ?? last
            let sizeFraction = upper.shortSide == lower.shortSide ? 0
                : (sample.shortSide - lower.shortSide) / (upper.shortSide - lower.shortSide)
            let t = normalize(amount)
            let segment = t <= 0.5 ? 0 : 1
            let fraction = t <= 0.5 ? t * 2 : t * 2 - 1
            func channel(_ get: (Anchor) -> Double) -> Double {
                func atSize(_ index: Int) -> Double {
                    interpolate(get(lower.anchors[index]), get(upper.anchors[index]), sizeFraction)
                }
                return interpolate(atSize(segment), atSize(segment + 1), fraction)
            }
            func rampChannel(from start: Double, to end: Double, endAnchor: Double, _ get: (Anchor) -> Double) -> Double {
                guard let low = group.first(where: { $0.shortSide == start }),
                      let high = group.first(where: { $0.shortSide == endAnchor }) else {
                    return channel(get)
                }
                let sizeProgress = min(max((sample.shortSide - start) / (end - start), 0), 1)
                func atSize(_ index: Int) -> Double {
                    interpolate(get(low.anchors[index]), get(high.anchors[index]), sizeProgress)
                }
                return interpolate(atSize(segment), atSize(segment + 1), fraction)
            }
            var result = sample
            for key in numericKeys {
                // Opening an otherwise zero-radius blur is a discrete gate.
                // Interpolating its opacity would attenuate the effect twice.
                if cell.isClear, cell.hasMainParticipation, blurOpacityKeys.contains(key) {
                    result.numeric[key] = t > 0 ? lower.anchors[1].numeric[key] : 0
                } else if cell.isClear, key == "inputBlurFillBlurRadius" {
                    result.numeric[key] = t > 0.5 ? lower.anchors[2].numeric[key] : 0
                } else if cell.isClear, !cell.hasMainParticipation, key == "inputBlurRadius" {
                    result.numeric[key] = rampChannel(from: 48, to: 120, endAnchor: 128) { $0.numeric[key]! }
                } else if !cell.isClear, !cell.isLightAppearance,
                          ["inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR"].contains(key) {
                    result.numeric[key] = rampChannel(from: 64, to: 104, endAnchor: 128) { $0.numeric[key]! }
                } else {
                    result.numeric[key] = channel { $0.numeric[key]! }
                }
            }
            for key in colorKeys {
                result.colors[key] = GlassMaterialColorValue(
                    red: channel { $0.colors[key]!.red },
                    green: channel { $0.colors[key]!.green },
                    blue: channel { $0.colors[key]!.blue },
                    alpha: channel { $0.colors[key]!.alpha }
                )
            }
            if cell.isClear {
                result.marginWidth = t > 0.5
                    ? lower.anchors[2].marginWidth : lower.anchors[1].marginWidth
            }
            // Native geometry contains caps and a blur gate between atlas
            // coordinates. A straight line across those knees changes the
            // material even when the transparency interpolation is correct.
            let size = sample.shortSide
            if cell.isClear {
                result.numeric["inputInnerRefractionAmount"] = -min(60, size * 0.65)
                result.numeric["inputShadowAmount"] = min(75, size * 0.625)
            } else {
                result.numeric["inputInnerRefractionAmount"] = -min(60, size * 0.5)
                result.numeric["inputInnerRefractionHeight"] = min(20, size * 0.25)
                if cell.hasMainParticipation {
                    result.numeric["inputOuterRefractionHeight"] = max(16, size * 0.2)
                    let bleedBlur = size > 64 ? size * 0.35 : 0
                    result.numeric["inputBleedBlurRadius"] = bleedBlur
                    result.marginWidth = max(16, bleedBlur)
                    if let opacity = result.numeric["inputShadowOpacity"],
                       let radius = result.numeric["inputShadowRadius"] {
                        result.outputMaximum = max(8.890357668551713, radius * shadowExtent(opacity: Float(opacity)))
                    }
                }
            }
            return result
        }
    }

    /// DesignLibrary's shadow range helper (26A428), which feeds the native
    /// SDF output bound. Its logarithmic portion cannot be linearly sampled.
    private static func shadowExtent(opacity: Float) -> Double {
        let alpha = Double(opacity)
        if alpha >= 0.505 { return 1.65 + 0.05 * (min(alpha, 1) - 0.505) / 0.495 }
        if alpha <= 0.005 { return 0 }
        return max(0, 1.65 + 0.3 * log(2 * (alpha - 0.005)))
    }

    static let blurOpacityKeys: Set<String> = [
        "inputBlurOpacity0", "inputBlurOpacity1", "inputBlurOpacity2", "inputBlurOpacity3",
    ]
    static let numericKeys: Set<String> = blurOpacityKeys.union([
        "inputBlurRadius", "inputBlurFillBlurRadius", "inputBlurFillNormalOpacity",
        "inputBlurFillLightenOpacity", "inputBlurFillDarkenOpacity",
        "inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR",
    ])
    static let colorKeys: Set<String> = ["inputFaceColorMatrixFillColor"]

    static func normalize(_ amount: Double) -> Double {
        amount.isNaN ? 0.5 : min(max(amount, 0), 1)
    }

    private static func interpolate(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        if fraction <= 0 { return a }
        if fraction >= 1 { return b }
        return a + (b - a) * fraction
    }

    static let bundled: Model? = {
        guard isSupported else { return nil }
#if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
#else
        let bundles = [Bundle.main]
#endif
        for bundle in bundles {
            for subdirectory: String? in [nil, "Catalog"] {
                guard let url = bundle.url(
                    forResource: "glass-tint-amount-macos-27", withExtension: "json",
                    subdirectory: subdirectory
                ), let data = try? Data(contentsOf: url),
                      let model = try? JSONDecoder().decode(Model.self, from: data),
                      model.isValid else { continue }
                return model
            }
        }
        return nil
    }()
}

/// AppKit registers the default in NSUserDefaults. Do not use a raw
/// CFPreferences read (which omits registration defaults), or float(forKey:)
/// (which silently turns an absent key into zero). The native Glass change
/// notification is posted in each process by AppKit's preference machinery.
enum GlassSystemTintAmount {
    static let didChange = Notification.Name("NSGlassEffectDiffusionDidChangeNotification")

    static var isSupported: Bool { GlassMaterialTintAmount.isSupported }

    static func read(
        defaults: UserDefaults = .standard,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Double? {
        guard GlassMaterialTintAmount.isSupported(osMajor: osMajor) else {
            return nil
        }
        let raw = defaults.object(forKey: "NSGlassTintAmount")
        let value: Double?
        if let number = raw as? NSNumber { value = number.doubleValue }
        else if let text = raw as? String { value = Double(text) }
        else { value = nil }
        guard let value, value.isFinite else { return nil }
        return GlassMaterialTintAmount.normalize(value)
    }
}
#endif
