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
    static let legacyStaticObservationCount = 776
    static let macOS27StaticObservationCount = 1_750
    static let legacyDynamicRunCount = 104
    static let macOS27DynamicRunCount = 273
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
    struct StaticContext: Codable, Equatable {
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
        var requiresCatalog: Bool
        var backdrop: GlassLabBackdropMode = .light
        var tintPreset: GlassLabTintPreset = .none
        var glassAmount: Double? = nil

        var cell: GoldenCell {
            .staticCell(context: self, backdrop: backdrop)
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

    static let glassGeometryShortSides: [Double] = [
        48, 64, 72, 80, 88, 96, 100, 104, 112, 120, 128, 136, 144, 152,
        160, 200, 320,
    ]
    static let glassScaleShortSides: [Double] = [48, 64, 96, 120, 160, 200, 320]
    static let glassScaleAmounts: [Double] = [
        0, 0.75, 0.8, 0.85, 0.875, 0.9, 0.925, 0.95, 0.975, 0.99, 1,
    ]
    static let glassAnchorAmounts: [Double] = [0, 0.5, 1]
    static let glassSentinelAmounts: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let glassBoundaryAmounts: [Double] = [0, 0.0001, 0.4999, 0.5, 0.5001, 1]

    static var currentOSMajor: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static func staticContexts(osMajor: Int = currentOSMajor) -> [StaticContext] {
        let baselineAmount: Double? = osMajor == 27 ? 0.5 : nil
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
            requiresCatalog: Bool = false,
            backdrop: GlassLabBackdropMode = .light,
            tintPreset: GlassLabTintPreset = .none,
            glassAmount: Double? = nil
        ) {
            var candidate = StaticContext(
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
            candidate.backdrop = backdrop
            candidate.tintPreset = tintPreset
            candidate.glassAmount = glassAmount
            let identity = candidate.cell.identity
            if let index = indexByIdentity[identity] {
                if requiresCatalog, !contexts[index].requiresCatalog {
                    contexts[index].requiresCatalog = true
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
                                subvariant: subvariant,
                                glassAmount: baselineAmount
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
                        subvariant: nil,
                        glassAmount: baselineAmount
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
                        subvariant: nil,
                        glassAmount: baselineAmount
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
                        subvariant: nil,
                        glassAmount: baselineAmount
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
                    subvariant: nil,
                    glassAmount: baselineAmount
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
                            requiresCatalog: true,
                            glassAmount: baselineAmount
                        )
                    }
                }
            }
        }

        guard osMajor == 27 else { return contexts }

        func appendConsumer(
            label: String,
            shortSides: [Double],
            amounts: [Double],
            tintPreset: GlassLabTintPreset = .none
        ) {
            for appearance in GlassLabTestAppearance.controlledCases {
                for variant in sliceVariants {
                    for main in [false, true] {
                        for shortSide in shortSides {
                            for amount in amounts {
                                append(
                                    label: label,
                                    width: referenceWidth,
                                    height: shortSide,
                                    cornerRadius: referenceCornerRadius,
                                    main: main,
                                    key: false,
                                    subdued: false,
                                    appearance: appearance,
                                    variant: variant,
                                    subvariant: nil,
                                    tintPreset: tintPreset,
                                    glassAmount: amount
                                )
                            }
                        }
                    }
                }
            }
        }

        // macOS 27 transparency is a sparse axis over the same canonical
        // Static observation space. Each coordinate is captured once, and the
        // model, geometry, scale and boundary learnings select their subsets.
        appendConsumer(
            label: "glass-model-anchor",
            shortSides: catalogShortSides,
            amounts: glassAnchorAmounts
        )
        appendConsumer(
            label: "glass-geometry",
            shortSides: glassGeometryShortSides,
            amounts: [0, 0.75, 1]
        )
        appendConsumer(
            label: "glass-scale",
            shortSides: glassScaleShortSides,
            amounts: glassScaleAmounts
        )
        appendConsumer(
            label: "glass-quarter",
            shortSides: [48, 200, 320],
            amounts: [0.25, 0.75]
        )
        appendConsumer(
            label: "glass-quarter",
            shortSides: [72, 104, 112, 120],
            amounts: [0.25]
        )

        // Non-Consumer topology sentinels retain the alternate/adaptive
        // branches at all five interpolation anchors.
        for variant in [4, 6] {
            for subdued in [false, true] {
                for amount in glassSentinelAmounts {
                    append(
                        label: "glass-nonconsumer-sentinel",
                        width: referenceWidth,
                        height: referenceHeight,
                        cornerRadius: referenceCornerRadius,
                        main: true,
                        key: false,
                        subdued: subdued,
                        appearance: .light,
                        variant: variant,
                        subvariant: nil,
                        glassAmount: amount
                    )
                }
            }
        }

        // Tint interaction is kept in Static because it is still one settled
        // native renderer state, just with a non-nil public tint input.
        appendConsumer(
            label: "glass-tint-interaction",
            shortSides: [referenceHeight],
            amounts: glassSentinelAmounts,
            tintPreset: .coral50
        )

        // The Clear Main+Key branch changes topology around the midpoint and
        // therefore receives close probes on both sides of 0.5.
        for amount in glassBoundaryAmounts {
            append(
                label: "glass-clear-key-boundary",
                width: referenceWidth,
                height: referenceHeight,
                cornerRadius: referenceCornerRadius,
                main: true,
                key: true,
                subdued: false,
                appearance: .light,
                host: .window,
                variant: 2,
                subvariant: nil,
                glassAmount: amount
            )
        }

        return contexts
    }

    static func catalogContexts(osMajor: Int = currentOSMajor) -> [StaticContext] {
        staticContexts(osMajor: osMajor).filter(\.requiresCatalog)
    }

    /// These are small reviewed shape pins, colocated with the one coordinate
    /// authority. They catch an accidental plan edit before a full run;
    /// readers validate emitted observations structurally rather than copying
    /// the numbers or coordinate tables.
    static func fullPlanIsApproved(osMajor: Int = currentOSMajor) -> Bool {
        let contexts = staticContexts(osMajor: osMajor)
        let consumers = contexts.filter(\.requiresCatalog)
        let consumerGroups = Dictionary(grouping: consumers) {
            "\($0.appearance.rawValue)|\($0.variant)|\($0.main)"
        }
        let expectedCount = osMajor == 27
            ? macOS27StaticObservationCount
            : legacyStaticObservationCount
        return contexts.count == expectedCount
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
    static func driftContexts(osMajor: Int = currentOSMajor) -> [StaticContext] {
        let sizeSentinels = Set<Double>([48, 200, 320])
        let product = catalogContexts(osMajor: osMajor).filter {
            sizeSentinels.contains(min($0.width, $0.height))
        }
        let research = staticContexts(osMajor: osMajor).filter {
            $0.label == "research-core"
                && [4, 6].contains($0.variant)
                && $0.subvariant == nil
                && $0.appearance == .light
                && $0.main
                && !$0.key
        }
        return product + research
    }

    static func driftPlanIsApproved(osMajor: Int = currentOSMajor) -> Bool {
        let full = Set(staticContexts(osMajor: osMajor).map(\.cell.identity))
        let contexts = driftContexts(osMajor: osMajor)
        let consumers = contexts.filter(\.requiresCatalog)
        return contexts.count == approvedDriftObservationCount
            && Set(contexts.map(\.cell.identity)).count == contexts.count
            && consumers.count == approvedDriftConsumerCount
            && contexts.allSatisfy { full.contains($0.cell.identity) }
    }

    // MARK: - Dynamic plan

    struct DynamicContext: Equatable {
        let slice: String
        let shortSide: Double
        let main: Bool
        let appearance: GlassLabTestAppearance
        let backdrop: GlassLabBackdropMode
        let tintPreset: GlassLabTintPreset
        let usage: GlassLabSemanticUsage
        let direction: GlassLabMaterializeDirection
        let animationMode: GlassLabMaterializeAnimationMode
        let glassAmount: Double?

        var lifecycleIdentity: String {
            [
                slice, String(shortSide), String(main), appearance.rawValue,
                backdrop.rawValue, tintPreset.descriptor.label,
                usage.displayName, animationMode.rawValue,
                glassAmount.map { String($0) } ?? "-",
            ].joined(separator: "|")
        }

        var identity: String {
            lifecycleIdentity + "|" + direction.rawValue
        }
    }

    static let dynamicShortSides: [Double] = [48, 200, 400]

    static func dynamicContexts(osMajor: Int = currentOSMajor) -> [DynamicContext] {
        let baselineAmount: Double? = osMajor == 27 ? 0.5 : nil
        var contexts: [DynamicContext] = []
        var identities = Set<String>()

        func append(
            slice: String,
            shortSide: Double,
            main: Bool,
            appearance: GlassLabTestAppearance,
            backdrop: GlassLabBackdropMode,
            tintPreset: GlassLabTintPreset,
            usage: GlassLabSemanticUsage,
            direction: GlassLabMaterializeDirection,
            animationMode: GlassLabMaterializeAnimationMode,
            glassAmount: Double?
        ) {
            let candidate = DynamicContext(
                slice: slice,
                shortSide: shortSide,
                main: main,
                appearance: appearance,
                backdrop: backdrop,
                tintPreset: tintPreset,
                usage: usage,
                direction: direction,
                animationMode: animationMode,
                glassAmount: glassAmount
            )
            guard identities.insert(candidate.identity).inserted else { return }
            contexts.append(candidate)
        }

        for shortSide in dynamicShortSides {
            for main in [false, true] {
                for appearance in GlassLabTestAppearance.controlledCases {
                    for tinted in [false, true] {
                        for usage in [GlassLabSemanticUsage.regular, .clear] {
                            for direction in GlassLabMaterializeDirection.allCases {
                                append(
                                    slice: "core",
                                    shortSide: shortSide,
                                    main: main,
                                    appearance: appearance,
                                    backdrop: .light,
                                    tintPreset: tinted ? .coral50 : .none,
                                    usage: usage,
                                    direction: direction,
                                    animationMode: .linear,
                                    glassAmount: baselineAmount
                                )
                            }
                        }
                    }
                }
            }
        }

        // Backdrop survives as a slice even though it is proven not to reach
        // model state. Deleting an axis whose finding is "this axis does
        // nothing" deletes the finding along with it.
        for main in [false, true] {
            for usage in [GlassLabSemanticUsage.regular, .clear] {
                append(
                    slice: "backdrop",
                    shortSide: referenceHeight,
                    main: main,
                    appearance: .light,
                    backdrop: .dark,
                    tintPreset: .none,
                    usage: usage,
                    direction: .insertion,
                    animationMode: .linear,
                    glassAmount: baselineAmount
                )
            }
        }

        // Re-capture the four Regular/Clear × Main cells that anchor the
        // baseline geometry. Keeping these duplicates is the direct exporter's
        // repeatability evidence; `slice` distinguishes the second sweep while
        // the shared cell coordinate deliberately remains identical.
        for main in [false, true] {
            for usage in [GlassLabSemanticUsage.regular, .clear] {
                append(
                    slice: "repeat",
                    shortSide: referenceHeight,
                    main: main,
                    appearance: .light,
                    backdrop: .light,
                    tintPreset: .none,
                    usage: usage,
                    direction: .insertion,
                    animationMode: .linear,
                    glassAmount: baselineAmount
                )
            }
        }

        if osMajor == 27 {
            typealias Condition = (
                slice: String, shortSide: Double, main: Bool,
                appearance: GlassLabTestAppearance,
                backdrop: GlassLabBackdropMode,
                tintPreset: GlassLabTintPreset,
                usage: GlassLabSemanticUsage
            )
            var conditions: [Condition] = []

            for appearance in GlassLabTestAppearance.controlledCases {
                for main in [false, true] {
                    for usage in [GlassLabSemanticUsage.regular, .clear] {
                        conditions.append((
                            "core", referenceHeight, main, appearance,
                            .light, .none, usage
                        ))
                    }
                }
            }
            for shortSide in [48.0, 400.0] {
                conditions.append((
                    "core", shortSide, true, .light,
                    .light, .none, .regular
                ))
            }
            conditions.append((
                "backdrop", referenceHeight, true, .light,
                .dark, .none, .regular
            ))
            conditions.append((
                "core", referenceHeight, true, .light,
                .light, .coral50, .regular
            ))

            for condition in conditions {
                for amount in glassSentinelAmounts {
                    for direction in GlassLabMaterializeDirection.allCases {
                        append(
                            slice: condition.slice,
                            shortSide: condition.shortSide,
                            main: condition.main,
                            appearance: condition.appearance,
                            backdrop: condition.backdrop,
                            tintPreset: condition.tintPreset,
                            usage: condition.usage,
                            direction: direction,
                            animationMode: .linear,
                            glassAmount: amount
                        )
                    }
                }
                for amount in glassAnchorAmounts {
                    for direction in GlassLabMaterializeDirection.allCases {
                        append(
                            slice: condition.slice,
                            shortSide: condition.shortSide,
                            main: condition.main,
                            appearance: condition.appearance,
                            backdrop: condition.backdrop,
                            tintPreset: condition.tintPreset,
                            usage: condition.usage,
                            direction: direction,
                            animationMode: .systemDefault,
                            glassAmount: amount
                        )
                    }
                }
            }
        }

        // A removal must immediately follow its real insertion. Regrouping
        // after the coordinate union preserves that physical lifecycle even
        // when the removal was added by a later sparse axis.
        let grouped = Dictionary(grouping: contexts, by: \.lifecycleIdentity)
        var seenLifecycles = Set<String>()
        var ordered: [DynamicContext] = []
        for context in contexts where seenLifecycles.insert(context.lifecycleIdentity).inserted {
            let group = grouped[context.lifecycleIdentity] ?? []
            for direction in GlassLabMaterializeDirection.allCases {
                if let run = group.first(where: { $0.direction == direction }) {
                    ordered.append(run)
                }
            }
        }
        return ordered
    }

    static func dynamicPlanIsApproved(osMajor: Int = currentOSMajor) -> Bool {
        let contexts = dynamicContexts(osMajor: osMajor)
        let expectedCount = osMajor == 27
            ? macOS27DynamicRunCount
            : legacyDynamicRunCount
        guard contexts.count == expectedCount,
              Set(contexts.map(\.identity)).count == contexts.count else {
            return false
        }
        for (index, context) in contexts.enumerated() where context.direction == .removal {
            guard index > 0,
                  contexts[index - 1].direction == .insertion,
                  contexts[index - 1].lifecycleIdentity == context.lifecycleIdentity else {
                return false
            }
        }
        return true
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
            tint: context.tintPreset.descriptor.label,
            width: context.width,
            height: context.height,
            cornerRadius: context.cornerRadius,
            host: context.host.rawValue,
            direction: nil,
            glassAmount: context.glassAmount
        )
    }
}

extension GoldenDynamicSample {
    /// Keep one complete native observation. Existing learnings derive their
    /// compact filter/effect views from this canonical snapshot.
    @MainActor
    init(sample: GlassLabMaterializeSample) {
        let faceValue = sample.snapshot.model.filters
            .first { $0.name == "glassBackground" }?
            .inputs.first { $0.key == "inputFaceOpacity" }?
            .value
        let face = faceValue.flatMap { Double($0) }
        self.init(
            progress: face,
            requestedProgress: sample.requestedProgress,
            elapsed: sample.elapsed,
            phase: sample.phase,
            snapshot: sample.snapshot
        )
    }
}

extension GoldenDynamicRun {
    @MainActor
    init(
        capture: GlassLabMaterializeCapture,
        slice: String,
        glassAmount: Double?
    ) {
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
                direction: capture.direction.rawValue.lowercased(),
                glassAmount: glassAmount
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
            requestedDuration: capture.requestedDuration,
            maximumAttachedAnimationDuration:
                capture.maximumAttachedAnimationDuration,
            samplingDuration: capture.samplingDuration,
            samples: capture.samples.map(GoldenDynamicSample.init(sample:)),
            context: capture.context
        )
    }
}
#endif
