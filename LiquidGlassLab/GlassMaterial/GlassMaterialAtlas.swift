//
//  GlassMaterialAtlas.swift
//  GlassMaterial
//
//  A captured atlas of resolved Glass styles: appearance × variant ×
//  participation × size. Freezing a glass to an atlas is how it renders a
//  context its window is not actually in — the motivating case is a HUD panel
//  that should hold the Main-On material while another window is main.
//
//  Every value is captured on the running machine from a probe glass that
//  genuinely resolves the target context. Participation is the only axis that
//  needs real window state (a genuinely key or main window); appearance and
//  variant can be forced on the probe, so one key-window opportunity yields
//  the whole atlas. Golden fixture values are regression references, not a
//  runtime source: a handful of resolved fields are display-sensitive.
//
//  Size is handled by sampling, not by formula. Several channels — including
//  the render-bounds group that prevents the clipped-ring artifact — depend on
//  BOTH participation and size, so neither a single frozen snapshot nor the
//  destination's live (flat-context) tree can serve a content-sized surface.
//  Capturing each cell at several short sides and interpolating per channel
//  follows size with no authored per-channel ratio/cap table.
//

#if os(macOS)
import AppKit

/// One color, stored as extended-sRGB components so samples are Codable.
public struct GlassMaterialColorValue: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
        alpha = Double(rgb.alphaComponent)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var nsColor: NSColor {
        let components = [red, green, blue, alpha].map { CGFloat($0) }
        return NSColor(
            colorSpace: .extendedSRGB,
            components: components,
            count: 4
        )
    }
}

/// One rim (key-fill highlight) pass: the layer gate, every declared effect
/// value, and both effect colors. Opening only the gate over a flat context's
/// rim shows nothing — the flat payload resolves zero-alpha colors — so the
/// payload travels with the style.
public struct GlassMaterialRimSample: Codable, Hashable, Sendable {
    public var layerOpacity: Double
    public var values: [String: Double]
    public var colors: [String: GlassMaterialColorValue]
}

/// One untinted `vibrantColorMatrix` slot: the 4×5 matrix plus its optional
/// scalar/Boolean inputs.
public struct GlassMaterialMatrixSample: Codable, Hashable, Sendable {
    public var matrix: [Float]
    public var inputs: [String: Double]
}

/// One complete resolved style at one geometry: the transplant groups the
/// AppKit reverse-engineering document verified to be individually necessary.
public struct GlassMaterialStyleSample: Codable, Hashable, Sendable {
    /// `min(width, height)` of the probe glass this was captured from.
    public var shortSide: Double

    // Group 1 — the glass shader, captured by declared capability rather than
    // by table: every numeric input, every color input, every point input,
    // and the keys that resolve nil. Nil is a value: replaying a captured nil
    // over a context's nonnil resolution requires an explicit clear.
    public var numeric: [String: Double]
    public var colors: [String: GlassMaterialColorValue]
    public var points: [String: CGPoint]
    public var nilKeys: Set<String>

    // Group 3 — render bounds. Without these the outer passes hard-clip at
    // the outline (the clipped-ring artifact): a flat context resolves
    // `marginWidth` 0.5 where Main-On resolves `0.35 · shortSide`.
    public var marginWidth: Double?
    public var outputMinimum: Double?
    public var outputMaximum: Double?

    // Groups 2 and 4 — in deterministic traversal order.
    public var matrices: [GlassMaterialMatrixSample]
    public var rims: [GlassMaterialRimSample]

    /// Captures the currently resolved style, or nil when the tree is missing,
    /// mutated (`inputFaceOpacity < 0.999`), or any discovered matrix or rim
    /// slot fails to read completely — a partial capture must not report
    /// success and then silently skip slots at apply time.
    @MainActor
    public static func capture(
        from glass: NSGlassEffectView
    ) -> GlassMaterialStyleSample? {
        guard let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) else { return nil }
        let inputs = GlassMaterialAccess.readTypedInputs(from: target)
        guard inputs.numeric["inputFaceOpacity"] ?? 0 >= 0.999 else {
            return nil
        }

        let matrixLayers = GlassMaterialAccess.untintedMatrixLayers(under: glass)
        var matrices: [GlassMaterialMatrixSample] = []
        for layer in matrixLayers {
            guard let matrix = GlassMaterialAccess.colorMatrix(on: layer) else {
                return nil
            }
            matrices.append(GlassMaterialMatrixSample(
                matrix: matrix,
                inputs: GlassMaterialAccess.matrixScalarInputs(on: layer)
            ))
        }

        let rimLayers = GlassMaterialAccess.rimLayers(under: glass)
        var rims: [GlassMaterialRimSample] = []
        for layer in rimLayers {
            guard let payload = GlassMaterialAccess.rimPayload(on: layer) else {
                return nil
            }
            var colors: [String: GlassMaterialColorValue] = [:]
            for (key, color) in payload.colors {
                guard let value = GlassMaterialColorValue(color) else { return nil }
                colors[key] = value
            }
            rims.append(GlassMaterialRimSample(
                layerOpacity: GlassMaterialAccess.rimOpacity(of: layer),
                values: payload.values,
                colors: colors
            ))
        }

        let output = GlassMaterialAccess.outputBounds(under: glass)
        var colors: [String: GlassMaterialColorValue] = [:]
        for (key, color) in inputs.colors {
            guard let value = GlassMaterialColorValue(color) else { return nil }
            colors[key] = value
        }
        return GlassMaterialStyleSample(
            shortSide: min(glass.bounds.width, glass.bounds.height),
            numeric: inputs.numeric,
            colors: colors,
            points: inputs.points,
            nilKeys: inputs.nilKeys,
            marginWidth: GlassMaterialAccess.marginWidth(under: glass),
            outputMinimum: output?.minimum,
            outputMaximum: output?.maximum,
            matrices: matrices,
            rims: rims
        )
    }
}

/// The captured style atlas: one entry per context cell, each holding samples
/// at several short sides plus an optional Main-context tint matrix for the
/// currently chosen tint color.
public struct GlassMaterialStyleAtlas: Codable, Sendable {
    /// A context cell. Appearance and variant are read live at apply time —
    /// which is how Light/Dark/Auto and Regular/Clear switch without
    /// recapture — while participation is the frozen axis.
    public struct Cell: Codable, Hashable, Sendable {
        public var isLightAppearance: Bool
        public var isClear: Bool
        public var hasMainParticipation: Bool

        public init(
            isLightAppearance: Bool,
            isClear: Bool,
            hasMainParticipation: Bool
        ) {
            self.isLightAppearance = isLightAppearance
            self.isClear = isClear
            self.hasMainParticipation = hasMainParticipation
        }
    }

    private var cells: [Cell: [GlassMaterialStyleSample]] = [:]
    /// The full 20-coefficient Tint matrix per cell for the current tint
    /// color. The transition only animates coefficient 18 (alpha); the 19 hue
    /// coefficients are context-resolved constants, and a non-main window
    /// resolves the hue-suppressed variant — so a Main-On lock restamps the
    /// captured matrix wholesale.
    private var tintMatrices: [Cell: [Float]] = [:]

    public init() {}

    public var isEmpty: Bool { cells.isEmpty }

    /// Registers a sample for a cell, keeping the cell's samples sorted by
    /// short side. Capturing the same short side twice replaces the sample.
    public mutating func add(
        _ sample: GlassMaterialStyleSample,
        for cell: Cell
    ) {
        var samples = cells[cell] ?? []
        samples.removeAll { $0.shortSide == sample.shortSide }
        samples.append(sample)
        samples.sort { $0.shortSide < $1.shortSide }
        cells[cell] = samples
    }

    public mutating func setTintMatrix(_ matrix: [Float]?, for cell: Cell) {
        tintMatrices[cell] = matrix
    }

    public func tintMatrix(for cell: Cell) -> [Float]? {
        tintMatrices[cell]
    }

    public func sampleShortSides(for cell: Cell) -> [Double] {
        (cells[cell] ?? []).map(\.shortSide)
    }

    /// The style for one cell at one live geometry, piecewise-linearly
    /// interpolated between the two bracketing captures and clamped at the
    /// sampled ends. Size-invariant channels interpolate to themselves, so no
    /// per-channel classification table is needed; the residual error is the
    /// piecewise-linear deviation across any resolver gate that falls between
    /// two probe sizes — bracket the known gates (the ≤64pt floor and the
    /// 64–160pt blur ramp) when choosing probe sizes.
    public func sample(
        for cell: Cell,
        at shortSide: Double
    ) -> GlassMaterialStyleSample? {
        guard let samples = cells[cell], let first = samples.first,
              let last = samples.last else { return nil }
        if shortSide <= first.shortSide { return first }
        if shortSide >= last.shortSide { return last }
        for (low, high) in zip(samples, samples.dropFirst())
        where shortSide <= high.shortSide {
            let span = high.shortSide - low.shortSide
            guard span > 0 else { return high }
            return Self.interpolate(
                low, high,
                progress: (shortSide - low.shortSide) / span,
                shortSide: shortSide
            )
        }
        return last
    }

    // MARK: Interpolation

    /// Linear except for gates: a pair of exactly {0, 1} endpoints is a
    /// discrete resolver flag (`inputBleedDarkenBlend`,
    /// `inputSDRHoldingToneEnabled`), which snaps to the nearer sample rather
    /// than resolving a value the system never produces.
    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        if a == b { return a }
        let gate: Set<Double> = [0, 1]
        if gate.contains(a), gate.contains(b) { return t < 0.5 ? a : b }
        return a + (b - a) * t
    }

    private static func mix(
        _ a: GlassMaterialColorValue,
        _ b: GlassMaterialColorValue,
        _ t: Double
    ) -> GlassMaterialColorValue {
        GlassMaterialColorValue(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            alpha: a.alpha + (b.alpha - a.alpha) * t
        )
    }

    private static func mixDictionaries<Value>(
        _ a: [String: Value],
        _ b: [String: Value],
        _ t: Double,
        using mix: (Value, Value, Double) -> Value
    ) -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, lowValue) in a {
            if let highValue = b[key] {
                out[key] = mix(lowValue, highValue, t)
            } else if t < 0.5 {
                out[key] = lowValue
            }
        }
        for (key, highValue) in b where a[key] == nil && t >= 0.5 {
            out[key] = highValue
        }
        return out
    }

    private static func interpolate(
        _ low: GlassMaterialStyleSample,
        _ high: GlassMaterialStyleSample,
        progress t: Double,
        shortSide: Double
    ) -> GlassMaterialStyleSample {
        var out = t < 0.5 ? low : high
        out.shortSide = shortSide
        out.numeric = mixDictionaries(low.numeric, high.numeric, t, using: mix)
        out.colors = mixDictionaries(low.colors, high.colors, t, using: mix)
        out.points = mixDictionaries(low.points, high.points, t) {
            CGPoint(
                x: $0.x + ($1.x - $0.x) * $2,
                y: $0.y + ($1.y - $0.y) * $2
            )
        }
        out.nilKeys = t < 0.5 ? low.nilKeys : high.nilKeys
        out.marginWidth = mixOptional(low.marginWidth, high.marginWidth, t)
        out.outputMinimum = mixOptional(low.outputMinimum, high.outputMinimum, t)
        out.outputMaximum = mixOptional(low.outputMaximum, high.outputMaximum, t)
        if low.matrices.count == high.matrices.count {
            out.matrices = zip(low.matrices, high.matrices).map { a, b in
                GlassMaterialMatrixSample(
                    matrix: a.matrix.count == b.matrix.count
                        ? zip(a.matrix, b.matrix).map {
                            $0 + ($1 - $0) * Float(t)
                        }
                        : (t < 0.5 ? a.matrix : b.matrix),
                    inputs: mixDictionaries(a.inputs, b.inputs, t, using: mix)
                )
            }
        }
        if low.rims.count == high.rims.count {
            out.rims = zip(low.rims, high.rims).map { a, b in
                GlassMaterialRimSample(
                    layerOpacity: mix(a.layerOpacity, b.layerOpacity, t),
                    values: mixDictionaries(a.values, b.values, t, using: mix),
                    colors: mixDictionaries(a.colors, b.colors, t, using: mix)
                )
            }
        }
        return out
    }

    private static func mixOptional(
        _ a: Double?,
        _ b: Double?,
        _ t: Double
    ) -> Double? {
        guard let a, let b else { return t < 0.5 ? a : b }
        return mix(a, b, t)
    }
}

extension GlassMaterialStyleAtlas {
    /// Reads the resolved Tint matrix from a probe glass whose `tintColor` is
    /// the color to lock, in the context of the target cell. Capture this at
    /// tint-selection time: the user is choosing the color in an active
    /// window, which is exactly the Main participation the matrix needs.
    @MainActor
    public static func captureTintMatrix(
        from glass: NSGlassEffectView
    ) -> [Float]? {
        guard let layer = GlassMaterialAccess.tintMatrixLayer(under: glass)
        else { return nil }
        return GlassMaterialAccess.colorMatrix(on: layer)
    }
}
#endif
