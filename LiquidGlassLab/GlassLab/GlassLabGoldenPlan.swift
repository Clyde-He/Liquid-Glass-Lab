//
//  GlassLabGoldenPlan.swift
//  LiquidGlassLab
//
//  The capture plan and the conversions from the lab's per-study capture types
//  into observations.
//
//  The plan is data, not control flow, so the driver cannot quietly acquire an
//  axis. Product and research requirements share this one coordinate list; an
//  overlapping coordinate is observed once. See Golden/CAPTURE-SPEC.md.
//

#if os(macOS)
import AppKit
import Foundation

enum GlassLabGoldenPlan {
    static let approvedStaticObservationCount = 776
    static let approvedConsumerCount = 56
    static let approvedDriftObservationCount = 28
    static let approvedDriftConsumerCount = 24
    /// The reference geometry every core row is captured at.
    static let referenceWidth: Double = 480
    static let referenceHeight: Double = 200
    static let referenceCornerRadius: Double = 16
    static let staticAppearance = GlassLabTestAppearance.light
    static let staticBackdrop = GlassLabBackdropMode.light
    /// One canonical model-tree context serves research and Consumer projection.
    /// Window padding affects visible pixels, not the resolved values captured here.
    static let staticWindowPadding: Double = 120

    // MARK: - Static plan

    /// One exact settled renderer observation. `label` and `requiresCatalog`
    /// are plan-only metadata and are never persisted as evidence identity.
    struct StaticContext {
        let label: String
        let width: Double
        let height: Double
        let cornerRadius: Double
        let main: Bool
        let key: Bool
        let subdued: Bool
        let appearance: GlassLabTestAppearance
        let host: GlassLabWindowHostType
        let variant: Int
        let subvariant: String?
        let requiresCatalog: Bool

        var cell: GoldenCell {
            .staticCell(context: self, backdrop: staticBackdrop)
        }
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

    /// Exact runtime interpolation anchors. These coordinates are ordinary
    /// Static observations; Catalog is only a projection over this subset.
    static let catalogShortSides: [Double] = [48, 64, 96, 128, 160, 200, 320]

    static let cornerRadiusSlice: [Double] = [0, 8, 32]

    /// `min(width, height)` must be reachable from more than one aspect ratio,
    /// or "the short side is the only geometry variable" cannot be re-derived.
    static let transposedSizes: [(width: Double, height: Double)] = [
        (200, 480), (400, 480),
    ]

    static func staticContexts() -> [StaticContext] {
        var contexts: [StaticContext] = []
        var indexByIdentity: [String: Int] = [:]

        func append(
            label: String,
            width: Double,
            height: Double,
            cornerRadius: Double,
            main: Bool,
            key: Bool,
            subdued: Bool,
            appearance: GlassLabTestAppearance,
            host: GlassLabWindowHostType = .panel,
            variant: Int,
            subvariant: String?,
            requiresCatalog: Bool = false
        ) {
            let candidate = StaticContext(
                label: label,
                width: width,
                height: height,
                cornerRadius: cornerRadius,
                main: main,
                key: key,
                subdued: subdued,
                appearance: appearance,
                host: host,
                variant: variant,
                subvariant: subvariant,
                requiresCatalog: requiresCatalog
            )
            let identity = candidate.cell.identity
            if let index = indexByIdentity[identity] {
                if requiresCatalog, !contexts[index].requiresCatalog {
                    let existing = contexts[index]
                    contexts[index] = StaticContext(
                        label: existing.label,
                        width: existing.width,
                        height: existing.height,
                        cornerRadius: existing.cornerRadius,
                        main: existing.main,
                        key: existing.key,
                        subdued: existing.subdued,
                        appearance: existing.appearance,
                        host: existing.host,
                        variant: existing.variant,
                        subvariant: existing.subvariant,
                        requiresCatalog: true
                    )
                }
                return
            }
            indexByIdentity[identity] = contexts.count
            contexts.append(candidate)
        }

        // Research core: the whole variant vocabulary at one reference
        // geometry under both controlled appearances.
        for appearance in GlassLabTestAppearance.controlledCases {
            for main in [false, true] {
                for subdued in [false, true] {
                    for variant in GlassLabTuning.variants {
                        for subvariant in [nil]
                            + GlassLabTuning.knownSubvariants.map(Optional.some) {
                            append(
                                label: "research-core",
                                width: referenceWidth,
                                height: referenceHeight,
                                cornerRadius: referenceCornerRadius,
                                main: main,
                                key: false,
                                subdued: subdued,
                                appearance: appearance,
                                variant: variant,
                                subvariant: subvariant
                            )
                        }
                    }
                }
            }
        }

        // Research size: the formula classes and their caps.
        for shortSide in sizeSliceShortSides {
            for main in [false, true] {
                for variant in sliceVariants {
                    append(
                        label: "research-size",
                        width: referenceWidth,
                        height: shortSide,
                        cornerRadius: referenceCornerRadius,
                        main: main,
                        key: false,
                        subdued: false,
                        appearance: staticAppearance,
                        variant: variant,
                        subvariant: nil
                    )
                }
            }
        }

        // Research transposed: one short side through two aspect ratios.
        for size in transposedSizes {
            for main in [false, true] {
                for variant in sliceVariants {
                    append(
                        label: "research-transposed",
                        width: size.width,
                        height: size.height,
                        cornerRadius: referenceCornerRadius,
                        main: main,
                        key: false,
                        subdued: false,
                        appearance: staticAppearance,
                        variant: variant,
                        subvariant: nil
                    )
                }
            }
        }

        // Research corner radius.
        for radius in cornerRadiusSlice {
            for main in [false, true] {
                for variant in sliceVariants {
                    append(
                        label: "research-corner-radius",
                        width: referenceWidth,
                        height: referenceHeight,
                        cornerRadius: radius,
                        main: main,
                        key: false,
                        subdued: false,
                        appearance: staticAppearance,
                        variant: variant,
                        subvariant: nil
                    )
                }
            }
        }

        // Key: real key participation alone selects the active branch. This is
        // the axis every other export path forbids, since the hard case the
        // harness was built for is main-without-key. It runs on the Panel
        // host because a titled Window that becomes key also becomes main,
        // which would confound the two participation states this exists to
        // separate.
        for subdued in [false, true] {
            for variant in sliceVariants {
                append(
                    label: "research-key",
                    width: referenceWidth,
                    height: referenceHeight,
                    cornerRadius: referenceCornerRadius,
                    main: false,
                    key: true,
                    subdued: subdued,
                    appearance: staticAppearance,
                    variant: variant,
                    subvariant: nil
                )
            }
        }

        // Product interpolation grid. The append operation unions its 24
        // overlaps with research instead of acquiring them a second time.
        for appearance in GlassLabTestAppearance.controlledCases {
            for variant in sliceVariants {
                for main in [false, true] {
                    for shortSide in catalogShortSides {
                        append(
                            label: "product",
                            width: referenceWidth,
                            height: shortSide,
                            cornerRadius: referenceCornerRadius,
                            main: main,
                            key: false,
                            subdued: false,
                            appearance: appearance,
                            variant: variant,
                            subvariant: nil,
                            requiresCatalog: true
                        )
                    }
                }
            }
        }

        return contexts
    }

    static func catalogContexts() -> [StaticContext] {
        staticContexts().filter(\.requiresCatalog)
    }

    /// These are small reviewed shape pins, colocated with the one coordinate
    /// authority. They catch an accidental plan edit before an hours-long run;
    /// readers validate emitted observations structurally rather than copying
    /// the numbers or coordinate tables.
    static func fullPlanIsApproved() -> Bool {
        let contexts = staticContexts()
        let consumers = contexts.filter(\.requiresCatalog)
        let consumerGroups = Dictionary(grouping: consumers) {
            "\($0.appearance.rawValue)|\($0.variant)|\($0.main)"
        }
        return contexts.count == approvedStaticObservationCount
            && Set(contexts.map(\.cell.identity)).count == contexts.count
            && consumers.count == approvedConsumerCount
            && Set(consumers.map(\.cell.identity)).count == consumers.count
            && consumerGroups.count == 8
            && consumerGroups.values.allSatisfy { group in
                group.count == catalogShortSides.count
                    && Set(group.map { min($0.width, $0.height) })
                        == Set(catalogShortSides)
            }
    }

    /// Fixed quick signal, captured by the same walker as Full. Twenty-four
    /// product anchors cover both appearances, variants, and participation at
    /// 48/200/320 points; Variant 4 and 6 add adaptive/alternate topology.
    static func driftContexts() -> [StaticContext] {
        let sizeSentinels = Set<Double>([48, 200, 320])
        let product = catalogContexts().filter {
            sizeSentinels.contains(min($0.width, $0.height))
        }
        let research = staticContexts().filter {
            $0.label == "research-core"
                && [4, 6].contains($0.variant)
                && $0.subvariant == nil
                && $0.appearance == .light
                && $0.main
                && !$0.key
        }
        return product + research
    }

    static func driftPlanIsApproved() -> Bool {
        let full = Set(staticContexts().map(\.cell.identity))
        let contexts = driftContexts()
        let consumers = contexts.filter(\.requiresCatalog)
        return contexts.count == approvedDriftObservationCount
            && Set(contexts.map(\.cell.identity)).count == contexts.count
            && consumers.count == approvedDriftConsumerCount
            && contexts.allSatisfy { full.contains($0.cell.identity) }
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
    /// One exact static Recipe condition.
    static func staticCell(
        context: GlassLabGoldenPlan.StaticContext,
        backdrop: GlassLabBackdropMode
    ) -> GoldenCell {
        let appearance = context.appearance
        return GoldenCell(
            variant: context.variant,
            subvariant: context.subvariant,
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
