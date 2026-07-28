//
//  GlassLabTintStudy.swift
//  LiquidGlassLab
//
//  Reproducible evidence models for locating public Glass tint across the
//  AppKit and SwiftUI rendering pipelines.
//

#if os(macOS)
import AppKit
import QuartzCore

enum GlassLabTintPreset: String, CaseIterable, Codable, Identifiable {
    case none
    case coral25
    case coral50
    case coral100
    case cyan50
    case noneReduced
    case coral50Reduced

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: "None"
        case .coral25: "Coral · 25%"
        case .coral50: "Coral · 50%"
        case .coral100: "Coral · 100%"
        case .cyan50: "Cyan · 50%"
        case .noneReduced: "None · Reduced"
        case .coral50Reduced: "Coral · 50% · Reduced"
        }
    }

    var color: NSColor? {
        switch self {
        case .none, .noneReduced:
            nil
        case .coral25:
            Self.makeColor(red: 0.92, green: 0.18, blue: 0.38, alpha: 0.25)
        case .coral50, .coral50Reduced:
            Self.makeColor(red: 0.92, green: 0.18, blue: 0.38, alpha: 0.5)
        case .coral100:
            Self.makeColor(red: 0.92, green: 0.18, blue: 0.38, alpha: 1)
        case .cyan50:
            Self.makeColor(red: 0.12, green: 0.72, blue: 0.94, alpha: 0.5)
        }
    }

    var reducedTintOpacity: Bool {
        switch self {
        case .noneReduced, .coral50Reduced: true
        default: false
        }
    }

    var descriptor: GlassLabTintDescriptor {
        GlassLabTintDescriptor(
            label: displayName,
            color: color,
            reducedTintOpacity: reducedTintOpacity
        )
    }

    static let semanticCases: [Self] = [
        .none,
        .coral25,
        .coral50,
        .coral100,
        .cyan50,
    ]

    static let transitionCases: [Self] = semanticCases

    private static func makeColor(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> NSColor {
        NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

struct GlassLabTintDescriptor: Codable, Equatable {
    let label: String
    let colorSpace: String?
    let components: [Double]?
    let reducedTintOpacity: Bool

    init(
        label: String,
        color: NSColor?,
        reducedTintOpacity: Bool
    ) {
        self.label = label
        self.reducedTintOpacity = reducedTintOpacity
        guard let converted = color?.usingColorSpace(.sRGB) else {
            colorSpace = nil
            components = nil
            return
        }
        colorSpace = String(describing: converted.colorSpace.colorSpaceModel)
        components = [
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent),
            Double(converted.alphaComponent),
        ]
    }
}

struct GlassLabTintLayerAppearanceRecord: Codable, Equatable {
    let path: String
    let layerClass: String
    let name: String?
    let opacity: Double
    let backgroundColor: String?
    let borderColor: String?
    let shadowColor: String?
    let privateColorValues: [String: String]
}

struct GlassLabAppKitTintSnapshot: Codable, Equatable {
    let model: GlassLabTuning.PassAuditSnapshot
    let presentation: GlassLabTuning.PassAuditSnapshot?
    let modelLayerAppearance: [String: GlassLabTintLayerAppearanceRecord]
    let presentationLayerAppearance: [String: GlassLabTintLayerAppearanceRecord]?
}

struct GlassLabAppKitTintEntry: Codable, Equatable {
    let variant: Int
    let material: String
    let requestedMain: Bool
    let actualMain: Bool
    let actualKey: Bool
    let tint: GlassLabTintDescriptor
    let storedTint: GlassLabTintDescriptor
    let reducedTintOpacitySetterAvailable: Bool
    let reducedTintOpacityGetterAvailable: Bool
    let storedReducedTintOpacity: Bool?
    let snapshot: GlassLabAppKitTintSnapshot
}

struct GlassLabSemanticTintEntry: Codable, Equatable {
    let roleTag: Int
    let usage: String
    let requestedMain: Bool
    let actualMain: Bool
    let actualKey: Bool
    let tint: GlassLabTintDescriptor
    let snapshot: GlassLabSemanticTransitionSnapshot
}

struct GlassLabTintStudyDocument: Codable {
    struct Context: Codable {
        let hostType: String
        let glassWidth: Double
        let glassHeight: Double
        let cornerRadius: Double
        let windowMargin: Double
        let adaptiveAppearance: Int
        let subvariant: String?
        let subdued: Bool
        let scrim: Bool
        let overridesEnabled: Bool
        let transitionAnimation: String
        let transitionDuration: Double
    }

    let formatVersion: Int
    let capturedAt: String
    let operatingSystem: String
    let context: Context
    let appKitStatic: [GlassLabAppKitTintEntry]
    let swiftUIStatic: [GlassLabSemanticTintEntry]
    let swiftUITransitions: [GlassLabMaterializeCapture]

    var report: String {
        let appKitTopologies = Set(
            appKitStatic.map(\.snapshot.model.topologySignature)
        ).count
        let appKitValues = Set(
            appKitStatic.map(\.snapshot.model.valueSignature)
        ).count
        let transitionSamples = swiftUITransitions.reduce(0) {
            $0 + $1.samples.count
        }
        return [
            "== Full Tint Study ==",
            "AppKit static: \(appKitStatic.count) rows, "
                + "\(appKitTopologies) topology signatures, "
                + "\(appKitValues) value signatures",
            "SwiftUI static: \(swiftUIStatic.count) rows",
            "SwiftUI transitions: \(swiftUITransitions.count) runs, "
                + "\(transitionSamples) samples",
            "Context: \(context.hostType) "
                + "\(Self.format(context.glassWidth))×"
                + "\(Self.format(context.glassHeight))"
                + "@\(Self.format(context.cornerRadius)) "
                + "margin \(Self.format(context.windowMargin))",
        ].joined(separator: "\n")
    }

    nonisolated private static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}

extension GlassLabTuning {
    @MainActor
    static func captureTintLayerAppearance(
        from root: CALayer?
    ) -> [String: GlassLabTintLayerAppearanceRecord] {
        guard let root else { return [:] }
        var records: [String: GlassLabTintLayerAppearanceRecord] = [:]
        var visited: Set<ObjectIdentifier> = []

        func visit(_ layer: CALayer, path: String) {
            guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
            var privateColorValues: [String: String] = [:]
            let object = layer as NSObject
            for key in [
                "contentsMultiplyColor",
                "contentsMultiplyColorSpace",
                "borderColor",
                "backgroundColor",
                "shadowColor",
            ] where object.responds(to: NSSelectorFromString(key)) {
                if let value = object.value(forKey: key) {
                    privateColorValues[key] = stableTintValueDescription(value)
                }
            }
            records[path] = GlassLabTintLayerAppearanceRecord(
                path: path,
                layerClass: String(describing: type(of: layer)),
                name: layer.name,
                opacity: Double(layer.opacity),
                backgroundColor: stableTintColorDescription(layer.backgroundColor),
                borderColor: stableTintColorDescription(layer.borderColor),
                shadowColor: stableTintColorDescription(layer.shadowColor),
                privateColorValues: privateColorValues
            )
            for (index, child) in (layer.sublayers ?? []).enumerated() {
                visit(
                    child,
                    path: "\(path).sublayers[\(index)]:"
                        + String(describing: type(of: child))
                )
            }
            if let mask = layer.mask {
                visit(
                    mask,
                    path: "\(path).mask:\(String(describing: type(of: mask)))"
                )
            }
        }

        visit(root, path: "root:\(String(describing: type(of: root)))")
        return records
    }

    nonisolated private static func stableTintValueDescription(
        _ value: Any
    ) -> String {
        let cfValue = value as CFTypeRef
        if CFGetTypeID(cfValue) == CGColor.typeID {
            return stableTintColorDescription(
                unsafeBitCast(cfValue, to: CGColor.self)
            ) ?? "nil"
        }
        if let number = value as? NSNumber {
            return String(format: "%.9g", number.doubleValue)
        }
        if let string = value as? String {
            return string
        }
        return String(describing: type(of: value))
    }

    nonisolated private static func stableTintColorDescription(
        _ color: CGColor?
    ) -> String? {
        guard let color else { return nil }
        let components = (color.components ?? []).map {
            String(format: "%.9g", Double($0))
        }.joined(separator: ",")
        let name = color.colorSpace?.name as String? ?? "unknown"
        return "\(name)[\(components)]"
    }
}
#endif
