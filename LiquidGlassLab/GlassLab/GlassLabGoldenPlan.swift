//
//  GlassLabGoldenPlan.swift
//  LiquidGlassLab
//
//  The capture plan and the conversions from the lab's per-study capture types
//  into unified rows.
//
//  The plan is data, not control flow, so the driver cannot quietly acquire an
//  axis. Every slice states the claim that requires it; a slice with no claim
//  behind it does not belong here. See Golden/CAPTURE-SPEC.md.
//

#if os(macOS)
import AppKit
import Foundation

enum GlassLabGoldenPlan {
    /// The reference geometry every core row is captured at.
    static let referenceWidth: Double = 480
    static let referenceHeight: Double = 200
    static let referenceCornerRadius: Double = 16
    static let staticAppearance = GlassLabTestAppearance.light
    static let staticBackdrop = GlassLabBackdropMode.light

    // MARK: - Static plan

    /// One context to visit. The variant/subvariant sweep happens inside it.
    struct StaticContext {
        let slice: String
        let width: Double
        let height: Double
        let cornerRadius: Double
        let main: Bool
        let key: Bool
        let subdued: Bool
        let appearance: GlassLabTestAppearance
        let host: GlassLabWindowHostType
        /// Nil sweeps all 21 variants; otherwise only these, at nil subvariant.
        let variants: [Int]?

        var sweepsEveryVariant: Bool { variants == nil }
    }

    /// Variants 1 and 2 are Regular and Clear: the two materials the strength
    /// curve ships for, and the only ones reachable from public SwiftUI.
    static let sliceVariants = [1, 2]

    /// Chosen to straddle every known cap rather than to look evenly spaced.
    /// Inner refraction amount caps at -60 (crossing at short side 75 on
    /// macOS 26 and 120 on macOS 27), inner refraction height at 20 (crossing
    /// at 80), outer refraction floors at 16 (crossing at 64). A sweep that
    /// misses a crossing cannot tell a cap from a different ratio.
    /// 200 is deliberately absent: the core product already captures it at the
    /// reference geometry, and a slice row there would collide on the cell.
    /// A learning fitting the size curve joins both by cell, not by slice.
    static let sizeSliceShortSides: [Double] = [
        16, 24, 32, 48, 64, 80, 96, 128, 300, 400, 480, 600,
    ]

    static let cornerRadiusSlice: [Double] = [0, 8, 32]

    /// `min(width, height)` must be reachable from more than one aspect ratio,
    /// or "the short side is the only geometry variable" cannot be re-derived.
    static let transposedSizes: [(width: Double, height: Double)] = [
        (200, 480), (400, 480),
    ]

    static func staticContexts() -> [StaticContext] {
        var contexts: [StaticContext] = []

        // Core: the whole variant vocabulary at one reference geometry, under
        // both controlled appearances. Appearance is an axis here and not a
        // constant because it moves resolved static values — the earlier
        // archive was captured under an uncontrolled appearance, and pinning it
        // to one value would have answered "which Variants follow appearance"
        // for only half the vocabulary.
        for appearance in GlassLabTestAppearance.controlledCases {
            for main in [false, true] {
            for subdued in [false, true] {
                contexts.append(StaticContext(
                    slice: "core",
                    width: referenceWidth,
                    height: referenceHeight,
                    cornerRadius: referenceCornerRadius,
                    main: main,
                    key: false,
                    subdued: subdued,
                    appearance: appearance,
                    host: .panel,
                    variants: nil
                ))
            }
            }
        }

        // Size: the formula classes and their caps.
        for shortSide in sizeSliceShortSides {
            for main in [false, true] {
                contexts.append(StaticContext(
                    slice: "size",
                    width: referenceWidth,
                    height: shortSide,
                    cornerRadius: referenceCornerRadius,
                    main: main,
                    key: false,
                    subdued: false,
                    appearance: staticAppearance,
                    host: .panel,
                    variants: sliceVariants
                ))
            }
        }

        // Transposed: the same short side reached with width and height swapped.
        for size in transposedSizes {
            for main in [false, true] {
                contexts.append(StaticContext(
                    slice: "transposed",
                    width: size.width,
                    height: size.height,
                    cornerRadius: referenceCornerRadius,
                    main: main,
                    key: false,
                    subdued: false,
                    appearance: staticAppearance,
                    host: .panel,
                    variants: sliceVariants
                ))
            }
        }

        // Corner radius: proving it reaches no shader input needs a second value.
        for radius in cornerRadiusSlice {
            for main in [false, true] {
                contexts.append(StaticContext(
                    slice: "cornerRadius",
                    width: referenceWidth,
                    height: referenceHeight,
                    cornerRadius: radius,
                    main: main,
                    key: false,
                    subdued: false,
                    appearance: staticAppearance,
                    host: .panel,
                    variants: sliceVariants
                ))
            }
        }

        // Key: real key participation alone selects the active branch. This is
        // the axis every other export path forbids, since the hard case the
        // harness was built for is main-without-key. It runs on the Panel
        // host because a titled Window that becomes key also becomes main,
        // which would confound the two participation states this exists to
        // separate.
        for subdued in [false, true] {
            contexts.append(StaticContext(
                slice: "key",
                width: referenceWidth,
                height: referenceHeight,
                cornerRadius: referenceCornerRadius,
                main: false,
                key: true,
                subdued: subdued,
                appearance: staticAppearance,
                host: .panel,
                variants: sliceVariants
            ))
        }

        return contexts
    }

    /// The tree is expensive per row, so it takes the core product only, plus
    /// one repeat pass for within-capture stability evidence.
    static func treeContexts() -> [StaticContext] {
        var contexts = staticContexts().filter {
            $0.slice == "core" && $0.appearance == staticAppearance
        }
        // One row per variant at nil subvariant, not a second full product:
        // enough to show the tree settles to the same signatures twice, at a
        // fraction of the cost of re-sweeping all 336 cells.
        contexts.append(StaticContext(
            slice: "repeat",
            width: referenceWidth,
            height: referenceHeight,
            cornerRadius: referenceCornerRadius,
            main: true,
            key: false,
            subdued: false,
            appearance: staticAppearance,
            host: .panel,
            variants: GlassLabTuning.variants
        ))
        // Appearance slice: one row per Variant under DarkAqua. The tree is the
        // expensive section, so this buys the whole variant vocabulary at one
        // participation state rather than a second full product. It exists to
        // answer one question — does topology follow appearance — which the
        // dynamic section can only answer for Variants 1 and 2.
        contexts.append(StaticContext(
            slice: "appearance",
            width: referenceWidth,
            height: referenceHeight,
            cornerRadius: referenceCornerRadius,
            main: true,
            key: false,
            subdued: false,
            appearance: .dark,
            host: .panel,
            variants: GlassLabTuning.variants
        ))
        return contexts
    }

    // MARK: - Dynamic plan

    struct DynamicContext {
        let slice: String
        let shortSide: Double
        let main: Bool
        let appearance: GlassLabTestAppearance
        let backdrop: GlassLabBackdropMode
        let tinted: Bool
        let direction: GlassLabMaterializeDirection
    }

    static let dynamicShortSides: [Double] = [48, 200, 400]

    static func dynamicContexts() -> [DynamicContext] {
        var contexts: [DynamicContext] = []
        for shortSide in dynamicShortSides {
            for main in [false, true] {
                for appearance in GlassLabTestAppearance.controlledCases {
                    for tinted in [false, true] {
                        for direction in GlassLabMaterializeDirection.allCases {
                            contexts.append(DynamicContext(
                                slice: "core",
                                shortSide: shortSide,
                                main: main,
                                appearance: appearance,
                                backdrop: .light,
                                tinted: tinted,
                                direction: direction
                            ))
                        }
                    }
                }
            }
        }

        // Backdrop survives as a slice even though it is proven not to reach
        // model state. Deleting an axis whose finding is "this axis does
        // nothing" deletes the finding along with it.
        for main in [false, true] {
            contexts.append(DynamicContext(
                slice: "backdrop",
                shortSide: referenceHeight,
                main: main,
                appearance: .light,
                backdrop: .dark,
                tinted: false,
                direction: .insertion
            ))
        }

        // Re-capture the four Regular/Clear × Main cells that anchor the
        // baseline geometry. Keeping these duplicates is the direct exporter's
        // repeatability evidence; `slice` distinguishes the second sweep while
        // the shared cell coordinate deliberately remains identical.
        for main in [false, true] {
            contexts.append(DynamicContext(
                slice: "repeat",
                shortSide: referenceHeight,
                main: main,
                appearance: .light,
                backdrop: .light,
                tinted: false,
                direction: .insertion
            ))
        }
        return contexts
    }
}

// MARK: - Conversions

extension GoldenCell {
    /// A static Recipe row. Appearance is recorded rather than left nil so a
    /// settled dynamic sample can be paired against its static endpoint; the
    /// previous archive could not do that comparison for exactly this reason.
    static func staticCell(
        variant: Int,
        subvariant: String?,
        context: GlassLabGoldenPlan.StaticContext,
        backdrop: GlassLabBackdropMode
    ) -> GoldenCell {
        let appearance = context.appearance
        return GoldenCell(
            variant: variant,
            subvariant: subvariant,
            main: context.main,
            key: context.key,
            subdued: context.subdued,
            appearance: appearance == .system ? nil : appearance.rawValue,
            backdrop: backdrop.rawValue,
            tint: "None",
            width: context.width,
            height: context.height,
            cornerRadius: context.cornerRadius,
            host: context.host.rawValue,
            direction: nil
        )
    }
}

extension GoldenStaticScalarRow {
    init(entry: GlassLabTuning.MatrixEntry, cell: GoldenCell, slice: String) {
        self.init(
            cell: cell,
            accepted: entry.appActive
                && entry.isActualMainWindow == entry.requestedMain,
            participation: entry.participation,
            slice: slice,
            passes: Passes(
                shader: entry.hasShaderPass,
                highlight: entry.hasHighlightPass
            ),
            inputs: entry.inputs,
            highlight: entry.highlight,
            geometry: entry.geometry,
            colors: entry.shaderColors.merging(entry.highlightColors) { first, _ in
                first
            },
            points: entry.shaderPoints,
            strings: entry.shaderStrings
        )
    }
}

extension GoldenStaticTreeRow {
    init(entry: GlassLabTuning.PassAuditEntry, cell: GoldenCell, slice: String) {
        self.init(
            cell: cell,
            accepted: entry.appActive
                && entry.isActualMainWindow == entry.requestedMain,
            participation: entry.participation,
            slice: slice,
            topologySignature: entry.snapshot.topologySignature,
            valueSignature: entry.snapshot.valueSignature,
            layers: entry.snapshot.layers,
            passes: entry.snapshot.passes
        )
    }
}

extension GoldenDynamicSample {
    /// Model side only. `presentation`, `presentationLayers`, `modelLayers`,
    /// and `animations` are dropped: no accepted learning reads them, and
    /// together they were 70% of the archive's bytes. `layerLines` stays
    /// because the SDF inflation claim parses element frames out of it.
    @MainActor
    init(sample: GlassLabMaterializeSample) {
        let model = sample.snapshot.model
        let filters = model.filters.map { filter in
            Filter(
                name: filter.name,
                path: filter.path,
                layerClass: filter.layerClass,
                location: filter.location,
                inputs: Dictionary(
                    filter.inputs.map { ($0.key, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        let face = filters
            .first { $0.name == "glassBackground" }?
            .inputs["inputFaceOpacity"]
            .flatMap(Double.init)
        self.init(
            progress: face,
            requestedProgress: sample.requestedProgress,
            elapsed: sample.elapsed,
            phase: sample.phase,
            filters: filters,
            effects: model.effects.map { effect in
                Effect(
                    effectClass: effect.effectClass,
                    path: effect.path,
                    layerClass: effect.layerClass,
                    layerOpacity: effect.layerOpacity,
                    inputs: Dictionary(
                        effect.inputs.map { ($0.key, $0.value) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            },
            layerLines: model.layerLines
        )
    }
}

extension GoldenDynamicRun {
    @MainActor
    init(capture: GlassLabMaterializeCapture, slice: String) {
        let context = capture.context
        // Regular and Clear are addressed by their private variant index here
        // so the dynamic and static sections share one axis, rather than one
        // naming materials and the other numbering them.
        let variant = capture.usage.contains("Clear") ? 2 : 1
        self.init(
            cell: GoldenCell(
                variant: variant,
                subvariant: nil,
                main: context.requestedMain,
                key: context.actualKey,
                // SwiftUI Materialize exposes no Subdued concept, so this axis
                // is genuinely uncontrolled rather than false.
                subdued: nil,
                appearance: context.requestedAppearance == .system
                    ? nil
                    : context.requestedAppearance.rawValue,
                backdrop: context.backdrop.rawValue,
                tint: context.tint.label,
                width: context.glassWidth,
                height: context.glassHeight,
                cornerRadius: context.cornerRadius,
                host: context.hostType,
                direction: capture.direction.rawValue.lowercased()
            ),
            accepted: context.actualMain == context.requestedMain
                && !context.actualKey
                && context.requestedAppearance.matchesName(
                    context.effectiveAppearance
                ),
            slice: slice,
            usage: capture.usage,
            effectiveAppearance: context.effectiveAppearance,
            tintComponents: context.tint.components,
            animationMode: capture.animationMode.rawValue,
            maximumAttachedAnimationDuration:
                capture.maximumAttachedAnimationDuration,
            samples: capture.samples.map(GoldenDynamicSample.init(sample:))
        )
    }
}
#endif
