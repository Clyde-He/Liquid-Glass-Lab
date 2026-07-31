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
struct GlassMaterialColorValue: Codable, Hashable, Sendable {
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

    nonisolated init(red: Double, green: Double, blue: Double, alpha: Double) {
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
struct GlassMaterialRimSample: Codable, Hashable, Sendable {
    public internal(set) var layerOpacity: Double
    public internal(set) var values: [String: Double]
    public internal(set) var colors: [String: GlassMaterialColorValue]
}

/// One untinted `vibrantColorMatrix` slot: the 4×5 matrix plus its optional
/// scalar/Boolean inputs.
struct GlassMaterialMatrixSample: Codable, Hashable, Sendable {
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
struct GlassMaterialStyleSample: Codable, Hashable, Sendable {
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

    /// Captures the currently resolved style, or nil when the tree is missing,
    /// mutated (`inputFaceOpacity < 0.999`), or any discovered matrix or rim
    /// slot fails to read completely — a partial capture must not report
    /// success and then silently skip slots at apply time.
    @MainActor
    @available(macOS 26.0, *)
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
/// at several short sides plus optional color-bound Tint matrices. Persisted
/// overlays come from verified capture; the product controller may also add a
/// supported-major synthesized overlay to an in-memory value-semantic copy.
///
/// An atlas is a versioned material snapshot. Product catalogs intentionally
/// pin one accepted snapshot per macOS major release: minor/beta builds and
/// display signatures reuse it while the schema and live destination topology
/// still accept the complete payload. Runtime calibration remains the fallback
/// when a future system changes that topology.
struct GlassMaterialStyleAtlas: Codable, Sendable {
    private static let requiredRimColorKeys = ["fillColor", "keyColor"]

    /// Bump when either the payload shape or the proof required to trust a
    /// captured payload changes. Version 2 requires every Main-On sample to
    /// carry a same-context Main-Off witness; a version-1 cache may contain a
    /// stable Main-Off payload mislabeled as Main-On and must never be reused.
    public static let currentSchemaVersion = 2

    /// The environment an atlas was captured in.
    public struct Environment: Codable, Hashable, Sendable {
        public var schemaVersion: Int
        public var osBuild: String
        public var displaySignature: String
        /// Added without a schema bump because it changes catalog selection,
        /// not the captured payload. Old schema-2 JSON decodes this as nil and
        /// falls back to parsing `osBuild`.
        public var osMajorVersion: Int?

        public var resolvedOSMajorVersion: Int? {
            osMajorVersion ?? Self.inferMajorVersion(from: osBuild)
        }

        /// The running environment. Stamp this onto an atlas right after
        /// capturing it: `atlas.environment = .current(for: window.screen)`.
        @MainActor
        public static func current(for screen: NSScreen?) -> Environment {
            Environment(
                schemaVersion: GlassMaterialStyleAtlas.currentSchemaVersion,
                osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
                displaySignature: screen.map {
                    "\($0.localizedName) @\($0.backingScaleFactor)x"
                } ?? "unknown",
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            )
        }

        /// Product compatibility is deliberately major-scoped. This pins the
        /// accepted macOS 26 look across 26.x builds, and the accepted macOS 27
        /// look across 27.x builds. Display identity is diagnostics only.
        public func isCompatible(with other: Environment) -> Bool {
            guard schemaVersion == other.schemaVersion,
                  let major = resolvedOSMajorVersion,
                  let otherMajor = other.resolvedOSMajorVersion
            else { return false }
            return major == otherMajor
        }

        /// Exact identity remains available for diagnostics and lab reporting;
        /// it is no longer a product admission requirement.
        public func isExactMatch(with other: Environment) -> Bool {
            schemaVersion == other.schemaVersion
                && osBuild == other.osBuild
                && displaySignature == other.displaySignature
        }

        public func isExactBuildMatch(with other: Environment) -> Bool {
            schemaVersion == other.schemaVersion && osBuild == other.osBuild
        }

        private static func inferMajorVersion(from description: String) -> Int? {
            guard let marker = description.range(of: "Version ") else {
                return nil
            }
            let suffix = description[marker.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            return Int(digits)
        }
    }

    /// Where this atlas was captured. Nil means never stamped, which
    /// `freeze(atlas:)` treats as incompatible.
    public var environment: Environment?

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

    /// A resolved Tint matrix bound to its source color. The
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
    private var tintMatrices: [Cell: [TintMatrix]] = [:]

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

    /// Adds a resolved Tint matrix for the cell, replacing any entry with the
    /// same source RGB. Persisted runtime overlays accumulate independently of
    /// the size samples; synchronous product synthesis applies this mutation
    /// only to a short-lived Atlas copy.
    public mutating func addTintMatrix(_ matrix: TintMatrix, for cell: Cell) {
        var entries = tintMatrices[cell] ?? []
        entries.removeAll {
            Self.matchesRGB($0.sourceColor, matrix.sourceColor)
        }
        entries.append(matrix)
        tintMatrices[cell] = entries
    }

    /// Certified catalogs carry only the reusable base. Color-bound matrices
    /// belong to the app-scoped runtime overlay.
    public mutating func removeAllTintMatrices() {
        tintMatrices = [:]
    }

    public var hasTintMatrices: Bool {
        tintMatrices.values.contains { !$0.isEmpty }
    }

    /// Applies only the reusable tint overlay from a compatible runtime cache
    /// to a newly bundled certified base. The catalog remains authoritative
    /// for every style sample; cache data can only add well-formed color-bound
    /// matrices.
    public mutating func mergeTintMatrices(
        from compatibleCache: GlassMaterialStyleAtlas
    ) {
        for (cell, entries) in compatibleCache.tintMatrices {
            for entry in entries where entry.matrix.count == 20 {
                addTintMatrix(entry, for: cell)
            }
        }
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
        guard let entries = tintMatrices[cell],
              let requested = GlassMaterialColorValue(color) else { return nil }
        return entries.first {
            $0.matrix.count == 20
                && Self.matchesRGB($0.sourceColor, requested)
        }?.matrix
    }

    private static func matchesRGB(
        _ a: GlassMaterialColorValue,
        _ b: GlassMaterialColorValue
    ) -> Bool {
        let tolerance = 0.001
        return abs(a.red - b.red) <= tolerance
            && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance
    }

    public func sampleShortSides(for cell: Cell) -> [Double] {
        (cells[cell] ?? []).map(\.shortSide)
    }

    /// The largest verified Main-On render margin at one requested geometry.
    /// Used only for the transient pre-atlas window envelope, where oversizing
    /// is safer than clipping and appearance/variant are not yet trustworthy.
    public func maximumMainOnMargin(at shortSide: Double) -> Double? {
        guard hasVerifiedMainOnPayload() else { return nil }
        var margins: [Double] = []
        for isLight in [true, false] {
            for isClear in [false, true] {
                let cell = Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                guard let sample = sample(for: cell, at: shortSide) else {
                    return nil
                }
                margins.append(sample.marginWidth)
            }
        }
        return margins.max()
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
            Self.matchesSupportedTopology(sample)
        }
    }

    /// Whether the atlas contains a cryptographically-uninteresting but
    /// semantically strong proof for every Main-On sample: a fresh sample
    /// from the same appearance, variant, geometry, and display while a
    /// second window was genuinely neither key nor main.
    ///
    /// Window flags alone are not accepted as proof. A newly inserted hidden
    /// material can briefly (or permanently) resolve the flat branch even
    /// while its host already reports key/main. Requiring both the measured
    /// render-bounds expansion and the independent key-fill rim gate to differ
    /// from the paired Main-Off witness makes that false-positive unpersistable.
    public func hasVerifiedMainOnPayload() -> Bool {
        for isLight in [true, false] {
            for isClear in [false, true] {
                let mainOn = Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                guard cellHasVerifiedMainOnPayload(mainOn) else { return false }
            }
        }
        return true
    }

    /// The stricter provider-ready predicate: the paired proof above plus
    /// exact coverage of every size the consumer requested.
    public func hasVerifiedMainOnCoverage(
        shortSides requiredShortSides: [Double]
    ) -> Bool {
        guard hasVerifiedMainOnPayload() else { return false }
        for isLight in [true, false] {
            for isClear in [false, true] {
                let mainOn = Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                let mainOff = Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: false
                )
                let onSides = Set(sampleShortSides(for: mainOn))
                let offSides = Set(sampleShortSides(for: mainOff))
                guard requiredShortSides.allSatisfy({
                    onSides.contains($0) && offSides.contains($0)
                }) else { return false }
            }
        }
        return true
    }

    /// Validates one live On/Off pair before the provider admits either sample
    /// into its transaction. This deliberately uses two independent branch
    /// signals rather than a timing delay or a single magic endpoint:
    ///
    /// - Main-On opens the key-fill rim gate that Main-Off keeps closed.
    /// - The resolved background branch must independently differ through
    ///   either its expanded render margin or several shader inputs. Clear
    ///   can share the flat margin, so margin alone is not a universal proof.
    ///
    /// Both are resolved system output captured from the same machine. The
    /// absolute Main-On style remains data-driven; only the experimentally
    /// established direction and minimum separation are asserted.
    public static func verifiesMainOn(
        _ mainOn: GlassMaterialStyleSample,
        against mainOff: GlassMaterialStyleSample
    ) -> Bool {
        guard matchesSupportedTopology(mainOn),
              matchesSupportedTopology(mainOff),
              abs(mainOn.shortSide - mainOff.shortSide) < 0.001,
              let onRim = mainOn.rims.first,
              let offRim = mainOff.rims.first
        else { return false }

        let marginSeparation = mainOn.marginWidth - mainOff.marginWidth
        let minimumMarginSeparation = max(2, mainOn.shortSide * 0.05)
        let rimSeparation = onRim.layerOpacity - offRim.layerOpacity
        let sharedNumericKeys = Set(mainOn.numeric.keys)
            .intersection(mainOff.numeric.keys)
        let separatedNumericCount = sharedNumericKeys.reduce(into: 0) {
            count, key in
            guard let onValue = mainOn.numeric[key],
                  let offValue = mainOff.numeric[key]
            else { return }
            let scale = max(abs(onValue), abs(offValue), 1)
            if abs(onValue - offValue) / scale >= 0.01 {
                count += 1
            }
        }
        let backgroundBranchIsDistinct =
            marginSeparation >= minimumMarginSeparation
            || separatedNumericCount >= 3
        return rimSeparation >= 0.5 && backgroundBranchIsDistinct
    }

    private func cellHasVerifiedMainOnPayload(_ mainOn: Cell) -> Bool {
        guard mainOn.hasMainParticipation,
              let onSamples = cells[mainOn],
              !onSamples.isEmpty
        else { return false }
        let mainOff = Cell(
            isLightAppearance: mainOn.isLightAppearance,
            isClear: mainOn.isClear,
            hasMainParticipation: false
        )
        guard let offSamples = cells[mainOff] else { return false }
        return onSamples.allSatisfy { onSample in
            guard let offSample = offSamples.first(where: {
                abs($0.shortSide - onSample.shortSide) < 0.001
            }) else { return false }
            return Self.verifiesMainOn(onSample, against: offSample)
        }
    }

    private static func matchesSupportedTopology(
        _ sample: GlassMaterialStyleSample
    ) -> Bool {
        sample.matrices.count == 2
            && sample.matrices.allSatisfy { $0.matrix.count == 20 }
            && sample.rims.count == 1
            && sample.rims.allSatisfy { rim in
                !rim.values.isEmpty
                    && requiredRimColorKeys.allSatisfy {
                        rim.colors[$0] != nil
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
    nonisolated private static let discreteKeys: Set<String> = [
        "inputBleedDarkenBlend",
        "inputSDRHoldingToneEnabled",
        "global",
    ]

    nonisolated private static func mix(
        _ key: String,
        _ a: Double,
        _ b: Double,
        _ t: Double
    ) -> Double {
        if a == b { return a }
        if discreteKeys.contains(key) { return t < 0.5 ? a : b }
        return a + (b - a) * t
    }

    nonisolated private static func mix(
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

    nonisolated private static func mixDictionaries<Value>(
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
    @available(macOS 26.0, *)
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
