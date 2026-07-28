//
//  GlassLabMaterializeStudy.swift
//  LiquidGlassLab
//
//  Full P1 evidence matrix for SwiftUI Glass materialize interpolation across
//  Material, Main participation, NSAppearance, backdrop luminance, Tint, and
//  insertion/removal direction.
//

#if os(macOS)
import AppKit
import Foundation

struct GlassLabMaterializeStudyDocument: Codable {
    struct Context: Codable {
        let hostType: String
        let glassWidth: Double
        let glassHeight: Double
        let cornerRadius: Double
        let windowMargin: Double
        let animationMode: GlassLabMaterializeAnimationMode
        let animationDuration: Double
        let materials: [String]
        let participation: [String]
        let appearances: [GlassLabTestAppearance]
        let backdrops: [GlassLabBackdropMode]
        let tints: [String]
        let directions: [GlassLabMaterializeDirection]
    }

    let formatVersion: Int
    let capturedAt: String
    let operatingSystem: String
    let context: Context
    let transitions: [GlassLabMaterializeCapture]

    var report: String {
        let samples = transitions.reduce(0) {
            $0 + $1.samples.count
        }
        let acceptedContexts = transitions.filter {
            $0.context.actualMain == $0.context.requestedMain
                && !$0.context.actualKey
                && $0.context.requestedAppearance.matchesName(
                    $0.context.effectiveAppearance
                )
        }.count
        return [
            "== Full P1 Materialize Coverage ==",
            "Transitions: \(transitions.count)",
            "Samples: \(samples)",
            "Accepted contexts: \(acceptedContexts)/\(transitions.count)",
            "Dimensions: 2 Material × 2 Main × 2 Appearance × "
                + "2 Backdrop × 2 Tint × 2 Direction",
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

/// Geometry spot check for the baseline-driven curve.
///
/// Endpoints already follow `shortSide` because they are read from the live
/// Recipe, so this study exists to answer the one remaining question: are the
/// normalized shapes size-invariant? It deliberately holds appearance,
/// backdrop, Tint, and direction fixed — those axes are already closed — and
/// sweeps only `shortSide` against the two public materials and both
/// participation states.
struct GlassLabMaterializeSizeStudyDocument: Codable {
    struct Context: Codable {
        let hostType: String
        let glassWidth: Double
        let shortSides: [Double]
        let cornerRadius: Double
        let windowMargin: Double
        let animationMode: GlassLabMaterializeAnimationMode
        let animationDuration: Double
        let materials: [String]
        let participation: [String]
        let appearance: GlassLabTestAppearance
        let backdrop: GlassLabBackdropMode
        let direction: GlassLabMaterializeDirection
    }

    let formatVersion: Int
    let capturedAt: String
    let operatingSystem: String
    let context: Context
    let transitions: [GlassLabMaterializeCapture]

    var report: String {
        let samples = transitions.reduce(0) { $0 + $1.samples.count }
        let accepted = transitions.filter {
            $0.context.actualMain == $0.context.requestedMain
                && !$0.context.actualKey
        }.count
        return [
            "== Materialize geometry spot check ==",
            "Transitions: \(transitions.count)",
            "Samples: \(samples)",
            "Accepted contexts: \(accepted)/\(transitions.count)",
            "shortSide: \(context.shortSides.map { String(format: "%.0f", $0) }.joined(separator: ", "))",
            "Dimensions: \(context.shortSides.count) shortSide × 2 Material × 2 Main",
        ].joined(separator: "\n")
    }
}

extension GlassLabTestAppearance {
    nonisolated func matchesName(_ effectiveName: String) -> Bool {
        switch self {
        case .system:
            true
        case .light:
            effectiveName == NSAppearance.Name.aqua.rawValue
                || effectiveName.localizedCaseInsensitiveContains("aqua")
                    && !effectiveName.localizedCaseInsensitiveContains("dark")
        case .dark:
            effectiveName == NSAppearance.Name.darkAqua.rawValue
                || effectiveName.localizedCaseInsensitiveContains("dark")
        }
    }
}
#endif
