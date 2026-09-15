#if os(macOS)
import AppKit
import Observation

/// Controls AppKit's native resolver in this process. Never writes global preferences.
@Observable @MainActor
final class GlassLabTransparency {
    private(set) var amount: Double?
    private(set) var resolvedAmount: Double? = GlassSystemTintAmount.read()
    @ObservationIgnored private var originalArgument: Any?
    @ObservationIgnored private var ownsArgument = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var captureAmount: Double?
    @ObservationIgnored private var captureChanged = false

    init() {
        if GlassSystemTintAmount.isSupported {
            observer = NotificationCenter.default.addObserver(
                forName: GlassSystemTintAmount.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        resolvedAmount = GlassSystemTintAmount.read()
        if let captureAmount, resolvedAmount != captureAmount { captureChanged = true }
    }

    func setAmount(_ value: Double?) {
        guard GlassSystemTintAmount.isSupported else {
            amount = nil
            resolvedAmount = nil
            return
        }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value {
            guard value.isFinite else { return }
            if !ownsArgument {
                originalArgument = domain["NSGlassTintAmount"]
                ownsArgument = true
            }
            let normalized = min(1, max(0, value))
            domain["NSGlassTintAmount"] = normalized
            amount = normalized
        } else {
            if ownsArgument { domain["NSGlassTintAmount"] = originalArgument }
            ownsArgument = false
            originalArgument = nil
            amount = nil
        }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        refresh()
        NotificationCenter.default.post(name: GlassSystemTintAmount.didChange, object: nil)
    }

    func beginCapture(at value: Double) throws {
        guard GlassSystemTintAmount.isSupported else {
            throw GlassLabGoldenExportError.contextRejected(
                context: "Transparency",
                detail: "Glass amount is supported only on macOS 27"
            )
        }
        guard value.isFinite, (0...1).contains(value) else {
            throw GlassLabGoldenExportError.contextRejected(context: "Transparency", detail: "amount must be finite and in 0...1")
        }
        guard captureAmount == nil else {
            throw GlassLabGoldenExportError.contextRejected(context: "Transparency", detail: "a capture is already active")
        }
        setAmount(value)
        captureChanged = false
        captureAmount = value
        try validateCapture()
    }

    /// Moves an active capture to another exact coordinate without giving the
    /// system preference observer a chance to classify our own write as drift.
    func setCaptureAmount(_ value: Double) throws {
        guard captureAmount != nil else {
            throw GlassLabGoldenExportError.contextRejected(
                context: "Transparency",
                detail: "no capture is active"
            )
        }
        guard value.isFinite, (0...1).contains(value) else {
            throw GlassLabGoldenExportError.contextRejected(
                context: "Transparency",
                detail: "amount must be finite and in 0...1"
            )
        }
        if captureAmount == value {
            try validateCapture()
            return
        }
        captureAmount = nil
        setAmount(value)
        captureAmount = value
        captureChanged = false
        try validateCapture()
    }

    func validateCapture() throws {
        refresh()
        guard captureAmount != nil, !captureChanged else {
            throw GlassLabGoldenExportError.contextRejected(
                context: "Transparency", detail: "the effective Glass amount changed during capture"
            )
        }
    }

    func endCapture(restoring value: Double?) {
        captureAmount = nil
        captureChanged = false
        setAmount(value)
    }

    var fixedCaptureMetadata: GoldenTransparencyContext? {
        captureAmount.map { GoldenTransparencyContext.fixed(amount: $0) }
    }

}

/// Optional on schema-2 archives: absence means unknown, never an assumed 0.5.
struct GoldenTransparencyContext: Codable, Equatable {
    var version = 1
    var amount: Double?
    var baselineAmount: Double?
    var control: String

    static func fixed(amount: Double) -> Self {
        Self(
            amount: amount,
            baselineAmount: nil,
            control: "processOverride"
        )
    }

    static func canonicalArchive(baselineAmount: Double) -> Self {
        Self(
            amount: nil,
            baselineAmount: baselineAmount,
            control: "processOverridePerObservation"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version, amount, baselineAmount, control
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(baselineAmount, forKey: .baselineAmount)
        try container.encode(control, forKey: .control)
    }
}
#endif
