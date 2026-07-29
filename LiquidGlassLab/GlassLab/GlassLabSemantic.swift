//
//  GlassLabSemantic.swift
//  LiquidGlassLab
//
//  Runtime-gated access to SwiftUI's private semantic Glass usages plus a
//  read-only inspector for the CA layer/filter/effect tree they synthesize.
//  These usages are not NSGlassEffectView `_variant` values.
//  See Documentation/SwiftUIGlassReverseEngineering.md
//

#if os(macOS)
import AppKit
import Combine
import Darwin
import QuartzCore
import SwiftUI

enum GlassLabRendererMode: String, CaseIterable, Identifiable {
    case recipe = "Recipe (NSGlass)"
    case semanticUsage = "Semantic Usage (SwiftUI)"

    var id: Self { self }

    var navigationTitle: String {
        switch self {
        case .recipe: "NSGlass"
        case .semanticUsage: "SwiftUI"
        }
    }

    var navigationIcon: String {
        switch self {
        case .recipe: "square.stack.3d.up"
        case .semanticUsage: "swift"
        }
    }
}

/// Sidebar sections. Recipe and Semantic Usage are the two tweaking surfaces
/// and map 1:1 onto renderer modes; Bench is the research area — captures,
/// probes, studies, and exports — and deliberately has no renderer of its own:
/// each Bench page drives `rendererMode` to whatever its instrumentation
/// needs, so tweaking pages never host capture UI again.
enum GlassLabSection: String, CaseIterable, Identifiable {
    case recipe = "Recipe (NSGlass)"
    case semanticUsage = "Semantic Usage (SwiftUI)"
    case bench = "Bench"

    var id: Self { self }

    var navigationTitle: String {
        switch self {
        case .recipe: "NSGlass"
        case .semanticUsage: "SwiftUI"
        case .bench: "Bench"
        }
    }

    var navigationIcon: String {
        switch self {
        case .recipe: "square.stack.3d.up"
        case .semanticUsage: "swift"
        case .bench: "flask"
        }
    }

    /// The renderer this section requires, or nil when the section leaves the
    /// renderer to its pages.
    var requiredRendererMode: GlassLabRendererMode? {
        switch self {
        case .recipe: .recipe
        case .semanticUsage: .semanticUsage
        case .bench: nil
        }
    }
}

enum GlassLabMaterializeAnimationMode: String, CaseIterable, Identifiable, Codable {
    case systemDefault = "System Default"
    case linear = "Linear"

    var id: Self { self }
}

enum GlassLabMaterializeDirection: String, CaseIterable, Identifiable, Codable {
    case insertion = "Insertion"
    case removal = "Removal"

    var id: Self { self }

    var initialPresentedState: Bool {
        switch self {
        case .insertion: false
        case .removal: true
        }
    }

    var targetPresentedState: Bool {
        !initialPresentedState
    }
}

/// SwiftUI `_Glass.Variant.Role` tags observed on macOS 27. This is a separate
/// ordinal space from both AppKit's raw `_variant` and DesignLibrary's
/// `GlassMaterialProvider.Variant` enum used by electron-liquid-glass.
enum GlassLabSemanticUsage: Int, CaseIterable, Identifiable {
    case regular = 0
    case identity
    case clear
    case dock
    case appIcons
    case widgets
    case text
    case avPlayer
    case faceTime
    case controlCenter
    case notificationCenter
    case monogram
    case focusBorder
    case keyboard
    case sidebar
    case control
    case loupe
    case slider
    case camera
    case cartouchePopover
    case menu
    case siri
    case siriSnippet
    case vibrantFill

    var id: Self { self }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .identity: "Identity"
        case .clear: "Clear"
        case .dock: "Dock"
        case .appIcons: "App Icons"
        case .widgets: "Widgets"
        case .text: "Text"
        case .avPlayer: "AVPlayer"
        case .faceTime: "FaceTime"
        case .controlCenter: "Control Center"
        case .notificationCenter: "Notification Center"
        case .monogram: "Monogram"
        case .focusBorder: "Focus Border"
        case .keyboard: "Keyboard"
        case .sidebar: "Sidebar"
        case .control: "Control"
        case .loupe: "Loupe"
        case .slider: "Slider"
        case .camera: "Camera"
        case .cartouchePopover: "Cartouche Popover"
        case .menu: "Menu"
        case .siri: "Siri"
        case .siriSnippet: "Siri Snippet"
        case .vibrantFill: "Vibrant Fill"
        }
    }

    var symbolName: String {
        switch self {
        case .regular: "$s7SwiftUI6_GlassV7regularACvgZ"
        case .identity: "$s7SwiftUI6_GlassV8identityACvgZ"
        case .clear: "$s7SwiftUI6_GlassV5clearACvgZ"
        case .dock: "$s7SwiftUI6_GlassV4dockACvgZ"
        case .appIcons: "$s7SwiftUI6_GlassV8appIconsACvgZ"
        case .widgets: "$s7SwiftUI6_GlassV7widgetsACvgZ"
        case .text:
            // `_Glass.text` is a factory rather than a zero-argument getter.
            // The runtime calls it with nil tint/frost/normalized-factor so
            // its own default fields are preserved rather than forged.
            "$s7SwiftUI6_GlassV4text4tint5frost16normalizedFactorAcA5ColorVSg_SfSgAKtFZ"
        case .avPlayer: "$s7SwiftUI6_GlassV8avplayerACvgZ"
        case .faceTime: "$s7SwiftUI6_GlassV8facetimeACvgZ"
        case .controlCenter: "$s7SwiftUI6_GlassV13controlCenterACvgZ"
        case .notificationCenter: "$s7SwiftUI6_GlassV18notificationCenterACvgZ"
        case .monogram: "$s7SwiftUI6_GlassV8monogramACvgZ"
        case .focusBorder: "$s7SwiftUI6_GlassV11focusBorderACvgZ"
        case .keyboard: "$s7SwiftUI6_GlassV8keyboardACvgZ"
        case .sidebar: "$s7SwiftUI6_GlassV7sidebarACvgZ"
        case .control: "$s7SwiftUI6_GlassV7controlACvgZ"
        case .loupe: "$s7SwiftUI6_GlassV5loupeACvgZ"
        case .slider: "$s7SwiftUI6_GlassV6sliderACvgZ"
        case .camera: "$s7SwiftUI6_GlassV6cameraACvgZ"
        case .cartouchePopover: "$s7SwiftUI6_GlassV16cartouchePopoverACvgZ"
        case .menu: "$s7SwiftUI6_GlassV4menuACvgZ"
        case .siri: "$s7SwiftUI6_GlassV4siriACvgZ"
        case .siriSnippet: "$s7SwiftUI6_GlassV11siriSnippetACvgZ"
        case .vibrantFill: "$s7SwiftUI6_GlassV11vibrantFillACvgZ"
        }
    }

    var implementationHint: String {
        switch self {
        case .regular:
            "Public Regular-compatible semantic material."
        case .clear:
            "Public Clear-compatible semantic material."
        case .identity:
            "Identity/no-op semantic material; it is not AppKit raw Variant 12."
        case .control, .loupe, .slider:
            "Control-family composition: a related base Recipe plus Usage-specific displacement/foreground layers."
        case .camera:
            "Resolves through the camera-named material path; it is not AppKit raw Variant 22."
        case .cartouchePopover:
            "Uses a cartouche-family base plus SwiftUI composition; it is not AppKit raw Variant 23."
        case .focusBorder:
            "Outline/highlight composition that may intentionally omit glassBackground."
        case .siri, .siriSnippet:
            "Composite semantic treatment with Usage-specific foreground/gradient layers."
        default:
            "Private SwiftUI semantic material; inspect the live layer tree for its resolved composition."
        }
    }
}

struct GlassLabSemanticResolution {
    let glass: Glass?
    let message: String

    var isAvailable: Bool { glass != nil }
}

@MainActor
final class GlassLabSemanticRuntime {
    static let shared = GlassLabSemanticRuntime()

    private struct GlassABIProfile {
        let size: Int
        let stride: Int
    }

    private struct RuntimeValueLayout: Equatable {
        let size: Int
        let stride: Int
        let flagsAndExtraInhabitants: UInt
    }

    /// `_Glass` is private and changed layout between the measured macOS 26
    /// and macOS 27 runtimes. Keep an explicit allowlist rather than treating
    /// any coincidentally equal public/private size as ABI compatibility.
    private static let glassABIProfiles: [Int: GlassABIProfile] = [
        26: GlassABIProfile(size: 41, stride: 48),
        27: GlassABIProfile(size: 40, stride: 40),
    ]
    private static let publicGlassMetadataSymbol = "$s7SwiftUI5GlassVN"
    private static let privateGlassMetadataSymbol = "$s7SwiftUI6_GlassVN"
    private typealias GlassGetter = @convention(thin) () -> Glass
    private typealias TextFactory = @convention(thin) (
        Color?,
        Float?,
        Float?
    ) -> Glass

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let loadError: String?
    /// Empty string means Available. Caching keeps Form re-evaluation from
    /// repeating metadata walks and 24 dlsym calls while controls update.
    private var availabilityCache: [GlassLabSemanticUsage: String] = [:]

    private init() {
        let paths = [
            "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            "/System/Library/Frameworks/SwiftUI.framework/Versions/A/Frameworks/SwiftUICore.framework/SwiftUICore",
        ]
        var loadedHandle: UnsafeMutableRawPointer?
        var lastError: String?
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                loadedHandle = handle
                break
            }
            if let error = dlerror() {
                lastError = String(cString: error)
            }
        }
        frameworkHandle = loadedHandle
        loadError = loadedHandle == nil
            ? (lastError ?? "SwiftUICore could not be loaded.")
            : nil
    }

    func isAvailable(_ usage: GlassLabSemanticUsage) -> Bool {
        availabilityMessage(for: usage) == nil
    }

    func status(for usage: GlassLabSemanticUsage) -> String {
        availabilityMessage(for: usage) ?? "Available on this runtime"
    }

    func resolve(_ usage: GlassLabSemanticUsage) -> GlassLabSemanticResolution {
        if let unavailable = availabilityMessage(for: usage) {
            return GlassLabSemanticResolution(glass: nil, message: unavailable)
        }
        guard let handle = frameworkHandle else {
            return GlassLabSemanticResolution(
                glass: nil,
                message: loadError ?? "SwiftUICore is unavailable."
            )
        }

        guard let function = dlsym(handle, usage.symbolName) else {
            return GlassLabSemanticResolution(
                glass: nil,
                message: "Private getter is missing on this runtime."
            )
        }
        let glass: Glass
        if usage == .text {
            let factory = unsafeBitCast(function, to: TextFactory.self)
            glass = factory(nil, nil, nil)
        } else {
            let getter = unsafeBitCast(function, to: GlassGetter.self)
            glass = getter()
        }
        return GlassLabSemanticResolution(
            glass: glass,
            message: "Available on this runtime"
        )
    }

    private func availabilityMessage(for usage: GlassLabSemanticUsage) -> String? {
        if let cached = availabilityCache[usage] {
            return cached.isEmpty ? nil : cached
        }
        let message = uncachedAvailabilityMessage(for: usage)
        availabilityCache[usage] = message ?? ""
        return message
    }

    private func uncachedAvailabilityMessage(
        for usage: GlassLabSemanticUsage
    ) -> String? {
        guard let handle = frameworkHandle else {
            return "Unavailable: \(loadError ?? "SwiftUICore could not be loaded.")"
        }
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let profile = Self.glassABIProfiles[majorVersion] else {
            return "Unavailable: macOS \(majorVersion) has no verified Glass ABI profile."
        }
        guard let publicLayout = runtimeValueLayout(
            symbol: Self.publicGlassMetadataSymbol,
            in: handle
        ) else {
            return "Unavailable: public Glass metadata is absent on this runtime."
        }
        guard publicLayout.size == MemoryLayout<Glass>.size,
              publicLayout.stride == MemoryLayout<Glass>.stride else {
            return "Unavailable: public Glass metadata disagrees with its runtime MemoryLayout."
        }
        guard publicLayout.size == profile.size,
              publicLayout.stride == profile.stride else {
            return "Unavailable: public Glass layout is \(publicLayout.size)/\(publicLayout.stride) bytes; the verified macOS \(majorVersion) profile requires \(profile.size)/\(profile.stride)."
        }
        guard let privateLayout = runtimeValueLayout(
            symbol: Self.privateGlassMetadataSymbol,
            in: handle
        ) else {
            return "Unavailable: private `_Glass` metadata is absent on this runtime."
        }
        guard privateLayout == publicLayout else {
            return "Unavailable: public Glass and private `_Glass` runtime layouts do not match."
        }
        guard dlsym(handle, usage.symbolName) != nil else {
            return "Unavailable: this private SwiftUI Usage is absent on the current macOS runtime."
        }
        return nil
    }

    /// Swift value metadata stores its Value Witness Table pointer one word
    /// before the metadata address. VWT slots 8, 9, and 10 contain size,
    /// stride, and the combined flags/extra-inhabitant word. Checking all
    /// three before the ABI cast makes layout drift a visible Unavailable
    /// state instead of an unsafe function call.
    private func runtimeValueLayout(
        symbol: String,
        in handle: UnsafeMutableRawPointer
    ) -> RuntimeValueLayout? {
        guard let metadata = dlsym(handle, symbol) else {
            return nil
        }
        let pointerSize = MemoryLayout<UnsafeRawPointer>.size
        let witnessTable = metadata
            .advanced(by: -pointerSize)
            .load(as: UnsafeRawPointer.self)
        let wordSize = MemoryLayout<UInt>.size
        return RuntimeValueLayout(
            size: Int(witnessTable.load(
                fromByteOffset: 8 * wordSize,
                as: UInt.self
            )),
            stride: Int(witnessTable.load(
                fromByteOffset: 9 * wordSize,
                as: UInt.self
            )),
            flagsAndExtraInhabitants: witnessTable.load(
                fromByteOffset: 10 * wordSize,
                as: UInt.self
            )
        )
    }
}

@MainActor
final class GlassLabSemanticModel: ObservableObject {
    @Published var glass: Glass = .regular
    @Published var displayName = GlassLabSemanticUsage.regular.displayName
    @Published var cornerRadius: Double = 16
    @Published var isAvailable = true
    @Published var status = "Available on this runtime"
    @Published var isTransitionProbeEnabled = false
    @Published var isTransitionPresented = true
    @Published private(set) var previewRevision = 0
    private var resolvedUsage: GlassLabSemanticUsage?
    private var resolvedBaseGlass: Glass?
    private var resolvedTintColor: NSColor?

    func update(
        usage: GlassLabSemanticUsage,
        cornerRadius: Double,
        tintColor: NSColor?
    ) {
        if self.cornerRadius != cornerRadius {
            self.cornerRadius = cornerRadius
        }
        let usageChanged = usage != resolvedUsage
        let tintChanged = !Self.colorsEqual(resolvedTintColor, tintColor)
        guard usageChanged || tintChanged else { return }

        if usageChanged {
            let resolution = GlassLabSemanticRuntime.shared.resolve(usage)
            resolvedUsage = usage
            displayName = usage.displayName
            status = resolution.message
            isAvailable = resolution.isAvailable
            resolvedBaseGlass = resolution.glass
        }
        if tintChanged {
            resolvedTintColor = tintColor?.copy() as? NSColor
        }
        if let resolvedBaseGlass {
            glass = resolvedBaseGlass.tint(resolvedTintColor.map(Color.init))
        }
    }

    private static func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isEqual(rhs)
        default: false
        }
    }

    func configureTransitionProbe(enabled: Bool, presented: Bool) {
        let previewModeChanged = enabled != isTransitionProbeEnabled
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isTransitionProbeEnabled = enabled
            isTransitionPresented = enabled ? presented : true
            if previewModeChanged {
                previewRevision &+= 1
            }
        }
    }

    /// Recreates the whole transition subtree at a known endpoint.
    ///
    /// A reused GlassEffectContainer can retain the previous Usage or geometry
    /// Recipe even after its public state and window context already match.
    /// Capture runs need a new identity so their preflight endpoint is resolved
    /// from the requested context rather than inherited from the preceding run.
    func resetTransitionProbe(presented: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isTransitionProbeEnabled = true
            isTransitionPresented = presented
            previewRevision &+= 1
        }
    }

    func setTransitionPresented(
        _ presented: Bool,
        animationMode: GlassLabMaterializeAnimationMode,
        linearDuration: Double
    ) {
        guard isTransitionProbeEnabled, presented != isTransitionPresented else {
            return
        }
        switch animationMode {
        case .systemDefault:
            withAnimation(.default) {
                isTransitionPresented = presented
            }
        case .linear:
            withAnimation(.linear(duration: linearDuration)) {
                isTransitionPresented = presented
            }
        }
    }
}

struct GlassLabSemanticSurfaceView: View {
    @ObservedObject var model: GlassLabSemanticModel

    var body: some View {
        Group {
            if model.isTransitionProbeEnabled {
                GlassEffectContainer(spacing: 0) {
                    if model.isTransitionPresented {
                        resolvedSurface
                            .glassEffectTransition(.materialize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resolvedSurface
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .id(model.previewRevision)
    }

    @ViewBuilder
    private var resolvedSurface: some View {
        if model.isAvailable {
            ZStack {
                Color.white.opacity(0.001)
                Text(model.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(
                model.glass,
                in: .rect(cornerRadius: model.cornerRadius)
            )
        } else {
            ZStack {
                Color.red.opacity(0.12)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: model.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: model.cornerRadius)
                    .stroke(.red.opacity(0.35), style: StrokeStyle(dash: [5, 4]))
            }
        }
    }
}

// MARK: - Materialize transition probe

struct GlassLabSemanticTransitionLayerRecord: Codable, Equatable, Identifiable {
    let path: String
    let layerClass: String
    let name: String?
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
    let boundsX: Double
    let boundsY: Double
    let boundsWidth: Double
    let boundsHeight: Double
    let positionX: Double
    let positionY: Double
    let anchorX: Double
    let anchorY: Double
    let zPosition: Double
    let opacity: Double
    let isHidden: Bool
    let masksToBounds: Bool
    let cornerRadius: Double
    let contentsScale: Double
    let backgroundColor: String?
    let borderColor: String?
    let shadowColor: String?
    /// Row-major CATransform3D values m11...m44.
    let transform: [Double]
    /// Row-major CATransform3D values m11...m44.
    let sublayerTransform: [Double]
    /// CGAffineTransform values a, b, c, d, tx, ty.
    let affineTransform: [Double]

    var id: String { path }
}

struct GlassLabSemanticAnimationRecord: Codable, Equatable, Identifiable {
    let layerPath: String
    let registrationKey: String
    let componentPath: String
    let animationClass: String
    let keyPath: String?
    let beginTime: Double
    let duration: Double
    let speed: Float
    let timeOffset: Double
    let repeatCount: Float
    let autoreverses: Bool
    let fillMode: String
    let isRemovedOnCompletion: Bool
    let timingFunction: String?
    let details: [String: String]

    var id: String {
        "\(layerPath).\(registrationKey).\(componentPath)"
    }
}

struct GlassLabSemanticTransitionSnapshot: Codable, Equatable {
    let model: GlassLabSemanticSnapshot
    let presentation: GlassLabSemanticSnapshot?
    let modelLayers: [GlassLabSemanticTransitionLayerRecord]
    let presentationLayers: [GlassLabSemanticTransitionLayerRecord]?
    let animations: [GlassLabSemanticAnimationRecord]

    @MainActor
    static func capture(from root: CALayer?) -> GlassLabSemanticTransitionSnapshot? {
        guard let root,
              let model = GlassLabSemanticSnapshot.capture(
                from: root,
                includesMasks: true
              ) else {
            return nil
        }
        let presentationRoot = root.presentation()
        return GlassLabSemanticTransitionSnapshot(
            model: model,
            presentation: GlassLabSemanticSnapshot.capture(
                from: presentationRoot,
                includesMasks: true
            ),
            modelLayers: captureLayers(from: root),
            presentationLayers: presentationRoot.map(captureLayers),
            animations: captureAnimations(from: root)
        )
    }

    @MainActor
    private static func captureLayers(
        from root: CALayer
    ) -> [GlassLabSemanticTransitionLayerRecord] {
        var records: [GlassLabSemanticTransitionLayerRecord] = []

        func visit(_ layer: CALayer, path: String) {
            let frame = layer.frame
            let bounds = layer.bounds
            let position = layer.position
            let anchor = layer.anchorPoint
            let affine = layer.affineTransform()
            records.append(
                GlassLabSemanticTransitionLayerRecord(
                    path: path,
                    layerClass: String(describing: type(of: layer)),
                    name: layer.name,
                    frameX: Double(frame.origin.x),
                    frameY: Double(frame.origin.y),
                    frameWidth: Double(frame.width),
                    frameHeight: Double(frame.height),
                    boundsX: Double(bounds.origin.x),
                    boundsY: Double(bounds.origin.y),
                    boundsWidth: Double(bounds.width),
                    boundsHeight: Double(bounds.height),
                    positionX: Double(position.x),
                    positionY: Double(position.y),
                    anchorX: Double(anchor.x),
                    anchorY: Double(anchor.y),
                    zPosition: Double(layer.zPosition),
                    opacity: Double(layer.opacity),
                    isHidden: layer.isHidden,
                    masksToBounds: layer.masksToBounds,
                    cornerRadius: Double(layer.cornerRadius),
                    contentsScale: Double(layer.contentsScale),
                    backgroundColor: stableColorDescription(
                        layer.backgroundColor
                    ),
                    borderColor: stableColorDescription(layer.borderColor),
                    shadowColor: stableColorDescription(layer.shadowColor),
                    transform: transformValues(layer.transform),
                    sublayerTransform: transformValues(
                        layer.sublayerTransform
                    ),
                    affineTransform: [
                        Double(affine.a),
                        Double(affine.b),
                        Double(affine.c),
                        Double(affine.d),
                        Double(affine.tx),
                        Double(affine.ty),
                    ]
                )
            )
            for (index, child) in (layer.sublayers ?? []).enumerated() {
                visit(
                    child,
                    path: "\(path).\(index):\(String(describing: type(of: child)))"
                )
            }
            if let mask = layer.mask {
                visit(
                    mask,
                    path: "\(path).mask:\(String(describing: type(of: mask)))"
                )
            }
        }

        visit(root, path: String(describing: type(of: root)))
        return records
    }

    nonisolated private static func transformValues(
        _ transform: CATransform3D
    ) -> [Double] {
        [
            Double(transform.m11), Double(transform.m12),
            Double(transform.m13), Double(transform.m14),
            Double(transform.m21), Double(transform.m22),
            Double(transform.m23), Double(transform.m24),
            Double(transform.m31), Double(transform.m32),
            Double(transform.m33), Double(transform.m34),
            Double(transform.m41), Double(transform.m42),
            Double(transform.m43), Double(transform.m44),
        ]
    }

    nonisolated private static func stableColorDescription(
        _ color: CGColor?
    ) -> String? {
        guard let color else { return nil }
        let components = (color.components ?? []).map {
            String(format: "%.9g", Double($0))
        }.joined(separator: ",")
        let colorSpace = color.colorSpace?.name as String? ?? "unknown"
        return "\(colorSpace)[\(components)]"
    }

    @MainActor
    private static func captureAnimations(
        from root: CALayer
    ) -> [GlassLabSemanticAnimationRecord] {
        var records: [GlassLabSemanticAnimationRecord] = []

        func capture(
            _ animation: CAAnimation,
            registrationKey: String,
            componentPath: String,
            layerPath: String
        ) {
            var details: [String: String] = [:]
            if let basic = animation as? CABasicAnimation {
                details["fromValue"] = describe(basic.fromValue)
                details["toValue"] = describe(basic.toValue)
                details["byValue"] = describe(basic.byValue)
            }
            if let keyframe = animation as? CAKeyframeAnimation {
                details["calculationMode"] = keyframe.calculationMode.rawValue
                details["keyTimes"] = keyframe.keyTimes?
                    .map { String(format: "%.6g", $0.doubleValue) }
                    .joined(separator: ", ")
                details["values"] = keyframe.values?
                    .map { describe($0) ?? "nil" }
                    .joined(separator: " | ")
            }
            if let spring = animation as? CASpringAnimation {
                details["mass"] = String(format: "%.6g", spring.mass)
                details["stiffness"] = String(format: "%.6g", spring.stiffness)
                details["damping"] = String(format: "%.6g", spring.damping)
                details["initialVelocity"] = String(
                    format: "%.6g",
                    spring.initialVelocity
                )
                details["settlingDuration"] = String(
                    format: "%.6g",
                    spring.settlingDuration
                )
            }

            records.append(
                GlassLabSemanticAnimationRecord(
                    layerPath: layerPath,
                    registrationKey: registrationKey,
                    componentPath: componentPath,
                    animationClass: String(describing: type(of: animation)),
                    keyPath: (animation as? CAPropertyAnimation)?.keyPath,
                    beginTime: animation.beginTime,
                    duration: animation.duration,
                    speed: animation.speed,
                    timeOffset: animation.timeOffset,
                    repeatCount: animation.repeatCount,
                    autoreverses: animation.autoreverses,
                    fillMode: animation.fillMode.rawValue,
                    isRemovedOnCompletion: animation.isRemovedOnCompletion,
                    timingFunction: animation.timingFunction.map {
                        String(describing: $0)
                    },
                    details: details.compactMapValues { $0 }
                )
            )

            if let group = animation as? CAAnimationGroup {
                for (index, child) in (group.animations ?? []).enumerated() {
                    capture(
                        child,
                        registrationKey: registrationKey,
                        componentPath: "\(componentPath).\(index)",
                        layerPath: layerPath
                    )
                }
            }
        }

        func visit(_ layer: CALayer, path: String) {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else {
                    continue
                }
                capture(
                    animation,
                    registrationKey: key,
                    componentPath: "root",
                    layerPath: path
                )
            }
            for (index, child) in (layer.sublayers ?? []).enumerated() {
                visit(
                    child,
                    path: "\(path).\(index):\(String(describing: type(of: child)))"
                )
            }
            if let mask = layer.mask {
                visit(
                    mask,
                    path: "\(path).mask:\(String(describing: type(of: mask)))"
                )
            }
        }

        visit(root, path: String(describing: type(of: root)))
        return records.sorted {
            if $0.layerPath != $1.layerPath {
                return $0.layerPath < $1.layerPath
            }
            if $0.registrationKey != $1.registrationKey {
                return $0.registrationKey < $1.registrationKey
            }
            return $0.componentPath < $1.componentPath
        }
    }

    private static func describe(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            return String(format: "%.6g", number.doubleValue)
        }
        if let string = value as? String {
            return string
        }
        let cfValue = value as CFTypeRef
        if CFGetTypeID(cfValue) == CGColor.typeID {
            let color = unsafeBitCast(cfValue, to: CGColor.self)
            let components = (color.components ?? [])
                .map { String(format: "%.6g", Double($0)) }
                .joined(separator: ", ")
            return "CGColor([\(components)])"
        }
        if let array = value as? [Any] {
            return "["
                + array.map { describe($0) ?? "nil" }
                    .joined(separator: ", ")
                + "]"
        }
        if let matrix = GlassLabTuning.colorMatrixDescription(value) {
            return matrix
        }
        return String(describing: value)
    }
}

struct GlassLabMaterializeSample: Codable, Equatable, Identifiable {
    let phase: String
    let requestedProgress: Double
    let elapsed: Double
    let snapshot: GlassLabSemanticTransitionSnapshot

    var id: String {
        "\(phase).\(requestedProgress).\(elapsed)"
    }
}

struct GlassLabMaterializeCaptureContext: Codable, Equatable {
    let hostType: String
    let requestedMain: Bool
    let actualMain: Bool
    let actualKey: Bool
    let requestedAppearance: GlassLabTestAppearance
    let effectiveAppearance: String
    let backdrop: GlassLabBackdropMode
    let glassWidth: Double
    let glassHeight: Double
    let cornerRadius: Double
    let windowMargin: Double
    let tint: GlassLabTintDescriptor
}

struct GlassLabMaterializeCapture: Codable, Equatable {
    let formatVersion: Int
    let capturedAt: String
    let operatingSystem: String
    let roleTag: Int
    let usage: String
    let direction: GlassLabMaterializeDirection
    let animationMode: GlassLabMaterializeAnimationMode
    let requestedDuration: Double?
    let maximumAttachedAnimationDuration: Double
    let samplingDuration: Double
    let context: GlassLabMaterializeCaptureContext
    let samples: [GlassLabMaterializeSample]

    var report: String {
        let requestedDurationText = requestedDuration.map(Self.format)
            ?? "system"
        let attachedDurationText = Self.format(
            maximumAttachedAnimationDuration
        )
        let samplingDurationText = Self.format(samplingDuration)
        let geometry = Self.format(context.glassWidth)
            + "×\(Self.format(context.glassHeight))"
            + "@\(Self.format(context.cornerRadius))"
            + " margin=\(Self.format(context.windowMargin))"
        var lines = [
            "== SwiftUI Materialize Transition ==",
            "usage=\(usage) roleTag=\(roleTag)",
            "direction=\(direction.rawValue) animation=\(animationMode.rawValue)",
            "requestedDuration=\(requestedDurationText)",
            "maximumAttachedAnimationDuration=\(attachedDurationText)",
            "samplingDuration=\(samplingDurationText)",
            "host=\(context.hostType) requestedMain=\(context.requestedMain)"
                + " actualMain=\(context.actualMain) actualKey=\(context.actualKey)",
            "appearance=\(context.requestedAppearance.rawValue)"
                + " effective=\(context.effectiveAppearance)"
                + " backdrop=\(context.backdrop.rawValue)",
            "geometry=\(geometry)",
            "tint=\(context.tint.label) components="
                + "\(context.tint.components?.description ?? "nil")",
            "",
            "Samples",
            "-------",
        ]
        for sample in samples {
            let presentation = sample.snapshot.presentation
            var sampleLine = sample.phase
            sampleLine += " p=\(Self.format(sample.requestedProgress))"
            sampleLine += " elapsed=\(Self.format(sample.elapsed))"
            sampleLine += " modelLayers=\(sample.snapshot.model.layerLines.count)"
            sampleLine += " presentationLayers=\(presentation?.layerLines.count ?? 0)"
            sampleLine += " animations=\(sample.snapshot.animations.count)"
            lines.append(sampleLine)
            for animation in sample.snapshot.animations {
                var animationLine = "  \(animation.layerPath)"
                animationLine += " · \(animation.registrationKey)"
                animationLine += " · \(animation.animationClass)"
                animationLine += " keyPath=\(animation.keyPath ?? "<group>")"
                animationLine += " duration=\(Self.format(animation.duration))"
                lines.append(animationLine)
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}

// MARK: - Live semantic layer inspector

struct GlassLabSemanticInputRecord: Codable, Equatable, Identifiable {
    let key: String
    let value: String

    var id: String { key }
}

struct GlassLabSemanticFilterRecord: Codable, Equatable, Identifiable {
    let path: String
    let layerClass: String
    let location: String
    let name: String
    let inputs: [GlassLabSemanticInputRecord]

    var id: String { "\(path).\(location).\(name)" }
}

struct GlassLabSemanticEffectRecord: Codable, Equatable, Identifiable {
    let path: String
    let layerClass: String
    let effectClass: String
    let layerOpacity: Double
    let inputs: [GlassLabSemanticInputRecord]

    var id: String { "\(path).\(effectClass)" }
}

struct GlassLabSemanticSnapshot: Codable, Equatable {
    let layerLines: [String]
    let filters: [GlassLabSemanticFilterRecord]
    let effects: [GlassLabSemanticEffectRecord]

    var report: String {
        var lines = ["Layer Tree", "----------"]
        lines.append(contentsOf: layerLines)
        lines.append("")
        lines.append("Filters")
        lines.append("-------")
        if filters.isEmpty {
            lines.append("<none>")
        } else {
            for filter in filters {
                lines.append("\(filter.path) · \(filter.location) · \(filter.name)")
                for input in filter.inputs {
                    lines.append("  \(input.key) = \(input.value)")
                }
            }
        }
        lines.append("")
        lines.append("Effects")
        lines.append("-------")
        if effects.isEmpty {
            lines.append("<none>")
        } else {
            for effect in effects {
                lines.append("\(effect.path) · \(effect.effectClass) · opacity \(Self.format(effect.layerOpacity))")
                for input in effect.inputs {
                    lines.append("  \(input.key) = \(input.value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func capture(
        from root: CALayer?,
        includesMasks: Bool = false
    ) -> GlassLabSemanticSnapshot? {
        guard let root else { return nil }
        var layerLines: [String] = []
        var filters: [GlassLabSemanticFilterRecord] = []
        var effects: [GlassLabSemanticEffectRecord] = []

        func visit(_ layer: CALayer, path: String, depth: Int) {
            let layerClass = String(describing: type(of: layer))
            let directFilters = filterObjects(from: layer.filters)
            let backgroundFilters = filterObjects(from: layer.backgroundFilters)
            let directNames = directFilters.compactMap(filterName)
            let backgroundNames = backgroundFilters.compactMap(filterName)
            let effect = objectValue("effect", on: layer)

            var summary = String(repeating: "  ", count: depth) + layerClass
            if let name = layer.name, !name.isEmpty {
                summary += " \"\(name)\""
            }
            summary += " frame=\(format(layer.frame)) opacity=\(format(Double(layer.opacity)))"
            let pipelineNames = directNames + backgroundNames
            if !pipelineNames.isEmpty {
                summary += " filters=[\(pipelineNames.joined(separator: ", "))]"
            }
            if let effect {
                summary += " effect=\(String(describing: type(of: effect)))"
            }
            layerLines.append(summary)

            captureFilters(
                directFilters,
                location: "filters",
                path: path,
                layerClass: layerClass,
                into: &filters
            )
            captureFilters(
                backgroundFilters,
                location: "backgroundFilters",
                path: path,
                layerClass: layerClass,
                into: &filters
            )

            if let effect {
                let keys = [
                    "keyAmount", "keyHeight", "keySpread", "keyAngle",
                    "fillAmount", "fillHeight", "fillSpread", "fillAngle",
                    "curvature", "diffuseAmountScale", "diffuseHeightScale",
                    "diffuseSpreadScale", "global", "minimum", "maximum",
                    "keyColor", "fillColor", "color", "colors", "distances",
                    "interpolations", "premultiplied",
                ]
                let inputs = keys.compactMap { key -> GlassLabSemanticInputRecord? in
                    guard let value = guardedValue(key, on: effect) else { return nil }
                    return GlassLabSemanticInputRecord(key: key, value: describe(value))
                }
                effects.append(
                    GlassLabSemanticEffectRecord(
                        path: path,
                        layerClass: layerClass,
                        effectClass: String(describing: type(of: effect)),
                        layerOpacity: Double(layer.opacity),
                        inputs: inputs
                    )
                )
            }

            for (index, child) in (layer.sublayers ?? []).enumerated() {
                visit(
                    child,
                    path: "\(path).\(index):\(String(describing: type(of: child)))",
                    depth: depth + 1
                )
            }
            if includesMasks, let mask = layer.mask {
                visit(
                    mask,
                    path: "\(path).mask:\(String(describing: type(of: mask)))",
                    depth: depth + 1
                )
            }
        }

        visit(root, path: String(describing: type(of: root)), depth: 0)
        return GlassLabSemanticSnapshot(
            layerLines: layerLines,
            filters: filters,
            effects: effects
        )
    }

    private static func captureFilters(
        _ objects: [NSObject],
        location: String,
        path: String,
        layerClass: String,
        into records: inout [GlassLabSemanticFilterRecord]
    ) {
        for (index, filter) in objects.enumerated() {
            let name = filterName(filter) ?? String(describing: type(of: filter))
            let keys = (guardedValue("inputKeys", on: filter) as? [String]) ?? []
            let inputs = keys.sorted().map { key in
                let valueDescription: String
                if let value = declaredFilterValue(key, on: filter) {
                    valueDescription = describe(value)
                } else {
                    valueDescription = "nil"
                }
                return GlassLabSemanticInputRecord(
                    key: key,
                    value: valueDescription
                )
            }
            records.append(
                GlassLabSemanticFilterRecord(
                    path: path,
                    layerClass: layerClass,
                    location: "\(location)[\(index)]",
                    name: name,
                    inputs: inputs
                )
            )
        }
    }

    private static func filterObjects(from value: [Any]?) -> [NSObject] {
        (value ?? []).compactMap { $0 as? NSObject }
    }

    private static func filterName(_ filter: NSObject) -> String? {
        guardedValue("name", on: filter) as? String
    }

    private static func objectValue(_ key: String, on object: NSObject) -> NSObject? {
        guardedValue(key, on: object) as? NSObject
    }

    private static func guardedValue(_ key: String, on object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    /// CAFilter inputs are dynamically KVC-compliant and generally do not
    /// expose Objective-C selectors. Calling `responds(to:)` for these keys
    /// therefore turns every real value into nil. The key is safe to read here
    /// because it came from this exact filter instance's `inputKeys` inventory,
    /// matching the guard contract used by the Recipe Inspector.
    private static func declaredFilterValue(
        _ key: String,
        on filter: NSObject
    ) -> Any? {
        filter.value(forKey: key)
    }

    private static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return format(number.doubleValue)
        }
        if let string = value as? String {
            return string
        }
        // CGColor.description embeds process-local CGColor/CGColorSpace
        // addresses. Besides making Golden diffs noisy, those pointers obscure
        // the actual value. Persist the model and ordered components instead;
        // six significant digits match Core Graphics' readable component
        // precision without retaining volatile object identity.
        let cfValue = value as CFTypeRef
        if CFGetTypeID(cfValue) == CGColor.typeID {
            let color = unsafeBitCast(cfValue, to: CGColor.self)
            return describe(color)
        }
        if let array = value as? [Any] {
            return "["
                + array.map { describe($0) }.joined(separator: ", ")
                + "]"
        }
        if let value = value as? NSValue {
            return GlassLabTuning.colorMatrixDescription(value)
                ?? value.description
        }
        return String(describing: value)
    }

    private static func describe(_ color: CGColor) -> String {
        let model = colorSpaceModelName(color.colorSpace?.model)
        let components = (color.components ?? [])
            .map { String(format: "%.6g", Double($0)) }
            .joined(separator: ", ")
        return "CGColor(model: \(model), components: [\(components)])"
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

    private static func format(_ rect: CGRect) -> String {
        "(\(format(rect.origin.x)), \(format(rect.origin.y)), \(format(rect.width)), \(format(rect.height)))"
    }

    private static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}

struct GlassLabSemanticTreeExport: Codable {
    let formatVersion: Int
    let generatedAt: String
    let operatingSystem: String
    let axes: GlassLabSemanticTreeAxes
    let context: GlassLabSemanticTreeContext
    let entries: [GlassLabSemanticTreeEntry]
}

struct GlassLabSemanticTreeAxes: Codable {
    let requestedMain: [Bool]
    let roleTags: [Int]
}

struct GlassLabSemanticTreeContext: Codable {
    let hostType: String
    let glassWidth: Double
    let glassHeight: Double
    let cornerRadius: Double
    let windowMargin: Double
}

struct GlassLabSemanticTreeEntry: Codable {
    let roleTag: Int
    let usage: String
    let requestedMain: Bool
    let isAvailable: Bool
    let runtimeStatus: String
    let actualMain: Bool
    let actualKey: Bool
    let snapshot: GlassLabSemanticSnapshot?
}
#endif
