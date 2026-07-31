//
//  GlassMaterialAccess.swift
//  GlassMaterial
//
//  The minimum private-API surface the strength curve needs. Deliberately
//  self-contained: this directory has no dependency on the rest of Liquid
//  Glass Lab, so it can be lifted into another project as-is.
//
//  Every entry point is defensive. AppKit owns this layer tree and can rebuild
//  or rename it across releases, so a missing layer, filter, or key returns nil
//  or is skipped rather than trapping.
//

#if os(macOS)
import AppKit

@available(macOS 26.0, *)
enum GlassMaterialAccess {
    struct GlassBackgroundTarget {
        let layer: CALayer
        let filter: NSObject
        let name: String
        let inputKeys: Set<String>

        var identity: ObjectIdentifier { ObjectIdentifier(filter) }
    }

    // MARK: Layer discovery

    /// The `CABackdropLayer` carrying the glass shader. Only exists once the
    /// hosted glass has laid out at least one time.
    static func backdropLayer(under glass: NSGlassEffectView) -> CALayer? {
        glass.layer.flatMap { firstLayer(className: "CABackdropLayer", under: $0) }
    }

    /// Every `CASDFLayer` whose effect is the key-fill highlight (rim) pass.
    static func rimLayers(under glass: NSGlassEffectView) -> [CALayer] {
        guard let root = glass.layer else { return [] }
        var found: [CALayer] = []
        collectRimLayers(under: root, into: &found)
        return found
    }

    private static func firstLayer(
        className: String,
        under layer: CALayer
    ) -> CALayer? {
        if String(describing: type(of: layer)) == className { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let match = firstLayer(className: className, under: sublayer) {
                return match
            }
        }
        return nil
    }

    private static func collectRimLayers(
        under layer: CALayer,
        into found: inout [CALayer]
    ) {
        if String(describing: type(of: layer)) == "CASDFLayer",
           let effect = valueIfResponds(forKey: "effect", on: layer) as? NSObject,
           String(describing: type(of: effect)) == "CASDFKeyFillHighlightEffect" {
            found.append(layer)
        }
        for sublayer in layer.sublayers ?? [] {
            collectRimLayers(under: sublayer, into: &found)
        }
    }

    // MARK: Filter access

    static func glassBackgroundFilter(on layer: CALayer) -> NSObject? {
        (layer.filters as? [NSObject])?.first { filterName($0) == "glassBackground" }
    }

    static func glassBackgroundFilterIdentity(
        on layer: CALayer
    ) -> ObjectIdentifier? {
        glassBackgroundFilter(on: layer).map(ObjectIdentifier.init)
    }

    static func filterName(_ filter: NSObject) -> String? {
        valueIfResponds(forKey: "name", on: filter) as? String
    }

    /// Runtime `inputKeys` is the authoritative capability list. Each target
    /// snapshots it once per refresh/frame, then every read and write consults
    /// that snapshot.
    static func filterInputKeys(_ filter: NSObject) -> [String] {
        valueIfResponds(forKey: "inputKeys", on: filter) as? [String] ?? []
    }

    /// Resolves the mutable owner, filter identity, name, and capabilities
    /// once per refresh/frame. Repeating this lookup for every channel makes a
    /// 42-channel strength update pay for 42 tree scans and `inputKeys` reads.
    static func glassBackgroundTarget(
        under glass: NSGlassEffectView
    ) -> GlassBackgroundTarget? {
        guard let layer = backdropLayer(under: glass),
              let filter = glassBackgroundFilter(on: layer),
              let name = filterName(filter) else { return nil }
        return GlassBackgroundTarget(
            layer: layer,
            filter: filter,
            name: name,
            inputKeys: Set(filterInputKeys(filter))
        )
    }

    /// Every numeric input of the glass shader: the resolved Recipe.
    static func readNumbers(
        from target: GlassBackgroundTarget
    ) -> [String: Double] {
        var values: [String: Double] = [:]
        for key in target.inputKeys {
            if let number = target.filter.value(forKey: key) as? NSNumber {
                values[key] = number.doubleValue
            }
        }
        return values
    }

    struct TypedInputs {
        var numeric: [String: Double] = [:]
        var colors: [String: NSColor] = [:]
        var points: [String: CGPoint] = [:]
        var nilKeys: Set<String> = []
    }

    /// Every declared input, classified by resolved type. Strings stay
    /// read-only diagnostics; a key that resolves nil is recorded as such,
    /// because replaying a captured nil over a nonnil value needs an explicit
    /// clear rather than "key absent, do not write".
    static func readTypedInputs(
        from target: GlassBackgroundTarget
    ) -> TypedInputs {
        var inputs = TypedInputs()
        for key in target.inputKeys {
            guard let raw = target.filter.value(forKey: key) else {
                inputs.nilKeys.insert(key)
                continue
            }
            if let number = raw as? NSNumber {
                inputs.numeric[key] = number.doubleValue
            } else if CFGetTypeID(raw as CFTypeRef) == CGColor.typeID {
                // swiftlint:disable:next force_cast
                if let color = NSColor(cgColor: raw as! CGColor) {
                    inputs.colors[key] = color
                }
            } else if let value = raw as? NSValue {
                // `inputShadowOffset` resolves as an NSSize-encoded NSValue on
                // both captured systems; a point encoding is accepted too.
                // Either way the pair is stored as a CGPoint and re-boxed to
                // the destination's own encoding on write.
                let encoding = String(cString: value.objCType)
                if encoding.hasPrefix("{CGPoint") {
                    inputs.points[key] = value.pointValue
                } else if encoding.hasPrefix("{CGSize") {
                    let size = value.sizeValue
                    inputs.points[key] = CGPoint(x: size.width, y: size.height)
                }
            }
        }
        return inputs
    }

    /// Boxes a captured pair to match the destination's current encoding, so
    /// a size-typed input is never handed a point-typed NSValue. Falls back to
    /// the size encoding both accepted fixtures resolve.
    static func writePair(
        _ pair: CGPoint,
        forKey key: String,
        to target: GlassBackgroundTarget
    ) {
        guard target.inputKeys.contains(key) else { return }
        let current = target.filter.value(forKey: key) as? NSValue
        let boxed: NSValue
        if let current, String(cString: current.objCType).hasPrefix("{CGPoint") {
            boxed = NSValue(point: pair)
        } else {
            boxed = NSValue(size: NSSize(width: pair.x, height: pair.y))
        }
        write(boxed, forKey: key, to: target)
    }

    static func readColors(
        from target: GlassBackgroundTarget,
        keys: [String]
    ) -> [String: NSColor] {
        var values: [String: NSColor] = [:]
        for key in keys where target.inputKeys.contains(key) {
            guard let raw = target.filter.value(forKey: key),
                  CFGetTypeID(raw as CFTypeRef) == CGColor.typeID else { continue }
            // swiftlint:disable:next force_cast
            guard let color = NSColor(cgColor: raw as! CGColor) else { continue }
            values[key] = color
        }
        return values
    }

    /// Filter objects attached to a layer are immutable. Per CAFilter's
    /// contract writes must go through the owning layer with a
    /// `filters.<name>.<key>` key path; writing to the filter object is a
    /// silent no-op.
    static func write(
        _ value: Any?,
        forKey key: String,
        to target: GlassBackgroundTarget
    ) {
        guard target.inputKeys.contains(key) else { return }
        target.layer.setValue(
            value,
            forKeyPath: "filters.\(target.name).\(key)"
        )
    }

    // MARK: Render bounds

    /// `CABackdropLayer.marginWidth`, the room the backdrop reserves for
    /// passes that draw outside the outline. Both participation- and
    /// size-dependent: a flat context resolves 0.5 where Main-On resolves
    /// `0.35 · shortSide` (floored at 16).
    static func marginWidth(under glass: NSGlassEffectView) -> Double? {
        guard let layer = backdropLayer(under: glass) else { return nil }
        return (valueIfResponds(forKey: "marginWidth", on: layer) as? NSNumber)?
            .doubleValue
    }

    static func setMarginWidth(_ width: Double, under glass: NSGlassEffectView) {
        guard let layer = backdropLayer(under: glass),
              layer.responds(to: NSSelectorFromString("setMarginWidth:"))
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(width, forKey: "marginWidth")
        CATransaction.commit()
    }

    /// The `CASDFOutputEffect` render bounds. Without them the transplanted
    /// outer passes hard-clip at the outline.
    static func outputBounds(
        under glass: NSGlassEffectView
    ) -> (minimum: Double, maximum: Double)? {
        guard let (_, effect) = outputEffect(under: glass),
              let minimum = (valueIfResponds(forKey: "minimum", on: effect)
                as? NSNumber)?.doubleValue,
              let maximum = (valueIfResponds(forKey: "maximum", on: effect)
                as? NSNumber)?.doubleValue
        else { return nil }
        return (minimum, maximum)
    }

    static func setOutputBounds(
        minimum: Double,
        maximum: Double,
        under glass: NSGlassEffectView
    ) {
        guard let (layer, effect) = outputEffect(under: glass) else { return }
        mutateEffectCopy(effect, on: layer) { copy in
            copy.setValue(minimum, forKey: "minimum")
            copy.setValue(maximum, forKey: "maximum")
        }
    }

    private static func outputEffect(
        under glass: NSGlassEffectView
    ) -> (layer: CALayer, effect: NSObject)? {
        guard let root = glass.layer else { return nil }
        var found: (CALayer, NSObject)?
        findEffect(className: "CASDFOutputEffect", under: root, into: &found)
        return found
    }

    private static func findEffect(
        className: String,
        under layer: CALayer,
        into found: inout (CALayer, NSObject)?
    ) {
        guard found == nil else { return }
        if let effect = valueIfResponds(forKey: "effect", on: layer) as? NSObject,
           String(describing: type(of: effect)) == className {
            found = (layer, effect)
            return
        }
        for sublayer in layer.sublayers ?? [] {
            findEffect(className: className, under: sublayer, into: &found)
        }
    }

    /// SDF effect objects attached to a layer are immutable in place: the
    /// accepted mutation contract is copy, mutate the copy, reassign
    /// `layer.effect`.
    private static func mutateEffectCopy(
        _ effect: NSObject,
        on layer: CALayer,
        _ mutate: (NSObject) -> Void
    ) {
        guard let copying = effect as? NSCopying,
              let copy = copying.copy(with: nil) as? NSObject else { return }
        mutate(copy)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(copy, forKey: "effect")
        CATransaction.commit()
    }

    // MARK: Rim gate and payload

    static func rimOpacity(of layer: CALayer) -> Double {
        Double(layer.opacity)
    }

    /// The declared value keys of `CASDFKeyFillHighlightEffect`, from the
    /// accepted recursive audits. Reads are `responds`-guarded, so a key this
    /// build does not declare is skipped rather than trapped on.
    private static let rimValueKeys = [
        "curvature", "diffuseAmountScale", "diffuseHeightScale",
        "diffuseSpreadScale", "fillAmount", "fillAngle", "fillColorAlpha",
        "fillHeight", "fillHeightOffset", "fillHeightScale", "fillSpread",
        "fillSpreadOffset", "fillSpreadScale", "global", "keyAmount",
        "keyAngle", "keyColorAlpha", "keyHeight", "keyHeightOffset",
        "keyHeightScale", "keySpread", "keySpreadOffset", "keySpreadScale",
    ]
    static let rimColorKeys = ["fillColor", "keyColor"]

    /// The rim effect's complete value/color payload. A flat context resolves
    /// zero-alpha rim colors, so opening the gate without restamping the
    /// payload leaves the highlight invisible.
    static func rimPayload(
        on layer: CALayer
    ) -> (values: [String: Double], colors: [String: NSColor])? {
        guard let effect = valueIfResponds(forKey: "effect", on: layer)
            as? NSObject else { return nil }
        var values: [String: Double] = [:]
        for key in rimValueKeys {
            // A getter this build does not declare is skipped; a declared
            // getter that fails to produce a number fails the capture — the
            // all-or-nothing contract, so replay never leaves an omitted
            // effect property at the destination context's value.
            guard effect.responds(to: NSSelectorFromString(key)) else {
                continue
            }
            guard let number = effect.value(forKey: key) as? NSNumber else {
                return nil
            }
            values[key] = number.doubleValue
        }
        guard !values.isEmpty else { return nil }
        var colors: [String: NSColor] = [:]
        for key in rimColorKeys {
            // Both colors are part of the completeness contract: a payload
            // missing either would later open a rim whose omitted color stays
            // at the destination's zero-alpha value.
            guard let cgColor = effectColor(effect, getter: key),
                  let color = NSColor(cgColor: cgColor) else { return nil }
            colors[key] = color
        }
        return (values, colors)
    }

    /// True when the layer's current rim payload already equals this one.
    /// Writing a rim payload replaces the SDF effect object, and AppKit
    /// reacts to that replacement by re-deriving `CABackdropLayer.marginWidth`
    /// for the window's *real* participation on the next cycle — so a frozen
    /// apply must not replace an effect that already carries its values, or
    /// every G scrub re-triggers that reaction and the margin restamp can
    /// never be the final writer.
    static func rimPayloadMatches(
        values: [String: Double],
        colors: [String: NSColor],
        on layer: CALayer
    ) -> Bool {
        guard let current = rimPayload(on: layer) else { return false }
        guard current.values.count == values.count,
              current.colors.count == colors.count else { return false }
        for (key, value) in values {
            guard let existing = current.values[key],
                  abs(existing - value) < 1e-6 else { return false }
        }
        for (key, color) in colors {
            guard let existing = current.colors[key],
                  colorsMatch(existing, color) else { return false }
        }
        return true
    }

    static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let aRGB = a.usingColorSpace(.extendedSRGB),
              let bRGB = b.usingColorSpace(.extendedSRGB) else { return false }
        return abs(aRGB.redComponent - bRGB.redComponent) < 1e-4
            && abs(aRGB.greenComponent - bRGB.greenComponent) < 1e-4
            && abs(aRGB.blueComponent - bRGB.blueComponent) < 1e-4
            && abs(aRGB.alphaComponent - bRGB.alphaComponent) < 1e-4
    }

    static func setRimPayload(
        values: [String: Double],
        colors: [String: NSColor],
        on layer: CALayer
    ) {
        guard let effect = valueIfResponds(forKey: "effect", on: layer)
            as? NSObject else { return }
        mutateEffectCopy(effect, on: layer) { copy in
            for (key, value) in values where hasSetter(for: key, on: copy) {
                copy.setValue(value, forKey: key)
            }
            for (key, color) in colors {
                setEffectColor(color.cgColor, on: copy, key: key)
            }
        }
    }

    private static func hasSetter(for key: String, on object: NSObject) -> Bool {
        object.responds(to: NSSelectorFromString(setterName(for: key)))
    }

    private static func setterName(for key: String) -> String {
        guard let first = key.first else { return key }
        return "set\(first.uppercased())\(key.dropFirst()):"
    }

    /// The rim color properties are raw `CGColorRef`s, which KVC cannot box —
    /// reads and writes go through typed IMPs, per the accepted mutation
    /// contract.
    private static func effectColor(
        _ effect: NSObject,
        getter: String
    ) -> CGColor? {
        let selector = NSSelectorFromString(getter)
        guard effect.responds(to: selector) else { return nil }
        typealias GetColor = @convention(c) (NSObject, Selector)
            -> Unmanaged<CGColor>?
        let imp = unsafeBitCast(effect.method(for: selector), to: GetColor.self)
        return imp(effect, selector)?.takeUnretainedValue()
    }

    private static func setEffectColor(
        _ color: CGColor?,
        on effect: NSObject,
        key: String
    ) {
        let selector = NSSelectorFromString(setterName(for: key))
        guard effect.responds(to: selector) else { return }
        typealias SetColor = @convention(c) (NSObject, Selector, CGColor?) -> Void
        let imp = unsafeBitCast(effect.method(for: selector), to: SetColor.self)
        imp(effect, selector, color)
    }

    /// The rim gate is system-animated. A leftover property animation pins the
    /// rendered value regardless of the model write, so stamping removes any
    /// animation targeting opacity or the effect inside a no-actions
    /// transaction.
    static func setRimOpacity(_ opacity: Double, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) else { continue }
            if animationTargetsGate(animation) {
                layer.removeAnimation(forKey: key)
            }
        }
        layer.opacity = Float(opacity)
        CATransaction.commit()
    }

    private static func animationTargetsGate(_ animation: CAAnimation) -> Bool {
        if let keyPath = (animation as? CAPropertyAnimation)?.keyPath {
            if keyPath == "opacity" || keyPath == "effect"
                || keyPath.hasPrefix("effect.") {
                return true
            }
        }
        if let group = animation as? CAAnimationGroup {
            for child in group.animations ?? [] {
                if animationTargetsGate(child) { return true }
            }
        }
        return false
    }

    // MARK: Color matrices

    /// Public Tint is topology, not a `glassBackground` field: a nonnil tint
    /// inserts its own branch whose `vibrantColorMatrix` shares an owner path
    /// with a `CASDFGradientEffect`. That shared path is how the Tint matrix is
    /// told apart from the untinted Content and Rim matrices.
    static func tintMatrixLayer(under glass: NSGlassEffectView) -> CALayer? {
        guard let root = glass.layer else { return nil }
        var found: CALayer?
        findTintMatrixLayer(under: root, into: &found)
        return found
    }

    private static func findTintMatrixLayer(
        under layer: CALayer,
        into found: inout CALayer?
    ) {
        guard found == nil else { return }
        if let effect = valueIfResponds(forKey: "effect", on: layer) as? NSObject,
           String(describing: type(of: effect)) == "CASDFGradientEffect",
           let filters = layer.filters as? [NSObject],
           filters.contains(where: { filterName($0) == "vibrantColorMatrix" }) {
            found = layer
            return
        }
        for sublayer in layer.sublayers ?? [] {
            findTintMatrixLayer(under: sublayer, into: &found)
        }
    }

    /// The untinted Content and Rim `vibrantColorMatrix` owners, in
    /// deterministic depth-first order. The transition never animates these,
    /// but the resolver re-grades them per appearance/participation, so a
    /// frozen style has to restamp them alongside the `glassBackground` vector.
    static func untintedMatrixLayers(under glass: NSGlassEffectView) -> [CALayer] {
        guard let root = glass.layer else { return [] }
        var found: [CALayer] = []
        collectUntintedMatrixLayers(under: root, into: &found)
        return found
    }

    private static func collectUntintedMatrixLayers(
        under layer: CALayer,
        into found: inout [CALayer]
    ) {
        if let filters = layer.filters as? [NSObject],
           filters.contains(where: { filterName($0) == "vibrantColorMatrix" }) {
            let ownsGradientEffect = (
                valueIfResponds(forKey: "effect", on: layer) as? NSObject
            ).map { String(describing: type(of: $0)) == "CASDFGradientEffect" }
                ?? false
            if !ownsGradientEffect { found.append(layer) }
        }
        for sublayer in layer.sublayers ?? [] {
            collectUntintedMatrixLayers(under: sublayer, into: &found)
        }
    }

    /// The scalar/Boolean inputs a `vibrantColorMatrix` filter declares beside
    /// `inputColorMatrix` — the per-slot optional Booleans from the accepted
    /// matrix mutation contract. Nil is a value, exactly as for the shader:
    /// an input the captured context resolves nil may resolve nonnil in the
    /// destination's real context and must be cleared on replay.
    static func matrixScalarInputs(
        on layer: CALayer
    ) -> (values: [String: Double], nilKeys: Set<String>) {
        guard let filter = (layer.filters as? [NSObject])?.first(where: {
            filterName($0) == "vibrantColorMatrix"
        }) else { return ([:], []) }
        var values: [String: Double] = [:]
        var nilKeys: Set<String> = []
        for key in filterInputKeys(filter) where key != "inputColorMatrix" {
            if let number = filter.value(forKey: key) as? NSNumber {
                values[key] = number.doubleValue
            } else {
                nilKeys.insert(key)
            }
        }
        return (values, nilKeys)
    }

    static func setMatrixScalarInputs(
        _ values: [String: Double],
        nilKeys: Set<String> = [],
        on layer: CALayer
    ) {
        guard let filter = (layer.filters as? [NSObject])?.first(where: {
            filterName($0) == "vibrantColorMatrix"
        }), let name = filterName(filter) else { return }
        let keys = Set(filterInputKeys(filter))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, value) in values where keys.contains(key) {
            layer.setValue(value, forKeyPath: "filters.\(name).\(key)")
        }
        for key in nilKeys where keys.contains(key) {
            layer.setValue(nil, forKeyPath: "filters.\(name).\(key)")
        }
        CATransaction.commit()
    }

    /// Reads the 4x5 color matrix of the first `vibrantColorMatrix` on the
    /// layer. Serves the Tint branch and the untinted Content/Rim slots alike.
    static func colorMatrix(on layer: CALayer) -> [Float]? {
        guard let filter = (layer.filters as? [NSObject])?.first(where: {
            filterName($0) == "vibrantColorMatrix"
        }), filterInputKeys(filter).contains("inputColorMatrix"),
        let value = filter.value(forKey: "inputColorMatrix") as? NSValue else {
            return nil
        }
        var storage = [Float](repeating: 0, count: 20)
        guard NSValueByteCount(value) == MemoryLayout<Float>.size * 20 else {
            return nil
        }
        storage.withUnsafeMutableBytes { value.getValue($0.baseAddress!) }
        return storage
    }

    static func setColorMatrix(_ matrix: [Float], on layer: CALayer) {
        guard matrix.count == 20,
              let filter = (layer.filters as? [NSObject])?.first(where: {
                  filterName($0) == "vibrantColorMatrix"
              }),
              filterInputKeys(filter).contains("inputColorMatrix"),
              let name = filterName(filter) else { return }
        // Re-box with the destination's own objCType. The render server
        // decodes the filter's native encoding ({CAColorMatrix=…}); a plain
        // [20f] box round-trips through every KVC and presentation read yet
        // renders nothing — model-perfect and pixel-absent, measured on the
        // tint branch against a genuine Main-On window. Same 80 bytes,
        // different type tag; the accepted lab mutation contract has always
        // re-boxed with the captured type string.
        let currentValue = layer.value(
            forKeyPath: "filters.\(name).inputColorMatrix"
        ) as? NSValue
        let typeString = currentValue.map { String(cString: $0.objCType) }
            ?? "[20f]"
        let boxed = typeString.withCString { typePointer in
            matrix.withUnsafeBytes {
                NSValue(bytes: $0.baseAddress!, objCType: typePointer)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(
            boxed,
            forKeyPath: "filters.\(name).inputColorMatrix"
        )
        CATransaction.commit()
    }

    private static func NSValueByteCount(_ value: NSValue) -> Int {
        var size = 0
        NSGetSizeAndAlignment(value.objCType, &size, nil)
        return size
    }

    // MARK: Selector safety

    static func valueIfResponds(forKey key: String, on object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    /// Writes the private variant with the same responds-guarded discipline
    /// as every other private access: Regular is 1, Clear is 2. Used by the
    /// atlas provider to give a fresh probe its material before the first
    /// resolution settles.
    static func setVariant(_ variant: Int, on glass: NSGlassEffectView) {
        guard glass.responds(to: NSSelectorFromString("set_variant:")) else {
            return
        }
        glass.setValue(variant, forKey: "_variant")
    }
}
#endif
