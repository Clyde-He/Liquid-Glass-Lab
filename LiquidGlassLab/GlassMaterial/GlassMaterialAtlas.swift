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
    public internal(set) var layerOpacity: Double
    public internal(set) var values: [String: Double]
    public internal(set) var colors: [String: GlassMaterialColorValue]
}

/// One untinted `vibrantColorMatrix` slot: the 4×5 matrix plus its optional
/// scalar/Boolean inputs.
public struct GlassMaterialMatrixSample: Codable, Hashable, Sendable {
    public internal(set) var matrix: [Float]
    public internal(set) var inputs: [String: Double]
    /// Scalar inputs the filter declares that resolved nil in the captured
    /// context. Nil is a value here just as it is for the shader: the
    /// destination may resolve these nonnil in its real context, and replay
    /// must clear them rather than leave them standing.
    public internal(set) var nilInputKeys: Set<String>
}

/// One complete resolved style at one geometry: the transplant groups the
/// AppKit reverse-engineering document verified to be individually necessary.
public struct GlassMaterialStyleSample: Codable, Hashable, Sendable {
    /// `min(width, height)` of the probe glass this was captured from.
    public internal(set) var shortSide: Double

    // Group 1 — the glass shader, captured by declared capability rather than
    // by table: every numeric input, every color input, every point input,
    // and the keys that resolve nil. Nil is a value: replaying a captured nil
    // over a context's nonnil resolution requires an explicit clear.
    public internal(set) var numeric: [String: Double]
    public internal(set) var colors: [String: GlassMaterialColorValue]
    public internal(set) var points: [String: CGPoint]
    public internal(set) var nilKeys: Set<String>

    // Group 3 — render bounds. Without these the outer passes hard-clip at
    // the outline (the clipped-ring artifact): a flat context resolves
    // `marginWidth` 0.5 where Main-On resolves `0.35 · shortSide`. The fields
    // are non-optional by design: `capture` refuses a tree that does not
    // resolve them, and decoding a persisted sample without them fails
    // instead of installing a sample the restamp would later skip.
    public internal(set) var marginWidth: Double
    public internal(set) var outputMinimum: Double
    public internal(set) var outputMaximum: Double

    // Groups 2 and 4 — in deterministic traversal order.
    public internal(set) var matrices: [GlassMaterialMatrixSample]
    public internal(set) var rims: [GlassMaterialRimSample]

    /// Every shader input this sample knows about — captured with a value or
    /// captured as nil. A destination that declares a managed input outside
    /// this set was resolved by a shader this sample never saw (typically an
    /// atlas persisted across an OS upgrade), and replaying onto it would
    /// leave the unknown inputs at the window's real-context values.
    public var capturedKeys: Set<String> {
        Set(numeric.keys)
            .union(colors.keys)
            .union(points.keys)
            .union(nilKeys)
    }

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
            let scalars = GlassMaterialAccess.matrixScalarInputs(on: layer)
            matrices.append(GlassMaterialMatrixSample(
                matrix: matrix,
                inputs: scalars.values,
                nilInputKeys: scalars.nilKeys
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

        // The supported Regular/Clear topology always resolves exactly two
        // untinted grade slots, one key-fill rim, and the render bounds. A
        // capture that finds `glassBackground` but not the rest — or only
        // part of it — sampled a partially materialized tree; admitting it
        // would fail the count-guarded restamp against the complete
        // destination topology and replay exactly the hybrid/clipped
        // material the freeze exists to prevent.
        guard matrices.count == 2, rims.count == 1,
              let marginWidth = GlassMaterialAccess.marginWidth(under: glass),
              let output = GlassMaterialAccess.outputBounds(under: glass)
        else { return nil }

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
            marginWidth: marginWidth,
            outputMinimum: output.minimum,
            outputMaximum: output.maximum,
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

    /// A captured Tint matrix bound to the color it was resolved for. The
    /// transition only animates coefficient 18 (alpha); the 19 hue
    /// coefficients are context-resolved constants, and a non-main window
    /// resolves the hue-suppressed variant — so a Main-On lock restamps the
    /// captured matrix wholesale. The binding is what keeps a Coral matrix
    /// from serving a Cyan `tintColor` after the caller changes colors.
    public struct TintMatrix: Codable, Hashable, Sendable {
        public var sourceColor: GlassMaterialColorValue
        public var matrix: [Float]

        public init(sourceColor: GlassMaterialColorValue, matrix: [Float]) {
            self.sourceColor = sourceColor
            self.matrix = matrix
        }
    }

    private var cells: [Cell: [GlassMaterialStyleSample]] = [:]
    private var tintMatrices: [Cell: TintMatrix] = [:]

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

    public mutating func setTintMatrix(_ matrix: TintMatrix?, for cell: Cell) {
        tintMatrices[cell] = matrix
    }

    /// The captured Tint matrix for a cell, but only when it was resolved for
    /// this color's hue — a stale matrix carries the previous color's hue,
    /// which is worse than the live hue-suppressed fallback.
    ///
    /// Only RGB participates in the match. The source alpha never enters the
    /// hue coefficients — coefficient 18 carries it, and the controller
    /// replaces that from the current `tintColor` on every apply — so an
    /// opacity-only change keeps serving the captured hue.
    public func tintMatrix(for cell: Cell, matching color: NSColor) -> [Float]? {
        guard let entry = tintMatrices[cell],
              entry.matrix.count == 20,
              let requested = GlassMaterialColorValue(color) else { return nil }
        let stored = entry.sourceColor
        let tolerance = 0.001
        guard abs(stored.red - requested.red) <= tolerance,
              abs(stored.green - requested.green) <= tolerance,
              abs(stored.blue - requested.blue) <= tolerance else { return nil }
        return entry.matrix
    }

    public func sampleShortSides(for cell: Cell) -> [Double] {
        (cells[cell] ?? []).map(\.shortSide)
    }

    /// True when every sample of the cell carries the structural invariants
    /// `capture` guarantees: two untinted grade slots with well-formed 4×5
    /// matrices, and one key-fill rim with a nonempty value payload and both
    /// effect colors. Capture enforces this for its own output and the
    /// payload types are not publicly constructible or mutable, so this
    /// re-validation exists for exactly one producer that cannot run those
    /// guards: `Codable` decoding of a persisted atlas.
    public func cellMatchesSupportedTopology(_ cell: Cell) -> Bool {
        guard let samples = cells[cell], !samples.isEmpty else { return false }
        return samples.allSatisfy { sample in
            sample.matrices.count == 2
                && sample.matrices.allSatisfy { $0.matrix.count == 20 }
                && sample.rims.count == 1
                && sample.rims.allSatisfy { rim in
                    !rim.values.isEmpty
                        && GlassMaterialAccess.rimColorKeys.allSatisfy {
                            rim.colors[$0] != nil
                        }
                }
        }
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

    /// The measured discrete resolver flags. Only these snap to the nearer
    /// sample instead of interpolating — a value-shape heuristic would
    /// misclassify continuous channels whose sampled endpoints happen to be
    /// 0 and 1, such as `inputShadowVibrancyContribution` across the size
    /// ramp.
    private static let discreteKeys: Set<String> = [
        "inputBleedDarkenBlend",
        "inputSDRHoldingToneEnabled",
        "global",
    ]

    private static func mix(
        _ key: String,
        _ a: Double,
        _ b: Double,
        _ t: Double
    ) -> Double {
        if a == b { return a }
        if discreteKeys.contains(key) { return t < 0.5 ? a : b }
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
        using mix: (String, Value, Value, Double) -> Value
    ) -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, lowValue) in a {
            if let highValue = b[key] {
                out[key] = mix(key, lowValue, highValue, t)
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
        out.colors = mixDictionaries(low.colors, high.colors, t) {
            _, a, b, t in mix(a, b, t)
        }
        out.points = mixDictionaries(low.points, high.points, t) { _, a, b, t in
            CGPoint(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t
            )
        }
        out.nilKeys = t < 0.5 ? low.nilKeys : high.nilKeys
        out.marginWidth = low.marginWidth
            + (high.marginWidth - low.marginWidth) * t
        out.outputMinimum = low.outputMinimum
            + (high.outputMinimum - low.outputMinimum) * t
        out.outputMaximum = low.outputMaximum
            + (high.outputMaximum - low.outputMaximum) * t
        if low.matrices.count == high.matrices.count {
            out.matrices = zip(low.matrices, high.matrices).map { a, b in
                GlassMaterialMatrixSample(
                    matrix: a.matrix.count == b.matrix.count
                        ? zip(a.matrix, b.matrix).map {
                            $0 + ($1 - $0) * Float(t)
                        }
                        : (t < 0.5 ? a.matrix : b.matrix),
                    inputs: mixDictionaries(a.inputs, b.inputs, t, using: mix),
                    nilInputKeys: t < 0.5 ? a.nilInputKeys : b.nilInputKeys
                )
            }
        }
        if low.rims.count == high.rims.count {
            out.rims = zip(low.rims, high.rims).map { a, b in
                GlassMaterialRimSample(
                    layerOpacity: mix("layerOpacity", a.layerOpacity, b.layerOpacity, t),
                    values: mixDictionaries(a.values, b.values, t, using: mix),
                    colors: mixDictionaries(a.colors, b.colors, t) {
                        _, a, b, t in mix(a, b, t)
                    }
                )
            }
        }
        return out
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
    ) -> TintMatrix? {
        guard let tintColor = glass.tintColor,
              let sourceColor = GlassMaterialColorValue(tintColor),
              let layer = GlassMaterialAccess.tintMatrixLayer(under: glass),
              let matrix = GlassMaterialAccess.colorMatrix(on: layer)
        else { return nil }
        return TintMatrix(sourceColor: sourceColor, matrix: matrix)
    }
}
#endif
