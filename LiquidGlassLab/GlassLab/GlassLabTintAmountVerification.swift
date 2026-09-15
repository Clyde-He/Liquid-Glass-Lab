#if os(macOS)
import AppKit

extension GlassLabView {
    /// Live product integration check. Preference changes are process-local;
    /// no user's system preference is written. Golden-derived native
    /// coordinates are checked separately by TintAmountTests.
    @available(macOS 27.0, *)
    @MainActor
    func performTintAmountVerification() async throws -> [String: Any] {
        guard GlassSystemTintAmount.isSupported else {
            throw GlassLabGoldenExportError.contextRejected(
                context: "Glass tint amount verification",
                detail: "Glass amount is supported only on macOS 27"
            )
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 120, y: 120, width: 520, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let glass = AdjustableGlassEffectView(
            frame: NSRect(x: 20, y: 20, width: 480, height: 200)
        )
        glass.cornerRadius = 16
        panel.contentView?.addSubview(glass)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var rows: [[String: Any]] = []

        func record(_ name: String, expectedAmount: Double, progress: Double) {
            let inputs = GlassLabTuning.captureShaderInputs(from: glass)
            let face = inputs["inputFaceOpacity"] ?? -1
            let held = glass.materialStrength.frozenStyleIsCurrentlyApplied
            let amount = glass.materialStrength.tintAmount ?? -1
            let passed = held && glass.status == .ready
                && abs(amount - expectedAmount) < 1e-6
                && abs(face - progress) < 1e-4
            rows.append([
                "name": name, "passed": passed, "frozenReadbackHeld": held,
                "status": String(describing: glass.status),
                "amount": amount, "expectedAmount": expectedAmount,
                "progress": progress, "faceOpacity": face,
                "shortSide": min(glass.bounds.width, glass.bounds.height),
                "requiredWindowInset": glass.requiredWindowInset,
                "inputs": inputs,
            ])
        }

        // Cross all product cells, the endpoints and both interpolation
        // segments, Materialize progress, resizing and a colored Tint.
        for isClear in [false, true] {
            for isLight in [false, true] {
                for active in [false, true] {
                    for amount in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        glass.performConfigurationUpdates {
                            glass.style = isClear ? .clear : .regular
                            glass.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
                            glass.effectState = active ? .active : .inactive
                            glass.tintAmount = CGFloat(amount)
                            glass.effectAmount = 0.5
                            glass.tintColor = NSColor(srgbRed: 0.173, green: 0.617, blue: 0.842, alpha: 0.88)
                        }
                        glass.setFrameSize(NSSize(width: 480, height: amount > 0.5 ? 96 : 200))
                        glass.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(160))
                        record("clear=\(isClear) light=\(isLight) active=\(active)", expectedAmount: amount, progress: 0.5)
                    }
                }
            }
        }

        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        func setProcessAmount(_ amount: Double) {
            var domain = original
            domain["NSGlassTintAmount"] = amount
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: GlassSystemTintAmount.didChange, object: nil)
        }
        glass.tintColor = nil
        glass.effectAmount = 1
        glass.tintAmount = nil
        for amount in [0.25, 0.75] {
            setProcessAmount(amount)
            try await Task.sleep(for: .milliseconds(200))
            record("follow system notification", expectedAmount: amount, progress: 1)
        }
        glass.tintAmount = 0.4
        setProcessAmount(0.1)
        try await Task.sleep(for: .milliseconds(200))
        record("manual preserves material on system notification", expectedAmount: 0.4, progress: 1)
        glass.tintAmount = nil
        try await Task.sleep(for: .milliseconds(200))
        record("resume following system", expectedAmount: 0.1, progress: 1)

        let witness = NSGlassEffectView(frame: NSRect(x: 20, y: 240, width: 480, height: 96))
        witness.style = .clear
        witness.appearance = NSAppearance(named: .aqua)
        panel.contentView?.addSubview(witness)
        var witnessSettlingChecks = 0
        while GlassLabTuning.captureShaderInputs(from: witness).isEmpty,
              witnessSettlingChecks < 20 {
            witnessSettlingChecks += 1
            try await Task.sleep(for: .milliseconds(16))
        }
        glass.tintAmount = 0.4
        glass.effectState = .inactive
        var nativeChanges: [[String: Any]] = []
        var nativeWitnessPassed = true
        func animations(_ layer: CALayer?) -> [[String: String]] {
            guard let layer else { return [] }
            var result = (layer.animationKeys() ?? []).map { key in
                ["layer": String(describing: type(of: layer)), "key": key,
                 "animation": String(describing: layer.animation(forKey: key))]
            }
            for child in layer.sublayers ?? [] { result += animations(child) }
            return result
        }
        for amount in [0.0, 1.0, 0.0] {
            setProcessAmount(amount)
            for delay in [16, 80, 400] {
                try await Task.sleep(for: .milliseconds(delay))
                record("manual during native change t=\(amount) delay=\(delay)", expectedAmount: 0.4, progress: 1)
                let native = GlassLabTuning.captureShaderInputs(from: witness)
                let nativeMatches = native["inputBlurFillNormalOpacity"].map {
                    abs($0 - max(0, 2 * amount - 1)) < 1e-6
                } ?? false
                // AppKit may still be presenting its own preference-change
                // transition at the early observation points. Retain 16/80ms
                // as timing evidence, and require the 400ms settled witness.
                if delay == 400 {
                    nativeWitnessPassed = nativeWitnessPassed && nativeMatches
                }
                nativeChanges.append([
                    "systemAmount": amount, "delay": delay,
                    "initialSettlingChecks": witnessSettlingChecks,
                    "native": native, "nativeMatchesSystemAmount": nativeMatches,
                    "product": GlassLabTuning.captureShaderInputs(from: glass),
                    "animations": animations(glass.layer),
                ])
            }
        }

        return [
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": nativeWitnessPassed
                && rows.allSatisfy { $0["passed"] as? Bool == true },
            "rows": rows,
            "nativeChanges": nativeChanges,
        ]
    }
}
#endif
