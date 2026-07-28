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

    // MARK: Rim gate

    static func rimOpacity(of layer: CALayer) -> Double {
        Double(layer.opacity)
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

    // MARK: Tint matrix

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

    /// Reads the 4x5 color matrix of the Tint-owned `vibrantColorMatrix`.
    static func tintMatrix(on layer: CALayer) -> [Float]? {
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

    static func setTintMatrix(_ matrix: [Float], on layer: CALayer) {
        guard matrix.count == 20,
              let filter = (layer.filters as? [NSObject])?.first(where: {
                  filterName($0) == "vibrantColorMatrix"
              }),
              filterInputKeys(filter).contains("inputColorMatrix"),
              let name = filterName(filter) else { return }
        let storage = matrix
        let boxed = storage.withUnsafeBytes {
            NSValue(
                bytes: $0.baseAddress!,
                objCType: "[20f]"
            )
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
}
#endif
