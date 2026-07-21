//
//  GlassLabTuning.swift
//  LiquidGlassLab
//
//  Typed access to NSGlassEffectView's private tuning surface, extracted from
//  earlier experiments. Every entry point is guarded by a selector or key
//  check so a macOS release that renames the private API degrades to a no-op
//  instead of crashing.
//
//  The rendering model, established empirically on the current macOS Glass
//  implementation:
//  - variant (Int) / subvariant (String) select a material recipe; the
//    public `style` is a facade (Regular = variant 1, Clear = variant 2).
//    Named subvariants ("menu", "sheet", "camera") are how real system
//    chrome differs from the numbered presets.
//  - The recipe resolves into ~70 inputs of the private `glassBackground`
//    CAFilter on an internal CABackdropLayer. Resolution depends on the
//    glass view's shortest side AND an internal window/display-list context.
//    A window that genuinely participates as key OR main receives graduated
//    blur, outer refraction, shadows, and an active rim; a Panel that is neither
//    receives the flat recipe. Window class/style do not select the branch.
//    This is not a virtual `isKeyWindow` check — spoofing that getter and its
//    notifications changes nothing without real AppKit/WindowServer state.
//  - Subdued is an independent axis, not an alias for non-main. On tested
//    Variants 0/2 it suppresses the active Shader/Rim payload while main, but
//    Variant 0 retains a distinct backdrop margin in that hybrid condition.
//  - The rim highlight is a separate SDF pass (CASDFKeyFillHighlightEffect
//    on its own CASDFLayer). Variants select its curvature/height/spread
//    recipe while active key/main participation gates it through layer opacity
//    and the effect's key/fill color alphas.
//
//  See Documentation/AppKitGlassReverseEngineering.md
//  for the evidence, measured formulas, and controlled window matrix.
//

#if os(macOS)
import AppKit
import CryptoKit
import ObjectiveC.runtime
import QuartzCore

enum GlassLabTuning {
    // MARK: - Recipe application

    /// Every distinct integer dispatch case exposed by the current runtime.
    /// Values outside 0...20 are retained by the getter but resolve through
    /// the Variant-0 fallback. Some in-range cases intentionally omit passes
    /// (13/14 have no glassBackground; 4/13/14 have no rim pass).
    static let variants: [Int] = Array(0...20)
    /// Named recipe inputs discovered by call-site observation and diffing.
    /// The property stores arbitrary, case-sensitive strings; only these
    /// names have produced a non-default recipe in the current probes.
    static let knownSubvariants = ["menu", "sheet", "camera"]

    static func variantLabel(for variant: Int) -> String {
        switch variant {
        case 0: "0 — Default"
        case 1: "1 — Regular (public style)"
        case 2: "2 — Clear (public style)"
        default: "\(variant) — Private"
        }
    }

    /// Stamps the full recipe state onto a glass view. Safe to call on
    /// every update; setters short-circuit unchanged values internally.
    @MainActor
    static func applyRecipe(from state: GlassLabState, to glass: NSGlassEffectView) {
        glass.tintColor = state.tintColor
        setGuarded(min(max(state.adaptiveAppearance, 0), 2), forKey: "_adaptiveAppearance", on: glass)
        setGuarded(state.variant, forKey: "_variant", on: glass)
        // Variant and subvariant are independent stored axes. Keep this order
        // only for deterministic updates; the resolver conditionally consumes
        // the name for some variants rather than globally overriding the Int.
        setGuarded(
            state.subvariant.isEmpty ? nil : state.subvariant,
            forKey: "_subvariant",
            on: glass
        )
        setGuarded(state.isSubdued ? 1 : 0, forKey: "_subduedState", on: glass)
        setGuarded(state.hasScrim ? 1 : 0, forKey: "_scrimState", on: glass)
        setGuarded(state.hasReducedTintOpacity, forKey: "_tintOpacityReduced", on: glass)

        applyOverrides(from: state, to: glass)
    }

    /// Stamps only the captured payload. Recipe setters can resolve a new
    /// CAFilter/effect tree asynchronously after `applyRecipe` returns, so the
    /// Inspector settling pass calls this again without bouncing Variant,
    /// Subvariant, Main, or other Recipe inputs a second time.
    @MainActor
    static func applyOverrides(from state: GlassLabState, to glass: NSGlassEffectView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if state.shaderOverridesEnabled, let backdrop = backdropLayer(under: glass) {
            for key in state.shaderNilOverrides {
                setShaderObjectValue(nil, forKey: key, on: backdrop)
            }
            for (key, value) in state.shaderOverrides {
                setShaderValue(value, forKey: key, on: backdrop)
            }
            for (key, value) in state.shaderColorOverrides {
                setShaderObjectValue(value.cgColor, forKey: key, on: backdrop)
            }
            for (key, value) in state.shaderPointOverrides {
                setShaderObjectValue(NSValue(point: value), forKey: key, on: backdrop)
            }
        }
        if state.shaderOverridesEnabled, !state.layerGeometryOverrides.isEmpty {
            applyLayerGeometry(state.layerGeometryOverrides, to: glass)
        }
        if state.highlightOverridesEnabled {
            for layer in highlightLayers(under: glass) {
                applyHighlightNilValues(state.highlightNilOverrides, to: layer)
                applyHighlightColors(state.highlightColorOverrides, to: layer)
                // Alpha projections intentionally apply after the full color
                // so they remain independently editable.
                applyHighlightValues(state.highlightOverrides, to: layer)
            }
        }
    }

    /// Stamps one dragged value onto the live tree. Continuous drag streams
    /// call this per tick; rewriting the full captured payload on every tick
    /// re-fetches the 77-key input inventory per key and stalls the drag.
    @MainActor
    static func applySingleShaderValue(
        _ value: Double,
        forKey key: String,
        to glass: NSGlassEffectView
    ) {
        guard let backdrop = backdropLayer(under: glass) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setShaderValue(value, forKey: key, on: backdrop)
        CATransaction.commit()
    }

    /// Single-value drag-stream variant of the highlight stamping path.
    @MainActor
    static func applySingleHighlightValue(
        _ value: Double,
        forKey key: String,
        to glass: NSGlassEffectView
    ) {
        for layer in highlightLayers(under: glass) {
            applyHighlightValues([key: value], to: layer)
        }
    }

    /// Re-resolves the private material after the host window genuinely
    /// becomes or resigns key/main participation. The controlled probes use
    /// this same AppKit hook after validating NSApp.keyWindow/mainWindow.
    @MainActor
    static func refreshResolvedWindowContext(on glass: NSGlassEffectView) {
        let selector = NSSelectorFromString("_windowChangedKeyState")
        guard glass.responds(to: selector) else { return }
        _ = glass.perform(selector)
        glass.needsLayout = true
        glass.layoutSubtreeIfNeeded()
    }

    /// Auto-generated knobs for every numeric-capable glassBackground input
    /// the curated list doesn't cover (blur-band stops, bleed extras, the
    /// BlurFill quartet, the SDR/HDR group, ...). Each gets its measured
    /// per-attribute recipe envelope where available, refined by authored CA
    /// metadata and protected by the live/override escape.
    /// Inputs whose current value is nil (unused stops like the aberration
    /// group) are included. The Inspector distinguishes that declared nil
    /// state from an input that is absent from the current filter.
    static func advancedShaderKnobs(
        from glass: NSGlassEffectView,
        metadata providedMetadata: [String: AttributeMetadata]? = nil
    ) -> [Knob] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [] }
        let inputKeys = filterInputKeys(filter)
        guard !inputKeys.isEmpty else { return [] }
        let covered = Set(shaderKnobs.map(\.key))
        let metadata = providedMetadata ?? captureShaderAttributeMetadata(from: glass)
        return inputKeys.sorted().compactMap { key in
            guard !covered.contains(key) else { return nil }
            let value = filter.value(forKey: key)
            // Metadata, unlike a nil live value, preserves the declared type.
            // This keeps unused numeric stops while excluding nil CGColor
            // inputs such as inputBleedColorMatrixFillColor.
            let declaredNumeric = metadata[key]?.valueType?.contains("NSNumber") == true
            guard declaredNumeric || value is NSNumber else { return nil }
            let kind: Knob.Kind
            switch key {
            case "inputMaxHeadroom": kind = .sentinel(9_999)
            default: switch metadata[key]?.subtype {
            case "bool": kind = .boolean
            case "angle": kind = .angle
            case "percentage": kind = .percentage
            default: kind = .scalar
            }
            }
            let measuredRange = measuredShaderRecipeRanges[key]
            let range = measuredRange ?? authoredFallbackRange(for: key)
            return Knob(
                key: key,
                label: advancedKnobLabel(for: key),
                range: range,
                fallback: (value as? NSNumber)?.doubleValue ?? 0,
                kind: kind,
                rangeSource: measuredRange == nil ? "Authoring" : "Recipe"
            )
        }
    }

    /// Per-input recipe envelopes derived from the accepted active macOS 27
    /// Recipe and formula probes across the full 0...20 ×
    /// nil/menu/sheet/camera product. Size-dependent bounds are extrapolated
    /// to the lab's maximum shortSide of 600.
    /// These are recipe ranges, not hard safety limits: CAFilter accepts
    /// values outside them, and +Current still expands non-sentinel controls.
    private static let measuredShaderRecipeRanges: [String: ClosedRange<Double>] = [
        "inputBleedBlurRadius": 0...200,
        "inputBleedColorMatrixBlack": 0...0.9,
        "inputBleedColorMatrixSaturation": 0...1.5,
        "inputBleedColorMatrixWhite": 0...1,
        "inputBleedDistance0": 0...1,
        "inputBleedDistance1": 0...1,
        "inputBleedHeight": 0...210,
        "inputBlurDistance0": -300...0,
        "inputBlurDistance1": -85...0,
        "inputBlurDistance2": -1...0,
        "inputBlurDistance3": 0...1,
        "inputBlurFillBlurRadius": 0...8,
        "inputClamp": 1...1.25,
        "inputFaceColorMatrixMaxLuma": 0...1,
        "inputFaceColorMatrixMaxLumaSDR": 0...1,
        "inputMaxHeadroom": 0...2,
        "inputRefractionDistance0": -1...4,
        "inputRefractionDistance1": -1...10,
        "inputSDRGradientDistance0": 0...1,
        "inputSDRGradientDistance1": 0...1,
        "inputSDRHoldingToneWhite": 0...1,
    ]

    /// Authoring-only bounds for declared NSNumber inputs that have never
    /// appeared in a resolved recipe. Their row stays nil until the runtime
    /// begins using them or the user explicitly authors a value.
    private static func authoredFallbackRange(for key: String) -> ClosedRange<Double> {
        switch key {
        case "inputAberrationHeight": return 0...100
        case "inputAberrationOffset": return -1...1
        case "inputBlurDistance4": return -300...0
        default: break
        }
        if key.localizedCaseInsensitiveContains("angle") {
            return (-Double.pi)...Double.pi
        }
        return 0...1
    }

    enum ShaderGroup: String, CaseIterable, Identifiable {
        // Declaration order is the inspector order. Matrix response is used
        // only to place whole semantic groups into broad, stable tiers; it
        // never reorders the paired controls inside a group.
        // High response across Variant / Context / Size.
        case backdropBlur = "Backdrop Blur"
        case face = "Face"
        // Medium response.
        case refraction = "Refraction"
        case filterHighlight = "Filter Highlight"
        case bleed = "Bleed"
        case shadow = "Shadow"
        case ringShadow = "Ring Shadow"
        // Lower-frequency or specialist controls.
        case dynamicRange = "SDR / HDR"
        case blurFill = "Blur Fill"
        case other = "Other"
        case aberration = "Aberration"

        var id: Self { self }

        /// User-facing sections follow the rendering role rather than
        /// exposing every CAFilter input under one monolithic "Shader" tree.
        var sectionTitle: String {
            switch self {
            case .refraction: "Optics · Refraction"
            case .backdropBlur: "Optics · Backdrop Blur"
            case .face: "Surface · Face"
            case .bleed: "Compositing · Bleed"
            case .shadow: "Lighting · Shadow"
            case .ringShadow: "Lighting · Ring Shadow"
            case .filterHighlight: "Lighting · Filter Highlight"
            case .blurFill: "Compositing · Blur Fill"
            case .dynamicRange: "Tone Mapping · SDR / HDR"
            case .aberration: "Optics · Aberration"
            case .other: "Pipeline · Other Inputs"
            }
        }
    }

    struct ShaderKnobGroup: Identifiable {
        let group: ShaderGroup
        let knobs: [Knob]
        var id: ShaderGroup { group }
    }

    /// Groups the entire numeric input surface by shader pass. This is a UI
    /// taxonomy, not an assertion that Core Animation evaluates them in this
    /// exact order.
    static func groupedShaderKnobs(
        from glass: NSGlassEffectView?,
        metadata: [String: AttributeMetadata]? = nil
    ) -> [ShaderKnobGroup] {
        // Keep the curated controls visible even when the selected live
        // surface is temporarily unavailable. Runtime-discovered inputs join
        // them as soon as that surface exists.
        let knobs = shaderKnobs + (glass.map {
            advancedShaderKnobs(from: $0, metadata: metadata)
        } ?? [])
        let buckets = Dictionary(grouping: knobs) { shaderGroup(forKey: $0.key) }
        return ShaderGroup.allCases.compactMap { group in
            guard let members = buckets[group], !members.isEmpty else { return nil }
            return ShaderKnobGroup(group: group, knobs: members.sorted { $0.key < $1.key })
        }
    }

    /// Shared routing for NSNumber, CGColor, CGPoint, and read-only inputs so
    /// typed values appear beside the pass that consumes them.
    static func shaderGroup(forKey key: String) -> ShaderGroup {
        if key.contains("Aberration") { return .aberration }
        if key.contains("BlurFill") { return .blurFill }
        if key.contains("SDR") || key.contains("HDR") || key.contains("Headroom") {
            return .dynamicRange
        }
        if key.contains("RingShadow") { return .ringShadow }
        if key.contains("Shadow") { return .shadow }
        if key.contains("KeyFillHighlight") { return .filterHighlight }
        if key.contains("Refraction") { return .refraction }
        if key.contains("Bleed") { return .bleed }
        if key.contains("Face") { return .face }
        if key.contains("Blur") { return .backdropBlur }
        return .other
    }

    enum HighlightGroup: String, CaseIterable, Identifiable {
        case gateAndShape
        case keyLight
        case fillLight
        case diffuse

        var id: Self { self }

        var sectionTitle: String {
            switch self {
            case .gateAndShape: "Rim Highlight · Gate & Shape"
            case .keyLight: "Rim Highlight · Key Light"
            case .fillLight: "Rim Highlight · Fill Light"
            case .diffuse: "Rim Highlight · Diffuse"
            }
        }
    }

    static func highlightGroup(forKey key: String) -> HighlightGroup {
        if key.hasPrefix("key") { return .keyLight }
        if key.hasPrefix("fill") { return .fillLight }
        if key.hasPrefix("diffuse") { return .diffuse }
        return .gateAndShape
    }

    static let shaderColorKeys: [(key: String, label: String)] = [
        ("inputFaceColorMatrixFillColor", "Face Fill Color"),
        ("inputBleedColorMatrixFillColor", "Bleed Fill Color"),
        ("inputShadowColorMatrixFillColor", "Shadow Fill Color"),
    ]

    static let shaderPointKeys: [(key: String, label: String)] = [
        ("inputShadowOffset", "Shadow Offset"),
    ]

    static let shaderReadOnlyKeys: [(key: String, label: String)] = [
        ("inputSourceSublayerName", "Source Sublayer Name"),
    ]

    /// "inputBlurFillDarkenOpacity" -> "Blur Fill Darken Opacity";
    /// "inputSDRGradientDistance0" -> "SDR Gradient Distance 0".
    private static func advancedKnobLabel(for key: String) -> String {
        let name = Array(key.hasPrefix("input") ? String(key.dropFirst(5)) : key)
        var label = ""
        for (index, character) in name.enumerated() {
            if index > 0 {
                let previous = name[index - 1]
                let nextIsLowercase = index + 1 < name.count && name[index + 1].isLowercase
                let startsWord =
                    (character.isUppercase
                        && (previous.isLowercase || previous.isNumber
                            || (previous.isUppercase && nextIsLowercase)))
                    || (character.isNumber && !previous.isNumber)
                if startsWord { label.append(" ") }
            }
            label.append(character)
        }
        return label
    }

    /// Layer-geometry knobs — not filter inputs; they bound how far the
    /// glass renders outside its outline. Read via captureLayerGeometry and
    /// stamped via applyLayerGeometry while shader overrides are enabled.
    static let geometryKnobs: [Knob] = [
        Knob(key: "backdropMarginWidth", label: "Backdrop Margin", range: 0...210, fallback: 0.5),
        // -10000 is the runtime's unbounded lower-field sentinel. Keep the
        // authoring slider useful; a dedicated sentinel control exposes it.
        Knob(
            key: "sdfOutputMinimum",
            label: "SDF Inner Limit",
            range: -200...0,
            fallback: -10_000,
            kind: .sentinel(-10_000),
            rangeSource: "Authoring"
        ),
        Knob(key: "sdfOutputMaximum", label: "SDF Field Reach", range: 0...40, fallback: 1.5),
    ]

    // MARK: - Layer geometry

    /// The recipe resolves layer-tree geometry alongside the filter inputs,
    /// and filter-only value cloning can't see it. Three values bound how far the
    /// glass renders outside its outline: the backdrop layer's marginWidth
    /// (active key/main branch: 70; neither-key-nor-main HUD: 0.5) sizes the
    /// glassBackground filter may paint into — bleed, outer refraction,
    /// shadow, ring shadow all live there — and CASDFOutputEffect.maximum
    /// (39.8 vs 1.5) clamps the SDF distance field's outer reach.
    static func captureLayerGeometry(from glass: NSGlassEffectView) -> [String: Double] {
        var values: [String: Double] = [:]
        if let backdrop = backdropLayer(under: glass),
           let margin = (valueIfResponds(forKey: "marginWidth", on: backdrop) as? NSNumber)?.doubleValue {
            values["backdropMarginWidth"] = margin
        }
        if let layer = outputEffectLayer(under: glass),
           let effect = effectObject(on: layer) {
            if let minimum = (valueIfResponds(forKey: "minimum", on: effect) as? NSNumber)?.doubleValue {
                values["sdfOutputMinimum"] = minimum
            }
            if let maximum = (valueIfResponds(forKey: "maximum", on: effect) as? NSNumber)?.doubleValue {
                values["sdfOutputMaximum"] = maximum
            }
        }
        return values
    }

    /// Capability keys are captured separately from values so a missing layer
    /// property cannot be confused with a present property whose value is nil.
    static func captureLayerGeometryKeys(from glass: NSGlassEffectView) -> Set<String> {
        var keys: Set<String> = []
        if let backdrop = backdropLayer(under: glass),
           backdrop.responds(to: NSSelectorFromString("marginWidth")) {
            keys.insert("backdropMarginWidth")
        }
        if let layer = outputEffectLayer(under: glass),
           let effect = effectObject(on: layer) {
            if effect.responds(to: NSSelectorFromString("minimum")) {
                keys.insert("sdfOutputMinimum")
            }
            if effect.responds(to: NSSelectorFromString("maximum")) {
                keys.insert("sdfOutputMaximum")
            }
        }
        return keys
    }

    static func applyLayerGeometry(_ values: [String: Double], to glass: NSGlassEffectView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let margin = values["backdropMarginWidth"],
           let backdrop = backdropLayer(under: glass),
           backdrop.responds(to: NSSelectorFromString("setMarginWidth:")) {
            backdrop.setValue(margin, forKey: "marginWidth")
        }
        if (values["sdfOutputMinimum"] != nil || values["sdfOutputMaximum"] != nil),
           let layer = outputEffectLayer(under: glass),
           let effect = effectObject(on: layer),
           let copy = effect.copy() as? NSObject {
            if let minimum = values["sdfOutputMinimum"],
               copy.responds(to: NSSelectorFromString("setMinimum:")) {
                copy.setValue(minimum, forKey: "minimum")
            }
            if let maximum = values["sdfOutputMaximum"],
               copy.responds(to: NSSelectorFromString("setMaximum:")) {
                copy.setValue(maximum, forKey: "maximum")
            }
            setValueIfResponds(copy, forKey: "effect", on: layer)
        }
        CATransaction.commit()
    }

    /// The CASDFLayer carrying the output effect whose `minimum` / `maximum`
    /// clamp the SDF field on either side of the outline.
    private static func outputEffectLayer(under glass: NSGlassEffectView) -> CALayer? {
        guard let root = glass.layer else { return nil }
        return firstSDFLayer(withEffect: "CASDFOutputEffect", under: root)
    }

    private static func firstSDFLayer(withEffect effectClass: String, under layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == "CASDFLayer",
           let effect = effectObject(on: layer),
           String(describing: type(of: effect)) == effectClass {
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let match = firstSDFLayer(withEffect: effectClass, under: sublayer) { return match }
        }
        return nil
    }

    private static func setGuarded(_ value: Any?, forKey key: String, on glass: NSGlassEffectView) {
        setValueIfResponds(value, forKey: key, on: glass)
    }

    /// Private KVC must never be attempted merely because a key was observed
    /// on another macOS build. NSObject raises NSUnknownKeyException before
    /// Swift can catch it, so every fixed read/write first proves the runtime
    /// getter/setter exists. Missing fields deliberately degrade to nil/no-op.
    private static func valueIfResponds(forKey key: String, on object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static func describedValue(forKey key: String, on object: NSObject) -> String {
        guard object.responds(to: NSSelectorFromString(key)) else { return "Absent" }
        return object.value(forKey: key).map { String(describing: $0) } ?? "nil"
    }

    private static func setValueIfResponds(_ value: Any?, forKey key: String, on object: NSObject) {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard object.responds(to: NSSelectorFromString(setter)) else { return }
        object.setValue(value, forKey: key)
    }

    // MARK: - Knobs

    /// One tunable parameter. `fallback` is the value observed on a fresh
    /// default-variant glass. `range` is the rounded envelope from a sweep of
    /// every known recipe in both window contexts, extrapolated across this
    /// lab's full 24...600 shortest-side domain. Core Animation metadata wins
    /// when it publishes a useful authored range; `prefersSweepRange` handles
    /// metadata that is technically valid but far too broad for this editor.
    struct Knob {
        enum Kind: Equatable {
            case scalar
            case percentage
            case angle
            case boolean
            /// A normal authoring range plus a recipe sentinel outside it.
            case sentinel(Double)
        }

        let key: String
        let label: String
        let range: ClosedRange<Double>
        let fallback: Double
        let prefersSweepRange: Bool
        let kind: Kind
        let rangeSource: String

        init(
            key: String,
            label: String,
            range: ClosedRange<Double>,
            fallback: Double,
            prefersSweepRange: Bool = false,
            kind: Kind = .scalar,
            rangeSource: String = "Recipe"
        ) {
            self.key = key
            self.label = label
            self.range = range
            self.fallback = fallback
            self.prefersSweepRange = prefersSweepRange
            self.kind = kind
            self.rangeSource = rangeSource
        }
    }

    /// Inputs that either never changed or never produced a value anywhere
    /// in the measured matrix. They remain authorable for private-API
    /// exploration, but the inspector folds them together by default so
    /// high-signal Recipe controls are visible first.
    private static let measuredMatrixLowSignalKeys: Set<String> = [
        "inputBleedDistance1",
        "inputBlurDistance3",
        "inputBlurFillLightenOpacity",
        "inputClampPreserveHue",
        "inputSDRShadowOpacity",
        "inputShadowBlurRadius",
        "inputShadowColorMatrixBlack",
        "inputShadowDistanceOffset",
        "fillAngle",
        "fillHeightOffset",
        "fillHeightScale",
        "fillSpreadOffset",
        "fillSpreadScale",
        "global",
        "keyHeightOffset",
        "keyHeightScale",
        "keySpreadOffset",
        "keySpreadScale",
        "sdfOutputMinimum",
        // Declared NSNumber inputs that stayed nil in all 1,008 samples.
        "inputBlurOpacity4",
        "inputBlurDistance4",
        "inputAberrationAmount",
        "inputAberrationHeight",
        "inputAberrationOffset",
        "inputAberrationAngle",
    ]

    static func isMatrixLowSignal(_ knob: Knob) -> Bool {
        measuredMatrixLowSignalKeys.contains(knob.key)
    }

    /// Range/type information exposed by Core Animation's private attribute
    /// metadata. Many inputs only declare NSNumber and intentionally omit a
    /// slider range; callers must retain a fallback for those keys.
    struct AttributeMetadata {
        let sliderRange: ClosedRange<Double>?
        let subtype: String?
        let valueType: String?
        let source: String
    }

    struct ResolvedSliderRange {
        let range: ClosedRange<Double>
        let source: String
    }

    static let shaderKnobs: [Knob] = [
        Knob(key: "inputInnerRefractionAmount", label: "Inner Refraction Amount", range: -80...0, fallback: -60),
        Knob(key: "inputInnerRefractionHeight", label: "Inner Refraction Height", range: 0...25, fallback: 20),
        Knob(key: "inputOuterRefractionAmount", label: "Outer Refraction Amount", range: 0...150, fallback: 0),
        Knob(key: "inputOuterRefractionHeight", label: "Outer Refraction Height", range: 0...120, fallback: 0),
        Knob(key: "inputBlurRadius", label: "Blur Radius", range: 0...12, fallback: 5),
        Knob(key: "inputFaceOpacity", label: "Face Opacity", range: 0...1, fallback: 1),
        Knob(key: "inputFaceColorMatrixWhite", label: "Face White", range: 0...1.1, fallback: 1.1),
        Knob(key: "inputFaceColorMatrixBlack", label: "Face Black", range: 0...0.5, fallback: 0.08),
        Knob(key: "inputFaceColorMatrixSaturation", label: "Face Saturation", range: 0...1.4, fallback: 1.4),
        Knob(key: "inputBleedAmount", label: "Bleed Amount", range: 0...210, fallback: 52.5),
        Knob(key: "inputBleedOpacity", label: "Bleed Opacity", range: 0...1, fallback: 0),
        Knob(key: "inputKeyFillHighlightAmount", label: "Highlight Amount", range: 0...1, fallback: 0.5),
        Knob(key: "inputKeyFillHighlightHeight", label: "Highlight Height", range: 0...1, fallback: 0.5),
        Knob(key: "inputKeyFillHighlightAngle", label: "Highlight Angle", range: 0...6.283, fallback: 1.571),
        Knob(key: "inputKeyFillHighlightSpread", label: "Highlight Spread", range: 0...3.142, fallback: 2.094),
        Knob(key: "inputKeyFillHighlightEffectOffset", label: "Highlight Offset", range: -1...0, fallback: -0.5),
        Knob(key: "inputKeyFillHighlightColorBias", label: "Highlight Color Bias", range: -0.5...0, fallback: -0.1875),
        // Shadow pass — drawn outside the rounded outline within the layer
        // rect, so on the panel it needs Panel Window Margin to be visible.
        // The active key/main branch resolves Amount≈75 and
        // Height≈0.4–0.5×shortSide; the neither-key-nor-main Panel branch zeros
        // the whole group.
        Knob(key: "inputShadowAmount", label: "Shadow Amount", range: 0...75, fallback: 0),
        Knob(key: "inputShadowHeight", label: "Shadow Height", range: 0...240, fallback: 0),
        Knob(key: "inputShadowOpacity", label: "Shadow Opacity", range: 0...1, fallback: 0),
        Knob(key: "inputShadowRadius", label: "Shadow Radius", range: 0...24, fallback: 0),
        Knob(key: "inputShadowBlurRadius", label: "Shadow Blur Radius", range: 0...24, fallback: 0),
        Knob(key: "inputShadowDistanceOffset", label: "Shadow Distance Offset", range: -24...24, fallback: 0),
        Knob(key: "inputShadowVibrancyContribution", label: "Shadow Vibrancy", range: 0...1, fallback: 0),
        Knob(key: "inputShadowColorMatrixWhite", label: "Shadow White", range: 0...1, fallback: 1),
        Knob(key: "inputShadowColorMatrixBlack", label: "Shadow Black", range: 0...0.5, fallback: 0),
        Knob(key: "inputShadowColorMatrixSaturation", label: "Shadow Saturation", range: 0...1.2, fallback: 1),
        // Ring shadow — a stroked ring hugging the outline (the soft
        // contact-shadow rim visible on system chrome).
        Knob(key: "inputRingShadowOpacity", label: "Ring Shadow Opacity", range: 0...0.1, fallback: 0),
        Knob(key: "inputRingShadowStrokeWidth", label: "Ring Shadow Stroke", range: 0...4, fallback: 4),
        Knob(key: "inputRingShadowBlurRadius", label: "Ring Shadow Blur", range: 0...5, fallback: 5),
        Knob(key: "inputRingShadowOffset", label: "Ring Shadow Offset", range: 0...12, fallback: 8),
        Knob(key: "inputRingShadowMask", label: "Ring Shadow Mask", range: 0...1, fallback: 1),
    ]

    static let highlightKnobs: [Knob] = [
        // The master gate: the real key-or-main branch resolves it to 1 while
        // the neither-key-nor-main Panel branch parks it at 0. A public
        // isKeyWindow spoof cannot change this internal environment state.
        Knob(key: "layerOpacity", label: "Layer Opacity (Gate)", range: 0...1, fallback: 0),
        Knob(key: "keyAmount", label: "Key Amount", range: 0...1, fallback: 0.5),
        Knob(
            key: "keyHeight",
            label: "Key Height",
            range: 0...5,
            fallback: 1,
            prefersSweepRange: true
        ),
        Knob(key: "keySpread", label: "Key Spread", range: 0...3.142, fallback: 1.494),
        Knob(key: "keyAngle", label: "Key Angle", range: -3.142...3.142, fallback: 0),
        Knob(key: "keyColorAlpha", label: "Key Color Alpha", range: 0...1, fallback: 0),
        Knob(key: "keyHeightScale", label: "Key Height Scale", range: 0...2, fallback: 1, rangeSource: "Authoring"),
        Knob(key: "keyHeightOffset", label: "Key Height Offset", range: -5...5, fallback: 0, rangeSource: "Authoring"),
        Knob(key: "keySpreadScale", label: "Key Spread Scale", range: 0...2, fallback: 1, rangeSource: "Authoring"),
        Knob(key: "keySpreadOffset", label: "Key Spread Offset", range: -3.142...3.142, fallback: 0, kind: .angle, rangeSource: "Authoring"),
        Knob(key: "fillAmount", label: "Fill Amount", range: 0...1, fallback: 0.5),
        Knob(
            key: "fillHeight",
            label: "Fill Height",
            range: 0...5,
            fallback: 1,
            prefersSweepRange: true
        ),
        Knob(key: "fillSpread", label: "Fill Spread", range: 0...3.142, fallback: 1.494),
        Knob(key: "fillAngle", label: "Fill Angle", range: -3.142...3.142, fallback: 3.142),
        Knob(key: "fillColorAlpha", label: "Fill Color Alpha", range: 0...1, fallback: 0),
        Knob(key: "fillHeightScale", label: "Fill Height Scale", range: 0...2, fallback: 1, rangeSource: "Authoring"),
        Knob(key: "fillHeightOffset", label: "Fill Height Offset", range: -5...5, fallback: 0, rangeSource: "Authoring"),
        Knob(key: "fillSpreadScale", label: "Fill Spread Scale", range: 0...2, fallback: 1, rangeSource: "Authoring"),
        Knob(key: "fillSpreadOffset", label: "Fill Spread Offset", range: -3.142...3.142, fallback: 0, kind: .angle, rangeSource: "Authoring"),
        Knob(key: "curvature", label: "Curvature", range: 0...1, fallback: 0.75),
        Knob(key: "diffuseAmountScale", label: "Diffuse Amount", range: 0...1, fallback: 0.15),
        // System metadata says 0...1 for diffuseHeightScale, while every
        // observed live recipe resolves 8. Prefer the measured recipe domain.
        Knob(key: "diffuseHeightScale", label: "Diffuse Height Scale", range: 0...10, fallback: 8, prefersSweepRange: true),
        Knob(key: "diffuseSpreadScale", label: "Diffuse Spread Scale", range: 0...1, fallback: 0.65),
        Knob(key: "global", label: "Global", range: 0...1, fallback: 0, kind: .boolean),
    ]

    static let highlightColorKeys: [(key: String, label: String)] = [
        ("keyColor", "Key Color"),
        ("fillColor", "Fill Color"),
    ]

    // MARK: - Attribute metadata and slider ranges

    /// Reads the same private Core Animation metadata used by Apple's own
    /// filter editors. Percentage inputs expose 0...1; many geometry-driven
    /// NSNumber inputs expose only their type and no authored range.
    static func captureShaderAttributeMetadata(
        from glass: NSGlassEffectView
    ) -> [String: AttributeMetadata] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [:] }
        let selector = NSSelectorFromString("attributesForKeyPath:")
        guard filter.responds(to: selector) else { return [:] }

        let inputKeys = filterInputKeys(filter)
        guard !inputKeys.isEmpty else { return [:] }
        var metadata: [String: AttributeMetadata] = [:]
        // All input keys, not just the curated knobs — the auto-generated
        // Advanced knobs resolve their ranges from the same table.
        for key in inputKeys {
            guard let raw = filter.perform(selector, with: key)?.takeUnretainedValue(),
                  let attributes = raw as? [String: Any] else { continue }
            metadata[key] = parseAttributeMetadata(attributes, source: "System")
        }
        return metadata
    }

    /// CASDFKeyFillHighlightEffect publishes a richer CA_attributes table,
    /// including 0...50 height ranges and 0...1 amount/curvature ranges.
    static func captureHighlightAttributeMetadata() -> [String: AttributeMetadata] {
        var metadata: [String: AttributeMetadata] = [
            "layerOpacity": AttributeMetadata(
                sliderRange: 0...1,
                subtype: "percentage",
                valueType: "NSNumber",
                source: "CALayer"
            ),
            "keyColorAlpha": AttributeMetadata(
                sliderRange: 0...1,
                subtype: "percentage",
                valueType: "CGColor",
                source: "CGColor"
            ),
            "fillColorAlpha": AttributeMetadata(
                sliderRange: 0...1,
                subtype: "percentage",
                valueType: "CGColor",
                source: "CGColor"
            ),
        ]

        guard let effectClass = NSClassFromString("CASDFKeyFillHighlightEffect"),
              let table = objectFromClassMethod(
                on: effectClass,
                selectorName: "CA_attributes"
              ) as? [String: Any] else { return metadata }

        for knob in highlightKnobs {
            guard let attributes = table[knob.key] as? [String: Any] else { continue }
            metadata[knob.key] = parseAttributeMetadata(attributes, source: "System")
        }
        return metadata
    }

    /// Prefers a useful authored system range, then semantic angle bounds,
    /// then the measured recipe-sweep envelope. Any live/override value
    /// outside that envelope grows it with headroom so the Slider never
    /// visually clamps a real value.
    static func resolvedSliderRange(
        for knob: Knob,
        metadata: AttributeMetadata?,
        liveValue: Double?,
        overrideValue: Double?
    ) -> ResolvedSliderRange {
        let base: ClosedRange<Double>
        var source: String

        if case .sentinel = knob.kind {
            base = knob.range
            source = "Authoring"
        } else if knob.prefersSweepRange {
            base = knob.range
            source = knob.rangeSource
        } else if let systemRange = metadata?.sliderRange {
            base = systemRange
            source = metadata?.source ?? "System"
        } else if metadata?.subtype == "angle" {
            if knob.key.localizedCaseInsensitiveContains("spread") {
                base = 0...Double.pi
            } else {
                base = (-Double.pi)...Double.pi
            }
            source = "Angle"
        } else {
            base = knob.range
            source = knob.rangeSource
        }

        // Sentinels are discrete recipe states, not an instruction to stretch
        // a linear slider by four orders of magnitude.
        if case .sentinel = knob.kind {
            return ResolvedSliderRange(range: base, source: source)
        }

        let values = [liveValue, overrideValue]
            .compactMap { $0 }
            .filter(\.isFinite)
        guard let observedMin = values.min(),
              let observedMax = values.max(),
              observedMin < base.lowerBound || observedMax > base.upperBound else {
            return ResolvedSliderRange(range: base, source: source)
        }

        let envelopeMin = min(base.lowerBound, observedMin)
        let envelopeMax = max(base.upperBound, observedMax)
        let padding = max((envelopeMax - envelopeMin) * 0.08, 0.001)
        let lower = observedMin < base.lowerBound ? observedMin - padding : base.lowerBound
        let upper = observedMax > base.upperBound ? observedMax + padding : base.upperBound
        source += "+Current"
        return ResolvedSliderRange(range: lower...upper, source: source)
    }

    static func resolvedControlKind(for knob: Knob, metadata: AttributeMetadata?) -> Knob.Kind {
        if knob.kind != .scalar { return knob.kind }
        switch metadata?.subtype {
        case "bool": return .boolean
        case "percentage": return .percentage
        case "angle": return .angle
        default: return .scalar
        }
    }

    private static func parseAttributeMetadata(
        _ attributes: [String: Any],
        source: String
    ) -> AttributeMetadata {
        let minimum = (attributes["sliderMin"] as? NSNumber)?.doubleValue
        let maximum = (attributes["sliderMax"] as? NSNumber)?.doubleValue
        let range: ClosedRange<Double>? = if let minimum, let maximum, minimum <= maximum {
            minimum...maximum
        } else {
            nil
        }
        return AttributeMetadata(
            sliderRange: range,
            subtype: attributes["subtype"] as? String,
            valueType: attributes["type"].map { String(describing: $0) },
            source: source
        )
    }

    private static func objectFromClassMethod(
        on objectClass: AnyClass,
        selectorName: String
    ) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(objectClass, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(objectClass, selector)?.takeUnretainedValue()
    }

    // MARK: - Private layer access

    /// The CABackdropLayer carrying the glass shader. Exists only after the
    /// hosted glass has laid out at least once.
    static func backdropLayer(under glass: NSGlassEffectView) -> CALayer? {
        glass.layer.flatMap { firstLayer(className: "CABackdropLayer", under: $0) }
    }

    private static func firstLayer(className: String, under layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == className { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let match = firstLayer(className: className, under: sublayer) { return match }
        }
        return nil
    }

    /// Every CASDFLayer whose effect is the key-fill highlight pass.
    static func highlightLayers(under glass: NSGlassEffectView) -> [CALayer] {
        var found: [CALayer] = []
        if let root = glass.layer {
            collectHighlightLayers(under: root, into: &found)
        }
        return found
    }

    private static func collectHighlightLayers(under layer: CALayer, into found: inout [CALayer]) {
        if String(describing: type(of: layer)) == "CASDFLayer",
           let effect = effectObject(on: layer),
           String(describing: type(of: effect)) == "CASDFKeyFillHighlightEffect" {
            found.append(layer)
        }
        for sublayer in layer.sublayers ?? [] {
            collectHighlightLayers(under: sublayer, into: &found)
        }
    }

    private static func glassBackgroundFilter(on layer: CALayer) -> NSObject? {
        (layer.filters as? [NSObject])?.first {
            filterName($0) == "glassBackground"
        }
    }

    private static func filterName(_ filter: NSObject) -> String? {
        valueIfResponds(forKey: "name", on: filter) as? String
    }

    private static func filterInputKeys(_ filter: NSObject) -> [String] {
        valueIfResponds(forKey: "inputKeys", on: filter) as? [String] ?? []
    }

    /// Runtime inputKeys is the authoritative capability list for dynamic
    /// CAFilter parameters. It protects fixed typed descriptors as well as
    /// numeric inputs when a macOS release removes or renames one.
    private static func filterValue(forKey key: String, on filter: NSObject) -> Any? {
        guard filterInputKeys(filter).contains(key) else { return nil }
        return filter.value(forKey: key)
    }

    private static func effectObject(on layer: CALayer) -> NSObject? {
        valueIfResponds(forKey: "effect", on: layer) as? NSObject
    }

    // MARK: - Shader inputs

    static func shaderValue(forKey key: String, on backdrop: CALayer) -> Double? {
        guard let filter = glassBackgroundFilter(on: backdrop),
              let number = filterValue(forKey: key, on: filter) as? NSNumber else { return nil }
        return number.doubleValue
    }

    /// Filter objects attached to a layer are immutable; per CAFilter's
    /// contract, changes go through the layer with a filters.<name>.<key>
    /// key path.
    static func setShaderValue(_ value: Double, forKey key: String, on backdrop: CALayer) {
        setShaderObjectValue(value, forKey: key, on: backdrop)
    }

    private static func setShaderObjectValue(_ value: Any?, forKey key: String, on backdrop: CALayer) {
        guard let filter = glassBackgroundFilter(on: backdrop),
              filterInputKeys(filter).contains(key),
              let name = filterName(filter) else { return }
        backdrop.setValue(value, forKeyPath: "filters.\(name).\(key)")
    }

    /// nil means that the glassBackground pass itself is absent. A non-nil
    /// set is the authoritative current filter inventory, including inputs
    /// whose resolved value is nil.
    static func captureShaderInputKeys(from glass: NSGlassEffectView) -> Set<String>? {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return nil }
        return Set(filterInputKeys(filter))
    }

    /// Every numeric input of the glass shader — the resolved recipe.
    static func captureShaderInputs(from glass: NSGlassEffectView) -> [String: Double] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [:] }
        var values: [String: Double] = [:]
        for key in filterInputKeys(filter) {
            if let number = filter.value(forKey: key) as? NSNumber {
                values[key] = number.doubleValue
            }
        }
        return values
    }

    static func captureShaderColors(from glass: NSGlassEffectView) -> [String: NSColor] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [:] }
        var values: [String: NSColor] = [:]
        for descriptor in shaderColorKeys {
            guard let rawValue = filterValue(forKey: descriptor.key, on: filter),
                  CFGetTypeID(rawValue as CFTypeRef) == CGColor.typeID else { continue }
            let cgColor = rawValue as! CGColor
            guard
                  let color = NSColor(cgColor: cgColor) else { continue }
            values[descriptor.key] = color
        }
        return values
    }

    static func captureShaderPoints(from glass: NSGlassEffectView) -> [String: CGPoint] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [:] }
        var values: [String: CGPoint] = [:]
        for descriptor in shaderPointKeys {
            guard let value = filterValue(forKey: descriptor.key, on: filter) as? NSValue else { continue }
            values[descriptor.key] = value.pointValue
        }
        return values
    }

    static func captureShaderStrings(from glass: NSGlassEffectView) -> [String: String] {
        guard let backdrop = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: backdrop) else { return [:] }
        var values: [String: String] = [:]
        for descriptor in shaderReadOnlyKeys {
            guard let value = filterValue(forKey: descriptor.key, on: filter) as? String else { continue }
            values[descriptor.key] = value
        }
        return values
    }

    // MARK: - Rim highlight

    static func highlightValue(forKey key: String, on layer: CALayer) -> Double? {
        if key == "layerOpacity" { return Double(layer.opacity) }
        guard let effect = effectObject(on: layer) else { return nil }
        switch key {
        case "keyColorAlpha": return highlightColor(effect, getter: "keyColor").map { Double($0.alpha) }
        case "fillColorAlpha": return highlightColor(effect, getter: "fillColor").map { Double($0.alpha) }
        default:
            guard effect.responds(to: NSSelectorFromString(key)) else { return nil }
            return (effect.value(forKey: key) as? NSNumber)?.doubleValue
        }
    }

    /// Effects behave as value objects; mutate a copy and re-assign it for
    /// the layer to pick the change up. Runs inside a no-actions transaction
    /// so repeated stamping never animates.
    static func applyHighlightValues(_ values: [String: Double], to layer: CALayer) {
        guard let effect = effectObject(on: layer),
              let copy = effect.copy() as? NSObject else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeHighlightPresentationAnimations(from: layer)
        for (key, value) in values {
            switch key {
            case "layerOpacity":
                layer.opacity = Float(value)
            case "keyColorAlpha":
                setHighlightColorAlpha(value, on: copy, getter: "keyColor", setter: "setKeyColor:")
            case "fillColorAlpha":
                setHighlightColorAlpha(value, on: copy, getter: "fillColor", setter: "setFillColor:")
            default:
                let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                guard copy.responds(to: NSSelectorFromString(setter)) else { continue }
                copy.setValue(value, forKey: key)
            }
        }
        setValueIfResponds(copy, forKey: "effect", on: layer)
        removeHighlightPresentationAnimations(from: layer)
        CATransaction.commit()
    }

    /// Key/main transitions may install named or grouped animations rather
    /// than an animation literally registered as "opacity". Remove every
    /// property animation that targets the Rim gate/effect; otherwise the
    /// model values read as locked while the presentation layer still fades to
    /// the freshly resolved Flat payload.
    private static func removeHighlightPresentationAnimations(from layer: CALayer) {
        layer.removeAnimation(forKey: "opacity")
        layer.removeAnimation(forKey: "effect")
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key),
                  highlightAnimationAffectsLockedPresentation(animation) else { continue }
            layer.removeAnimation(forKey: key)
        }
    }

    private static func highlightAnimationAffectsLockedPresentation(_ animation: CAAnimation) -> Bool {
        if let propertyAnimation = animation as? CAPropertyAnimation,
           let keyPath = propertyAnimation.keyPath {
            return keyPath == "opacity"
                || keyPath == "effect"
                || keyPath.hasPrefix("effect.")
        }
        if let group = animation as? CAAnimationGroup {
            for child in group.animations ?? [] {
                if highlightAnimationAffectsLockedPresentation(child) {
                    return true
                }
            }
        }
        return false
    }

    static func captureHighlightValues(from glass: NSGlassEffectView) -> [String: Double] {
        guard let layer = highlightLayers(under: glass).first else { return [:] }
        var values: [String: Double] = [:]
        for knob in highlightKnobs {
            if let value = highlightValue(forKey: knob.key, on: layer) {
                values[knob.key] = value
            }
        }
        return values
    }

    /// nil means that the whole Rim pass is absent. When it exists, this set
    /// records which effect properties are implemented even if they currently
    /// return nil.
    static func captureHighlightInputKeys(from glass: NSGlassEffectView) -> Set<String>? {
        guard let layer = highlightLayers(under: glass).first else { return nil }
        var keys: Set<String> = ["layerOpacity"]
        guard let effect = effectObject(on: layer) else { return keys }

        for knob in highlightKnobs {
            let getter: String
            switch knob.key {
            case "keyColorAlpha": getter = "keyColor"
            case "fillColorAlpha": getter = "fillColor"
            default: getter = knob.key
            }
            if effect.responds(to: NSSelectorFromString(getter)) {
                keys.insert(knob.key)
            }
        }
        for descriptor in highlightColorKeys
        where effect.responds(to: NSSelectorFromString(descriptor.key)) {
            keys.insert(descriptor.key)
        }
        return keys
    }

    private static func applyHighlightNilValues(_ keys: Set<String>, to layer: CALayer) {
        guard !keys.isEmpty,
              let effect = effectObject(on: layer),
              let copy = effect.copy() as? NSObject else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys {
            switch key {
            case "layerOpacity":
                continue
            case "keyColorAlpha", "keyColor":
                setHighlightColor(nil, on: copy, setter: "setKeyColor:")
            case "fillColorAlpha", "fillColor":
                setHighlightColor(nil, on: copy, setter: "setFillColor:")
            case "diffuseColor":
                setHighlightColor(nil, on: copy, setter: "setDiffuseColor:")
            default:
                let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                guard copy.responds(to: NSSelectorFromString(setter)) else { continue }
                copy.setValue(nil, forKey: key)
            }
        }
        setValueIfResponds(copy, forKey: "effect", on: layer)
        CATransaction.commit()
    }

    static func captureHighlightColors(from glass: NSGlassEffectView) -> [String: NSColor] {
        guard let layer = highlightLayers(under: glass).first,
              let effect = effectObject(on: layer) else { return [:] }
        var values: [String: NSColor] = [:]
        for descriptor in highlightColorKeys {
            guard let color = highlightColor(effect, getter: descriptor.key),
                  let nsColor = NSColor(cgColor: color) else { continue }
            values[descriptor.key] = nsColor
        }
        return values
    }

    static func applyHighlightColors(_ values: [String: NSColor], to layer: CALayer) {
        guard !values.isEmpty,
              let effect = effectObject(on: layer),
              let copy = effect.copy() as? NSObject else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, color) in values {
            setHighlightColor(color.cgColor, on: copy, setter: "set\(key.prefix(1).uppercased())\(key.dropFirst()):")
        }
        setValueIfResponds(copy, forKey: "effect", on: layer)
        CATransaction.commit()
    }

    /// The color properties are raw CGColorRefs, which KVC cannot box — go
    /// through typed IMPs.
    private static func highlightColor(_ effect: NSObject, getter: String) -> CGColor? {
        let selector = NSSelectorFromString(getter)
        guard effect.responds(to: selector) else { return nil }
        typealias GetColor = @convention(c) (NSObject, Selector) -> Unmanaged<CGColor>?
        let imp = unsafeBitCast(effect.method(for: selector), to: GetColor.self)
        return imp(effect, selector)?.takeUnretainedValue()
    }

    private static func setHighlightColorAlpha(
        _ alpha: Double,
        on effect: NSObject,
        getter: String,
        setter: String
    ) {
        let selector = NSSelectorFromString(setter)
        guard effect.responds(to: selector),
              let current = highlightColor(effect, getter: getter),
              let updated = current.copy(alpha: alpha) else { return }
        typealias SetColor = @convention(c) (NSObject, Selector, CGColor?) -> Void
        let imp = unsafeBitCast(effect.method(for: selector), to: SetColor.self)
        imp(effect, selector, updated)
    }

    private static func setHighlightColor(
        _ color: CGColor?,
        on effect: NSObject,
        setter: String
    ) {
        let selector = NSSelectorFromString(setter)
        guard effect.responds(to: selector) else { return }
        typealias SetColor = @convention(c) (NSObject, Selector, CGColor?) -> Void
        let imp = unsafeBitCast(effect.method(for: selector), to: SetColor.self)
        imp(effect, selector, color)
    }

    // MARK: - Diagnostics

    /// Textual dump of the glass's private layer tree, for diffing surfaces.
    static func diagnosticsReport(for glass: NSGlassEffectView, header: String) -> String {
        var lines: [String] = [header]
        let variant = describedValue(forKey: "_variant", on: glass)
        let subvariant = describedValue(forKey: "_subvariant", on: glass)
        lines.append(
            "glass: variant=\(variant) subvariant=\(subvariant)"
            + " frame=\(glass.frame) alphaValue=\(glass.alphaValue)"
        )
        if let root = glass.layer {
            appendLayerReport(root, depth: 1, into: &lines)
        } else {
            lines.append("  (no layer)")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendLayerReport(_ layer: CALayer, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let className = String(describing: type(of: layer))
        let frame = layer.frame
        var line = indent + "\(className) name=\(layer.name ?? "-")"
            + String(
                format: " frame=(%.1f, %.1f, %.1f×%.1f)",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
            + " opacity=\(layer.opacity)"
        if layer.masksToBounds { line += " CLIPS" }
        if layer.isHidden { line += " HIDDEN" }
        if layer.mask != nil { line += " MASKED" }
        if let keys = layer.animationKeys(), !keys.isEmpty { line += " anims=\(keys)" }
        if className == "CASDFLayer", let effect = effectObject(on: layer) {
            line += " effect=\(String(describing: type(of: effect)))"
            let interesting = ["keyAmount", "fillAmount", "keyHeight", "minimum", "maximum", "height"]
            var values = interesting.compactMap { key -> String? in
                guard effect.responds(to: NSSelectorFromString(key)),
                      let n = effect.value(forKey: key) as? NSNumber else { return nil }
                return "\(key)=\(String(format: "%.3f", n.doubleValue))"
            }
            if String(describing: type(of: effect)) == "CASDFKeyFillHighlightEffect" {
                if let alpha = highlightColor(effect, getter: "keyColor")?.alpha {
                    values.append("keyColorAlpha=\(String(format: "%.3f", alpha))")
                }
                if let alpha = highlightColor(effect, getter: "fillColor")?.alpha {
                    values.append("fillColorAlpha=\(String(format: "%.3f", alpha))")
                }
            }
            if !values.isEmpty { line += "(\(values.joined(separator: ",")))" }
        }
        if className == "CABackdropLayer" {
            let props = ["scale", "windowServerAware", "allowsInPlaceFiltering",
                         "groupName", "usesGlobalGroupNamespace", "tracksLuma",
                         "marginWidth", "zoom", "captureOnly", "reducesCaptureBitDepth"]
            let values = props.compactMap { key -> String? in
                valueIfResponds(forKey: key, on: layer).map { "\(key)=\($0)" }
            }
            line += " [" + values.joined(separator: " ") + "]"
        }
        lines.append(line)
        if let filters = layer.filters, !filters.isEmpty {
            for filter in filters {
                guard let filterObject = filter as? NSObject else { continue }
                let name = filterName(filterObject) ?? "nil"
                lines.append(indent + "  filter \(name):")
                for key in filterInputKeys(filterObject) {
                    let value = filterObject.value(forKey: key).map { "\($0)" } ?? "nil"
                    lines.append(indent + "    \(key) = \(value)")
                }
            }
        }
        for sublayer in layer.sublayers ?? [] {
            appendLayerReport(sublayer, depth: depth + 1, into: &lines)
        }
    }

    // MARK: - Recursive pass audit

    struct PassAuditRect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    struct PassAuditLayerRecord: Codable, Equatable {
        let path: String
        let layerClass: String
        let name: String?
        let frame: PassAuditRect
        let bounds: PassAuditRect
        let opacity: Double
        let isHidden: Bool
        let masksToBounds: Bool
        let cornerRadius: Double
        let hasMask: Bool
    }

    struct PassAuditPropertyRecord: Codable, Equatable {
        /// `value`, `nil`, or `unreadable`. Keeping this independent from the
        /// optional description distinguishes declared nil from absent keys.
        let state: String
        let value: String?
        let attributes: [String: String]
    }

    struct PassAuditPassRecord: Codable, Equatable {
        let id: String
        let layerPath: String
        let layerClass: String
        let location: String
        let objectClass: String
        let name: String?
        let properties: [String: PassAuditPropertyRecord]
    }

    struct PassAuditSnapshot: Codable, Equatable {
        let topologySignature: String
        let valueSignature: String
        let layers: [String: PassAuditLayerRecord]
        let passes: [String: PassAuditPassRecord]
    }

    /// Recursively inventories every known Core Animation pass location under
    /// NSGlassEffectView. Masks are separate layer trees rather than ordinary
    /// sublayers, so they receive an explicit structural path and cycle guard.
    @MainActor
    static func capturePassAuditSnapshot(
        from glass: NSGlassEffectView
    ) -> PassAuditSnapshot? {
        guard let root = glass.layer else { return nil }
        var layers: [String: PassAuditLayerRecord] = [:]
        var passes: [String: PassAuditPassRecord] = [:]
        var visited: Set<ObjectIdentifier> = []

        func visit(_ layer: CALayer, path: String) {
            guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
            let layerClass = String(describing: type(of: layer))
            layers[path] = PassAuditLayerRecord(
                path: path,
                layerClass: layerClass,
                name: layer.name,
                frame: PassAuditRect(layer.frame),
                bounds: PassAuditRect(layer.bounds),
                opacity: Double(layer.opacity),
                isHidden: layer.isHidden,
                masksToBounds: layer.masksToBounds,
                cornerRadius: Double(layer.cornerRadius),
                hasMask: layer.mask != nil
            )

            capturePassObjects(
                (layer.filters ?? []).compactMap { $0 as? NSObject },
                location: "filters",
                layerPath: path,
                layerClass: layerClass,
                into: &passes
            )
            capturePassObjects(
                (layer.backgroundFilters ?? []).compactMap { $0 as? NSObject },
                location: "backgroundFilters",
                layerPath: path,
                layerClass: layerClass,
                into: &passes
            )
            if let compositingFilter = layer.compositingFilter as? NSObject {
                capturePassObjects(
                    [compositingFilter],
                    location: "compositingFilter",
                    layerPath: path,
                    layerClass: layerClass,
                    into: &passes
                )
            }
            if let effect = effectObject(on: layer) {
                capturePassObjects(
                    [effect],
                    location: "effect",
                    layerPath: path,
                    layerClass: layerClass,
                    into: &passes
                )
            }

            for (index, child) in (layer.sublayers ?? []).enumerated() {
                let childClass = String(describing: type(of: child))
                visit(child, path: "\(path).sublayers[\(index)]:\(childClass)")
            }
            if let mask = layer.mask {
                let maskClass = String(describing: type(of: mask))
                visit(mask, path: "\(path).mask:\(maskClass)")
            }
        }

        let rootClass = String(describing: type(of: root))
        visit(root, path: "root:\(rootClass)")
        return makePassAuditSnapshot(layers: layers, passes: passes)
    }

    static func passAuditReport(
        _ snapshot: PassAuditSnapshot,
        header: String
    ) -> String {
        var lines = [
            header,
            "topologySignature=\(snapshot.topologySignature)",
            "valueSignature=\(snapshot.valueSignature)",
            "layers=\(snapshot.layers.count) passes=\(snapshot.passes.count)",
            "",
            "layers:",
        ]
        for key in snapshot.layers.keys.sorted() {
            guard let layer = snapshot.layers[key] else { continue }
            lines.append(
                "  \(key) · \(layer.layerClass)"
                    + String(
                        format: " · frame=(%.1f,%.1f,%.1f×%.1f)",
                        layer.frame.x,
                        layer.frame.y,
                        layer.frame.width,
                        layer.frame.height
                    )
                    + String(format: " · opacity=%.4g", layer.opacity)
                    + (layer.hasMask ? " · MASK" : "")
                    + (layer.isHidden ? " · HIDDEN" : "")
                    + (layer.masksToBounds ? " · CLIPS" : "")
            )
        }

        lines.append("")
        lines.append("passes:")
        let records = snapshot.passes.values.sorted {
            [$0.layerPath, $0.location, $0.objectClass, $0.name ?? "", $0.id]
                .joined(separator: "|")
                < [$1.layerPath, $1.location, $1.objectClass, $1.name ?? "", $1.id]
                .joined(separator: "|")
        }
        for pass in records {
            lines.append(
                "  \(pass.location) · \(pass.name ?? pass.objectClass)"
                    + " · class=\(pass.objectClass)"
                    + " · owner=\(pass.layerClass)"
            )
            lines.append("    locator=\(pass.layerPath)")
            for key in pass.properties.keys.sorted() {
                guard let property = pass.properties[key] else { continue }
                let attributes = property.attributes.keys.sorted().map {
                    "\($0)=\(property.attributes[$0]!)"
                }.joined(separator: ", ")
                lines.append(
                    "    \(key) [\(property.state)] = \(property.value ?? "<nil>")"
                        + (attributes.isEmpty ? "" : " {\(attributes)}")
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func capturePassObjects(
        _ objects: [NSObject],
        location: String,
        layerPath: String,
        layerClass: String,
        into passes: inout [String: PassAuditPassRecord]
    ) {
        for (index, object) in objects.enumerated() {
            let objectClass = String(describing: type(of: object))
            // `CALayer.compositingFilter` may be a filter-name NSString rather
            // than a CAFilter instance. Preserve that authored value instead
            // of exporting only its bridged `__NSCFConstantString` class.
            let name = filterName(object)
                ?? (object as? NSString).map { $0 as String }
            let id = "\(layerPath)|\(location)[\(index)]|\(objectClass)|\(name ?? "-")"
            let properties = location == "effect"
                ? captureEffectProperties(on: object)
                : captureFilterProperties(on: object)
            passes[id] = PassAuditPassRecord(
                id: id,
                layerPath: layerPath,
                layerClass: layerClass,
                location: "\(location)[\(index)]",
                objectClass: objectClass,
                name: name,
                properties: properties
            )
        }
    }

    private static func captureFilterProperties(
        on filter: NSObject
    ) -> [String: PassAuditPropertyRecord] {
        let selector = NSSelectorFromString("attributesForKeyPath:")
        return Dictionary(uniqueKeysWithValues: filterInputKeys(filter).sorted().map { key in
            let value = filter.value(forKey: key)
            let attributes: [String: String]
            if filter.responds(to: selector),
               let raw = filter.perform(selector, with: key)?.takeUnretainedValue()
                    as? [String: Any] {
                attributes = stableMetadata(raw)
            } else {
                attributes = [:]
            }
            return (
                key,
                PassAuditPropertyRecord(
                    state: value == nil ? "nil" : "value",
                    value: value.map { stableDescription($0) },
                    attributes: attributes
                )
            )
        })
    }

    private static func captureEffectProperties(
        on effect: NSObject
    ) -> [String: PassAuditPropertyRecord] {
        guard let table = objectFromClassMethod(
            on: type(of: effect),
            selectorName: "CA_attributes"
        ) as? [String: Any] else { return [:] }

        return Dictionary(uniqueKeysWithValues: table.keys.sorted().map { key in
            let getter = NSSelectorFromString(key)
            let readable = effect.responds(to: getter)
            let value = readable ? effect.value(forKey: key) : nil
            let rawAttributes = table[key] as? [String: Any] ?? [:]
            return (
                key,
                PassAuditPropertyRecord(
                    state: readable ? (value == nil ? "nil" : "value") : "unreadable",
                    value: value.map { stableDescription($0) },
                    attributes: stableMetadata(rawAttributes)
                )
            )
        })
    }

    private static func stableMetadata(_ metadata: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: metadata.keys.sorted().map {
            ($0, stableDescription(metadata[$0]!))
        })
    }

    private static func stableDescription(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return String(format: "%.17g", number.doubleValue)
        }
        if let string = value as? String {
            return string
        }
        let cfValue = value as CFTypeRef
        if CFGetTypeID(cfValue) == CGColor.typeID {
            let color = unsafeBitCast(cfValue, to: CGColor.self)
            let model = colorSpaceModelName(color.colorSpace?.model)
            let components = (color.components ?? [])
                .map { String(format: "%.6g", Double($0)) }
                .joined(separator: ",")
            return "CGColor(\(model):[\(components)])"
        }
        if let array = value as? [Any] {
            return "[" + array.map { stableDescription($0) }.joined(separator: ",") + "]"
        }
        if let dictionary = value as? [String: Any] {
            return "{" + dictionary.keys.sorted().map {
                "\($0):\(stableDescription(dictionary[$0]!))"
            }.joined(separator: ",") + "}"
        }
        if let value = value as? NSValue {
            return value.description
        }
        if let object = value as? NSObject {
            return "<\(String(describing: type(of: object)))>"
        }
        return String(describing: value)
    }

    private static func colorSpaceModelName(_ model: CGColorSpaceModel?) -> String {
        guard let rawValue = model?.rawValue else { return "unknown" }
        switch rawValue {
        case -1: return "unknown"
        case 0: return "monochrome"
        case 1: return "rgb"
        case 2: return "cmyk"
        case 3: return "lab"
        case 4: return "deviceN"
        case 5: return "indexed"
        case 6: return "pattern"
        case 7: return "xyz"
        default: return "model-\(rawValue)"
        }
    }

    private static func makePassAuditSnapshot(
        layers: [String: PassAuditLayerRecord],
        passes: [String: PassAuditPassRecord]
    ) -> PassAuditSnapshot {
        let topology = layers.keys.sorted().map { key in
            let layer = layers[key]!
            return "layer|\(key)|\(layer.layerClass)|mask=\(layer.hasMask)"
        } + passes.keys.sorted().map { key in
            let pass = passes[key]!
            return "pass|\(key)|keys=\(pass.properties.keys.sorted().joined(separator: ","))"
        }
        struct ValuePayload: Encodable {
            let layers: [String: PassAuditLayerRecord]
            let passes: [String: PassAuditPassRecord]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let valueData = try! encoder.encode(ValuePayload(layers: layers, passes: passes))
        return PassAuditSnapshot(
            topologySignature: sha256(Data(topology.joined(separator: "\n").utf8)),
            valueSignature: sha256(valueData),
            layers: layers,
            passes: passes
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recipe matrix capture

    struct MatrixEntry: Codable {
        struct PointValue: Codable, Equatable {
            let x: Double
            let y: Double
        }

        let context: String
        let appActive: Bool
        let isActualKeyWindow: Bool
        let isActualMainWindow: Bool
        let participation: String
        let requestedMain: Bool
        let subdued: Bool
        let glassWidth: Double
        let glassHeight: Double
        let cornerRadius: Double
        let variant: Int
        let subvariant: String?
        /// Capability inventory is separate from the sparse value maps:
        /// a listed key with no value is nil; an unlisted key is absent.
        let hasShaderPass: Bool
        let shaderInputKeys: [String]
        /// Backward-compatible name for the numeric glassBackground payload.
        let inputs: [String: Double]
        let shaderColors: [String: String]
        let shaderPoints: [String: PointValue]
        let shaderStrings: [String: String]
        let hasHighlightPass: Bool
        let highlightInputKeys: [String]
        let highlight: [String: Double]
        let highlightColors: [String: String]
        let geometryKeys: [String]
        let geometry: [String: Double]
    }

    /// Versioned export envelope used by repository Golden Standards. Axes
    /// describe what was swept; Environment records fixed provenance without
    /// multiplying verified non-Recipe controls into the Cartesian product.
    struct MatrixDocument: Codable {
        struct Axes: Codable {
            struct SizeSample: Codable {
                let width: Double
                let height: Double
                let cornerRadius: Double
            }

            let main: [Bool]
            let subdued: [Bool]
            let variants: [Int]
            let subvariants: [String?]
            let sizes: [SizeSample]
        }

        struct Environment: Codable {
            let hostType: String
            let windowMargin: Double
            let scrim: Bool
            let reducedTintOpacity: Bool
            let adaptiveAppearance: Int
            let tint: String?
            let overridesEnabled: Bool
        }

        let schemaVersion: Int
        let capturedAt: String
        let operatingSystem: String
        let axes: Axes
        let environment: Environment
        let entries: [MatrixEntry]
    }

    struct PassAuditEntry: Codable {
        let context: String
        let appActive: Bool
        let isActualKeyWindow: Bool
        let isActualMainWindow: Bool
        let participation: String
        let requestedMain: Bool
        let subdued: Bool
        let glassWidth: Double
        let glassHeight: Double
        let cornerRadius: Double
        let variant: Int
        let subvariant: String?
        let snapshot: PassAuditSnapshot
    }

    struct PassAuditDocument: Codable {
        struct Axes: Codable {
            let main: [Bool]
            let subdued: [Bool]
            let variants: [Int]
            let subvariants: [String?]
        }

        struct Context: Codable {
            let hostType: String
            let windowMargin: Double
            let glassWidth: Double
            let glassHeight: Double
            let cornerRadius: Double
            let scrim: Bool
            let reducedTintOpacity: Bool
            let adaptiveAppearance: Int
            let tint: String?
            let overridesEnabled: Bool
        }

        let formatVersion: Int
        let capturedAt: String
        let operatingSystem: String
        let axes: Axes
        let context: Context
        let entries: [PassAuditEntry]
    }

    enum MatrixCaptureError: Error {
        case applicationInactive
        case missingLayerTree
        case participationChanged(
            expectedMain: Bool,
            actualMain: Bool,
            actualKey: Bool
        )
    }

    /// One fully typed snapshot used both for adaptive stability detection and
    /// the final MatrixEntry. Reusing the settled payload avoids traversing the
    /// private layer/filter tree a second time for every Cartesian-product cell.
    private struct MatrixPayload: Equatable {
        let hasShaderPass: Bool
        let shaderInputKeys: [String]
        let inputs: [String: Double]
        let shaderColors: [String: String]
        let shaderPoints: [String: MatrixEntry.PointValue]
        let shaderStrings: [String: String]
        let hasHighlightPass: Bool
        let highlightInputKeys: [String]
        let highlight: [String: Double]
        let highlightColors: [String: String]
        let geometryKeys: [String]
        let geometry: [String: Double]
    }

    /// Captures the fixed-geometry recursive pass audit for one accepted
    /// Main/Subdued context. The caller owns the outer four-context loop so a
    /// context interrupted by application deactivation can be retried whole.
    @MainActor
    static func capturePassAudit(
        on glass: NSGlassEffectView,
        context: String,
        requestedMain: Bool,
        subdued: Bool,
        restoring state: GlassLabState
    ) async throws -> [PassAuditEntry] {
        var entries: [PassAuditEntry] = []

        defer {
            setGuarded(nil, forKey: "_subvariant", on: glass)
            setGuarded(state.variant == 0 ? 1 : 0, forKey: "_variant", on: glass)
            applyRecipe(from: state, to: glass)
        }

        let subvariants: [String?] = [nil] + knownSubvariants.map(Optional.some)
        for variant in variants {
            for subvariant in subvariants {
                guard NSApp.isActive else {
                    throw MatrixCaptureError.applicationInactive
                }
                selectRecipeCell(variant: variant, subvariant: subvariant, on: glass)
                refreshResolvedWindowContext(on: glass)
                let snapshot = try await settledPassAuditSnapshot(from: glass)
                let actualKey = glass.window.map { NSApp.keyWindow === $0 } ?? false
                let actualMain = glass.window.map { NSApp.mainWindow === $0 } ?? false
                guard NSApp.isActive else {
                    throw MatrixCaptureError.applicationInactive
                }
                guard actualMain == requestedMain, !actualKey else {
                    throw MatrixCaptureError.participationChanged(
                        expectedMain: requestedMain,
                        actualMain: actualMain,
                        actualKey: actualKey
                    )
                }
                entries.append(PassAuditEntry(
                    context: context,
                    appActive: NSApp.isActive,
                    isActualKeyWindow: actualKey,
                    isActualMainWindow: actualMain,
                    participation: actualKey ? "key" : (actualMain ? "main" : "neither"),
                    requestedMain: requestedMain,
                    subdued: subdued,
                    glassWidth: state.glassWidth,
                    glassHeight: state.glassHeight,
                    cornerRadius: state.cornerRadius,
                    variant: variant,
                    subvariant: subvariant,
                    snapshot: snapshot
                ))
            }
        }
        return entries
    }

    @MainActor
    private static func settledPassAuditSnapshot(
        from glass: NSGlassEffectView
    ) async throws -> PassAuditSnapshot {
        var previous: PassAuditSnapshot?
        var elapsedMilliseconds = 0
        for delayMilliseconds in [30, 30, 30, 30, 60] {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard NSApp.isActive else {
                throw MatrixCaptureError.applicationInactive
            }
            elapsedMilliseconds += delayMilliseconds
            glass.needsLayout = true
            glass.layoutSubtreeIfNeeded()
            CATransaction.flush()
            guard let current = capturePassAuditSnapshot(from: glass) else {
                continue
            }
            if elapsedMilliseconds >= 60, current == previous {
                return current
            }
            previous = current
        }
        guard let previous else { throw MatrixCaptureError.missingLayerTree }
        return previous
    }

    private static func selectRecipeCell(
        variant: Int,
        subvariant: String?,
        on glass: NSGlassEffectView
    ) {
        // Clear both axes first so an unchanged setter cannot leave a recipe
        // resolved from the previous Cartesian-product cell.
        setGuarded(nil, forKey: "_subvariant", on: glass)
        setGuarded(variant == 0 ? 1 : 0, forKey: "_variant", on: glass)
        setGuarded(variant, forKey: "_variant", on: glass)
        setGuarded(subvariant, forKey: "_subvariant", on: glass)
    }

    /// Sweeps the full Cartesian product of every integer variant and each
    /// known subvariant state (`nil`, menu, sheet, camera), then restores the
    /// original recipe. This intentionally records combinations that collapse
    /// to the same output: storage is orthogonal, recipe consumption is sparse.
    /// The real key/main participation of `glass.window` is part of what is
    /// being measured, so run once per surface.
    @MainActor
    static func captureMatrix(
        on glass: NSGlassEffectView,
        context: String,
        requestedMain: Bool,
        subdued: Bool,
        restoring state: GlassLabState
    ) async throws -> [MatrixEntry] {
        var entries: [MatrixEntry] = []

        defer {
            // Restore the state's recipe (bounce so the setter can't
            // short-circuit back into a stale resolution), including when an
            // inactive/context transition aborts this batch for a clean retry.
            setGuarded(nil, forKey: "_subvariant", on: glass)
            setGuarded(state.variant == 0 ? 1 : 0, forKey: "_variant", on: glass)
            applyRecipe(from: state, to: glass)
        }

        let subvariants: [String?] = [nil] + knownSubvariants.map(Optional.some)
        for variant in variants {
            for subvariant in subvariants {
                guard NSApp.isActive else {
                    throw MatrixCaptureError.applicationInactive
                }
                selectRecipeCell(variant: variant, subvariant: subvariant, on: glass)
                // The resolver normally reacts asynchronously. Explicitly run
                // its window-context hook, then retain the 180 ms historical
                // wait only as a ceiling rather than paying it for every cell.
                refreshResolvedWindowContext(on: glass)
                let payload = try await settledMatrixPayload(from: glass)
                let actualKey = glass.window.map { NSApp.keyWindow === $0 } ?? false
                let actualMain = glass.window.map { NSApp.mainWindow === $0 } ?? false
                guard NSApp.isActive else {
                    throw MatrixCaptureError.applicationInactive
                }
                guard actualMain == requestedMain, !actualKey else {
                    throw MatrixCaptureError.participationChanged(
                        expectedMain: requestedMain,
                        actualMain: actualMain,
                        actualKey: actualKey
                    )
                }
                entries.append(MatrixEntry(
                    context: context,
                    appActive: NSApp.isActive,
                    isActualKeyWindow: actualKey,
                    isActualMainWindow: actualMain,
                    participation: actualKey ? "key" : (actualMain ? "main" : "neither"),
                    requestedMain: requestedMain,
                    subdued: subdued,
                    glassWidth: state.glassWidth,
                    glassHeight: state.glassHeight,
                    cornerRadius: state.cornerRadius,
                    variant: variant,
                    subvariant: subvariant,
                    hasShaderPass: payload.hasShaderPass,
                    shaderInputKeys: payload.shaderInputKeys,
                    inputs: payload.inputs,
                    shaderColors: payload.shaderColors,
                    shaderPoints: payload.shaderPoints,
                    shaderStrings: payload.shaderStrings,
                    hasHighlightPass: payload.hasHighlightPass,
                    highlightInputKeys: payload.highlightInputKeys,
                    highlight: payload.highlight,
                    highlightColors: payload.highlightColors,
                    geometryKeys: payload.geometryKeys,
                    geometry: payload.geometry
                ))
            }
        }
        return entries
    }

    /// Samples after 30 ms checkpoints and returns once two snapshots are
    /// identical after at least 60 ms. Most recipes settle in that first pair;
    /// unstable cells continue through the former 180 ms safety boundary.
    @MainActor
    private static func settledMatrixPayload(
        from glass: NSGlassEffectView
    ) async throws -> MatrixPayload {
        var previous: MatrixPayload?
        var elapsedMilliseconds = 0
        for delayMilliseconds in [30, 30, 30, 30, 60] {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard NSApp.isActive else {
                throw MatrixCaptureError.applicationInactive
            }
            elapsedMilliseconds += delayMilliseconds
            glass.needsLayout = true
            glass.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let current = captureMatrixPayload(from: glass)
            if elapsedMilliseconds >= 60, current == previous {
                return current
            }
            previous = current
        }
        return previous ?? captureMatrixPayload(from: glass)
    }

    @MainActor
    private static func captureMatrixPayload(
        from glass: NSGlassEffectView
    ) -> MatrixPayload {
        let shaderInputKeys = captureShaderInputKeys(from: glass)
        let highlightInputKeys = captureHighlightInputKeys(from: glass)
        return MatrixPayload(
            hasShaderPass: shaderInputKeys != nil,
            shaderInputKeys: shaderInputKeys.map { $0.sorted() } ?? [],
            inputs: captureShaderInputs(from: glass),
            shaderColors: captureShaderColors(from: glass).mapValues(colorDescription),
            shaderPoints: captureShaderPoints(from: glass).mapValues {
                MatrixEntry.PointValue(x: $0.x, y: $0.y)
            },
            shaderStrings: captureShaderStrings(from: glass),
            hasHighlightPass: highlightInputKeys != nil,
            highlightInputKeys: highlightInputKeys.map { $0.sorted() } ?? [],
            highlight: captureHighlightValues(from: glass),
            highlightColors: captureHighlightColors(from: glass).mapValues(colorDescription),
            geometryKeys: captureLayerGeometryKeys(from: glass).sorted(),
            geometry: captureLayerGeometry(from: glass)
        )
    }

    private static func colorDescription(_ color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else { return color.description }
        return String(
            format: "rgba(%.6g,%.6g,%.6g,%.6g)",
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent
        )
    }
}
#endif
