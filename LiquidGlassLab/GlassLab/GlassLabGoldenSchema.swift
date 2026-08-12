//
//  GlassLabGoldenSchema.swift
//  LiquidGlassLab
//
//  The unified Golden archive schema, written directly by the exporter.
//
//  Every row of every section is addressed by the same `GoldenCell`, which is
//  what makes cross-version and cross-section comparison a key match instead of
//  a pairing routine written once per fixture. The contract is specified in
//  Golden/CAPTURE-SPEC.md and mirrored on the reading side by
//  Golden/tools/lib/cell.mjs; the two must be changed together.
//

#if os(macOS)
import AppKit
import Foundation

let goldenSchemaVersion = 1

/// One coordinate in the archive.
///
/// A field is `nil` when the capture did not control that axis. Nil is not
/// `false` and not a default — it means unknown, and a learning that needs the
/// axis skips rather than guessing. Encoding keeps nils so a row states its own
/// holes rather than leaving a reader to infer them from absence.
struct GoldenCell: Codable, Hashable {
    var variant: Int?
    var subvariant: String?
    var main: Bool?
    var key: Bool?
    var subdued: Bool?
    var appearance: String?
    var backdrop: String?
    var tint: String?
    var width: Double?
    var height: Double?
    var cornerRadius: Double?
    var host: String?
    var direction: String?

    /// Geometry reaches the renderer only through the short side, so this is
    /// derived rather than recorded: no capture can disagree with itself.
    var shortSide: Double? {
        guard let width, let height else { return nil }
        return min(width, height)
    }

    enum CodingKeys: String, CodingKey {
        case variant, subvariant, main, key, subdued, appearance, backdrop
        case tint, width, height, cornerRadius, host, direction, shortSide
    }

    /// `shortSide` is written for readers but never read back: it is derived,
    /// so accepting it from a file would let a stale value contradict the
    /// width and height it is supposed to summarize.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variant = try container.decodeIfPresent(Int.self, forKey: .variant)
        subvariant = try container.decodeIfPresent(String.self, forKey: .subvariant)
        main = try container.decodeIfPresent(Bool.self, forKey: .main)
        key = try container.decodeIfPresent(Bool.self, forKey: .key)
        subdued = try container.decodeIfPresent(Bool.self, forKey: .subdued)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance)
        backdrop = try container.decodeIfPresent(String.self, forKey: .backdrop)
        tint = try container.decodeIfPresent(String.self, forKey: .tint)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
    }

    init(
        variant: Int? = nil,
        subvariant: String? = nil,
        main: Bool? = nil,
        key: Bool? = nil,
        subdued: Bool? = nil,
        appearance: String? = nil,
        backdrop: String? = nil,
        tint: String? = nil,
        width: Double? = nil,
        height: Double? = nil,
        cornerRadius: Double? = nil,
        host: String? = nil,
        direction: String? = nil
    ) {
        self.variant = variant
        self.subvariant = subvariant
        self.main = main
        self.key = key
        self.subdued = subdued
        self.appearance = appearance
        self.backdrop = backdrop
        self.tint = tint
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.host = host
        self.direction = direction
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variant, forKey: .variant)
        try container.encode(subvariant, forKey: .subvariant)
        try container.encode(main, forKey: .main)
        try container.encode(key, forKey: .key)
        try container.encode(subdued, forKey: .subdued)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(backdrop, forKey: .backdrop)
        try container.encode(tint, forKey: .tint)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(host, forKey: .host)
        try container.encode(direction, forKey: .direction)
        try container.encode(shortSide, forKey: .shortSide)
    }

    /// Stable string identity, matching `cellKey` in cell.mjs. Used for
    /// duplicate detection during export; the reader recomputes its own.
    var identity: String {
        func token(_ value: Any?) -> String {
            switch value {
            case nil: return "-"
            case let flag as Bool: return flag ? "1" : "0"
            case let number as Double:
                return number == number.rounded()
                    ? String(Int(number))
                    : String(format: "%.6g", number)
            case let other?: return String(describing: other)
            }
        }
        return [
            "variant=\(token(variant))",
            "subvariant=\(token(subvariant))",
            "main=\(token(main))",
            "key=\(token(key))",
            "subdued=\(token(subdued))",
            "appearance=\(token(appearance))",
            "backdrop=\(token(backdrop))",
            "tint=\(token(tint))",
            "width=\(token(width))",
            "height=\(token(height))",
            "cornerRadius=\(token(cornerRadius))",
            "host=\(token(host))",
            "direction=\(token(direction))",
        ].joined(separator: "|")
    }
}

// MARK: - Complete settled renderer snapshot

/// One typed value read from the resolved Core Animation tree. The archive
/// keeps the original value kind instead of flattening everything to text, so
/// scalar analysis, recursive comparison, and Consumer projection are views of
/// the same observation.
indirect enum GoldenResolvedValue: Codable, Equatable {
    case boolean(Bool)
    case number(Double)
    case string(String)
    case color(GoldenResolvedColor)
    case point(GoldenResolvedPair)
    case size(GoldenResolvedPair)
    case rect(GoldenResolvedRect)
    case matrix(GoldenResolvedMatrix)
    case array([GoldenResolvedValue])
    case dictionary([String: GoldenResolvedValue])
    /// Research evidence may retain an unfamiliar readable type without
    /// pretending it is safe to replay. Replay-critical projections reject it.
    case opaque(type: String)
}

struct GoldenResolvedColor: Codable, Equatable {
    /// Core Graphics color-space identity as captured, not merely its model.
    let colorSpaceName: String?
    let model: String
    let components: [Double]
    /// The Consumer projection is explicitly extended-sRGB. Keeping this
    /// conversion next to the source components makes it deterministic without
    /// erasing the original color-space identity used by research comparisons.
    let extendedSRGB: GlassMaterialColorValue?
}

struct GoldenResolvedPair: Codable, Equatable {
    let x: Double
    let y: Double
}

struct GoldenResolvedRect: Codable, Equatable {
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

struct GoldenResolvedMatrix: Codable, Equatable {
    let objCType: String
    let coefficients: [Double]
}

enum GoldenResolvedPropertyState: String, Codable {
    case value
    case nilValue = "nil"
    case unreadable
}

struct GoldenResolvedProperty: Codable, Equatable {
    let state: GoldenResolvedPropertyState
    let value: GoldenResolvedValue?
    let attributes: [String: String]
}

struct GoldenResolvedLayer: Codable, Equatable {
    let path: String
    let layerClass: String
    let name: String?
    let frame: GoldenResolvedRect
    let bounds: GoldenResolvedRect
    let opacity: Double
    let isHidden: Bool
    let masksToBounds: Bool
    let cornerRadius: Double
    let hasMask: Bool
    /// Replay-critical private layer properties, currently marginWidth.
    let properties: [String: GoldenResolvedProperty]
}

struct GoldenResolvedPass: Codable, Equatable {
    let id: String
    let order: Int
    let layerPath: String
    let layerClass: String
    let location: String
    let objectClass: String
    let name: String?
    let properties: [String: GoldenResolvedProperty]
}

struct GoldenResolvedSnapshot: Codable, Equatable {
    let shortSide: Double
    let layers: [GoldenResolvedLayer]
    let passes: [GoldenResolvedPass]
}

// MARK: - Section 1: static-scalar

struct GoldenStaticScalarRow: Codable {
    let cell: GoldenCell
    /// Whether the requested participation was actually observed. A row that is
    /// not accepted is never written; the flag exists so a reader can assert it
    /// rather than trust the exporter.
    let accepted: Bool
    let participation: String
    let slice: String
    let passes: Passes
    let inputs: [String: Double]
    let highlight: [String: Double]
    let geometry: [String: Double]
    let colors: [String: String]
    let points: [String: GlassLabTuning.MatrixEntry.PointValue]
    let strings: [String: String]

    struct Passes: Codable {
        let shader: Bool
        let highlight: Bool
    }
}

struct GoldenStaticScalarDocument: Codable {
    let schemaVersion: Int
    let section: String
    let capturedAt: String
    let operatingSystem: String
    let environment: GoldenEnvironment
    /// Declared inputs are identical on every row, so one copy is enough.
    let capability: Capability
    let rows: [GoldenStaticScalarRow]

    struct Capability: Codable {
        let shaderInputKeys: [String]
        let highlightInputKeys: [String]
        let geometryKeys: [String]
    }
}

// MARK: - Section 2: static-tree

struct GoldenStaticTreeRow: Codable {
    let cell: GoldenCell
    let accepted: Bool
    let participation: String
    let slice: String
    let topologySignature: String
    let valueSignature: String
    let layers: [String: GlassLabTuning.PassAuditLayerRecord]
    let passes: [String: GlassLabTuning.PassAuditPassRecord]
}

struct GoldenStaticTreeDocument: Codable {
    let schemaVersion: Int
    let section: String
    let capturedAt: String
    let operatingSystem: String
    let environment: GoldenEnvironment
    let rows: [GoldenStaticTreeRow]
}

// MARK: - Section 3: dynamic

struct GoldenDynamicSample: Codable {
    /// Observed progress, not requested: the renderer is the source of truth
    /// for where the transition actually was when it was sampled.
    let progress: Double?
    let requestedProgress: Double
    let elapsed: Double
    let phase: String
    let filters: [Filter]
    let effects: [Effect]
    let layerLines: [String]

    struct Filter: Codable {
        let name: String
        let path: String
        let layerClass: String
        let location: String
        let inputs: [String: String]
    }

    struct Effect: Codable {
        let effectClass: String
        let path: String
        let layerClass: String
        let layerOpacity: Double?
        let inputs: [String: String]
    }
}

struct GoldenDynamicRun: Codable {
    let cell: GoldenCell
    let accepted: Bool
    let slice: String
    let usage: String
    let effectiveAppearance: String
    let tintComponents: [Double]?
    let animationMode: String
    let maximumAttachedAnimationDuration: Double
    let samples: [GoldenDynamicSample]
}

struct GoldenDynamicDocument: Codable {
    let schemaVersion: Int
    let section: String
    let capturedAt: String
    let operatingSystem: String
    let environment: GoldenEnvironment
    let runs: [GoldenDynamicRun]
}

// MARK: - Shared

/// Conditions held constant across a whole capture. Anything that varies row to
/// row belongs in the cell instead, or it cannot be compared.
struct GoldenEnvironment: Codable {
    let windowMargin: Double
    let scrim: Bool
    let reducedTintOpacity: Bool
    let adaptiveAppearance: Int
    let overridesEnabled: Bool
}

struct GoldenMeta: Codable {
    let schemaVersion: Int
    let operatingSystem: String
    let capturedAt: String
    /// Written by the exporter, so unlike the transcoded archive this is
    /// primary evidence rather than derived output.
    let role: String
    let sections: [String: Section]

    struct Section: Codable {
        let file: String
        let rows: Int
        let repeatedCells: Int
        let bytes: Int
        let sha256: String
        let swept: [String]
        let slices: [String: Int]
    }
}
#endif
