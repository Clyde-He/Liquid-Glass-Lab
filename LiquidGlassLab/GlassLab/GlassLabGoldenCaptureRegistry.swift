#if os(macOS)
import Foundation

enum GlassLabGoldenCaptureRegistry {
    enum Availability: String, Codable, Sendable {
        case required
        case optional
        case carriedForward = "carried-forward"
    }

    struct Module: Equatable, Sendable {
        var id: String
        var availability: Availability
        var driver: String?
        var resumeScope: String
    }

    struct Profile: Equatable, Sendable {
        var id: String
        var canonical: Bool
        var promotable: Bool
        var modules: [Module]

        var requiredModuleIDs: [String] {
            modules.filter { $0.availability == .required }.map(\.id)
        }

        func validationProblems() -> [String] {
            var problems: [String] = []
            let ids = modules.map(\.id)
            if Set(ids).count != ids.count { problems.append("duplicate module IDs") }
            if promotable && !canonical {
                problems.append("a noncanonical profile cannot be promotable")
            }
            for module in modules where module.availability == .required {
                if module.driver == nil {
                    problems.append("required module \(module.id) has no driver")
                }
            }
            return problems
        }
    }

    static let full = Profile(
        id: "full",
        canonical: true,
        promotable: true,
        modules: [
            Module(id: "core.static-scalar", availability: .required, driver: "--capture-golden", resumeScope: "session"),
            Module(id: "core.static-tree", availability: .required, driver: "--capture-golden", resumeScope: "session"),
            Module(id: "core.dynamic", availability: .required, driver: "--capture-golden", resumeScope: "session"),
            Module(id: "tint.parameterization.sweep", availability: .required, driver: "--capture-tint-parameterization", resumeScope: "color"),
            Module(id: "tint.parameterization.focused-2b", availability: .required, driver: "--capture-tint-parameterization-focused", resumeScope: "color"),
            Module(id: "tint.parameterization.hue-2c", availability: .required, driver: "--capture-tint-parameterization-phase-2c", resumeScope: "color"),
            Module(id: "tint.sync-resolution", availability: .required, driver: "--verify-tint-sync-resolution", resumeScope: "module"),
            Module(id: "tint.wide-gamut", availability: .required, driver: "--verify-tint-wide-gamut-model", resumeScope: "module"),
            Module(id: "semantic.usage-trees", availability: .required, driver: "--capture-semantic-usage-trees", resumeScope: "module"),
        ]
    )

    static func full(forOSMajor osMajor: Int) -> Profile {
        guard osMajor < 27 else { return full }
        var profile = full
        profile.modules = profile.modules.map { module in
            guard module.id == "semantic.usage-trees" else { return module }
            var optional = module
            optional.availability = .optional
            return optional
        }
        return profile
    }

    static let driftScan = Profile(
        id: "drift-scan",
        canonical: false,
        promotable: false,
        modules: [
            Module(id: "drift.style-atlas", availability: .required, driver: "--verify-style-atlas", resumeScope: "module"),
            Module(id: "drift.tint-sync", availability: .required, driver: "--verify-tint-sync-resolution", resumeScope: "module"),
        ]
    )
}
#endif
