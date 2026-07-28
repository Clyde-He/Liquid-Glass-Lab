//
//  GlassLabState.swift
//  LiquidGlassLab
//
//  Single source of truth for the Liquid Glass lab. A single independently
//  hosted glass surface can be rebuilt as several AppKit window types and
//  moved between neither-key-nor-main and main-only participation states.
//

#if os(macOS)
import AppKit
import Observation

enum GlassLabWindowHostType: String, CaseIterable, Identifiable {
    case panel = "Panel"
    case window = "Window"

    var id: Self { self }

    var contextID: String {
        switch self {
        case .panel: "panel"
        case .window: "window"
        }
    }
}

/// Explicit AppKit appearance applied only to the independently hosted test
/// window. `system` inherits the app appearance; Light/Dark are controlled
/// P1 inputs and are intentionally separate from NSGlass's private
/// `_adaptiveAppearance` recipe field.
enum GlassLabTestAppearance: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    static let controlledCases: [Self] = [.light, .dark]

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    func matches(_ appearance: NSAppearance?) -> Bool {
        guard self != .system, let appearance else { return self == .system }
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        switch self {
        case .system:
            return true
        case .light:
            return match == .aqua
        case .dark:
            return match == .darkAqua
        }
    }
}

/// Backdrop drawn inside the test window below the Glass surface. Ambient
/// preserves the original transparent-Panel/colorful-Window behavior; Light
/// and Dark use fixed sRGB neutral fills so render-server backdrop adaptation
/// can be tested independently of NSAppearance.
enum GlassLabBackdropMode: String, CaseIterable, Identifiable, Codable {
    case ambient = "Ambient"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    static let controlledCases: [Self] = [.light, .dark]

    var controlledColor: NSColor? {
        switch self {
        case .ambient:
            return nil
        case .light:
            return NSColor(
                srgbRed: 0.92,
                green: 0.92,
                blue: 0.92,
                alpha: 1
            )
        case .dark:
            return NSColor(
                srgbRed: 0.08,
                green: 0.08,
                blue: 0.08,
                alpha: 1
            )
        }
    }
}

@Observable
@MainActor
final class GlassLabState {
    // MARK: Renderer

    /// Recipe and Semantic Usage intentionally remain separate renderer
    /// spaces. The latter must never be written into NSGlassEffectView's raw
    /// `_variant` property.
    var rendererMode: GlassLabRendererMode = .recipe
    var semanticUsage: GlassLabSemanticUsage = .regular

    // MARK: Geometry — recipes resolve against the glass's own size.

    var glassWidth: Double = 480
    var glassHeight: Double = 200
    var cornerRadius: Double = 16

    // MARK: Material recipe (NSGlassEffectView properties)

    /// Integer recipe: 0 fresh default, 1 = public Regular, 2 = public Clear.
    var variant = 0
    /// Independent named recipe axis ("menu", "sheet", "camera", ...).
    /// The resolver consumes it only for some integer variants; it is not a
    /// global override of `variant`.
    var subvariant = ""
    /// Independent lower-emphasis axis. In controlled Variant 0/2 probes it
    /// suppresses the active Shader/Rim payload even while the host is main;
    /// some layer geometry can still retain main-participation differences.
    var isSubdued = false
    var hasScrim = false
    var hasReducedTintOpacity = false
    /// 2 = adaptive default; values above 2 trap inside AppKit.
    var adaptiveAppearance = 2
    var tintColor: NSColor?

    // MARK: Shader-input overrides (glassBackground CAFilter)

    var shaderOverridesEnabled = false
    var shaderOverrides: [String: Double] = [:]
    /// Editable inputs that exist in the current filter but whose captured
    /// Recipe value is nil. Keeping this separate from the value dictionaries
    /// prevents a fallback zero from being mistaken for a system value.
    var shaderNilOverrides: Set<String> = []
    /// Non-numeric shader inputs have their own typed pipelines so colors and
    /// points are not silently dropped or coerced through NSNumber.
    var shaderColorOverrides: [String: NSColor] = [:]
    var shaderPointOverrides: [String: CGPoint] = [:]
    /// Layer-tree geometry the recipe resolves alongside the filter inputs
    /// (backdrop marginWidth, SDF minimum/maximum reach). Captured when Filter
    /// Override is enabled and stamped alongside the filter values.
    var layerGeometryOverrides: [String: Double] = [:]

    // MARK: Rim-highlight overrides (CASDFKeyFillHighlightEffect pass)

    var highlightOverridesEnabled = false
    var highlightOverrides: [String: Double] = [:]
    var highlightColorOverrides: [String: NSColor] = [:]
    var highlightNilOverrides: Set<String> = []

    // MARK: Color-matrix pass overrides (two exact structural slots)

    var vibrantMatrixOverridesEnabled = false
    var vibrantMatrixOverrides:
        [String: GlassLabTuning.VibrantColorMatrixOverridePayload] = [:]

    var hasActiveOverrides: Bool {
        shaderOverridesEnabled
            || highlightOverridesEnabled
            || vibrantMatrixOverridesEnabled
    }

    // MARK: Test-window context

    var isTestWindowVisible = true
    var windowHostType: GlassLabWindowHostType = .panel
    /// Public environment appearance for both AppKit and SwiftUI renderers.
    /// This does not write NSGlass's private `_adaptiveAppearance`.
    var testAppearance: GlassLabTestAppearance = .system
    /// Controlled content below the Glass. P1 captures use Light/Dark rather
    /// than sampling an uncontrolled desktop behind a transparent Panel.
    var testBackdrop: GlassLabBackdropMode = .ambient
    /// Off guarantees neither-key-nor-main. On makes the test surface
    /// main-only and selects the active branch while the control window remains
    /// key. A titled Window briefly becomes key while AppKit establishes main
    /// participation, then immediately returns key status to the control.
    var isTestWindowMain = false
    /// Extra transparent/content area around the test glass. A window's
    /// backing surface hard-clips at its frame, so the recipe's shadow and
    /// outer passes need this room to render; 0 reproduces a zero-margin
    /// Panel window.
    var windowPadding: Double = 40

    // MARK: Lab output

    /// Latest context-diff or capture summary, shown in the inspector.
    var reportOutput = ""
    /// Prevents observation-driven representable refreshes from restamping the
    /// UI-selected recipe while the diagnostic exporter walks private axes.
    var isCapturingRecipeMatrix = false

    /// The AppKit test window is controller-owned and deliberately lives
    /// outside Observation. SwiftUI sends it explicit sync events.
    @ObservationIgnored let testWindow = GlassLabTestWindowController()

    func resetRecipe() {
        variant = 0
        subvariant = ""
        isSubdued = false
        hasScrim = false
        hasReducedTintOpacity = false
        adaptiveAppearance = 2
        tintColor = nil
    }
}
#endif
