import AppKit
import Foundation
import XCTest
@testable import AdjustableGlass

@available(macOS 26.0, *)
final class CatalogTests: XCTestCase {
    @MainActor
    func testPackageContainsVerifiedMacOS27Catalog() throws {
        let url = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        let data = try Data(contentsOf: url)
        let atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: data
        )

        XCTAssertEqual(atlas.environment?.resolvedOSMajorVersion, 27)
        XCTAssertEqual(atlas.environment?.osMajorVersion, 27)
        XCTAssertFalse(atlas.hasTintMatrices)
        XCTAssertTrue(
            atlas.hasVerifiedMainOnCoverage(
                shortSides: [48, 64, 96, 128, 160, 200, 320]
            )
        )
    }

    @MainActor
    func testPackageContainsVerifiedMacOS26Catalog() throws {
        let url = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 26)
        )
        let atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(atlas.environment?.osMajorVersion, 26)
        XCTAssertEqual(atlas.environment?.resolvedOSMajorVersion, 26)
        XCTAssertFalse(atlas.hasTintMatrices)
        XCTAssertTrue(
            atlas.hasVerifiedMainOnCoverage(
                shortSides: [48, 64, 96, 128, 160, 200, 320]
            )
        )
    }

    @MainActor
    func testPreAtlasEnvelopeUsesWorstBundledMainOnMargin() {
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            certifiedAtlasURLs: GlassMaterialAtlasCatalog.bundledAtlasURLs()
        )

        XCTAssertEqual(
            provider.conservativeMainOnMargin(for: 96),
            68,
            accuracy: 0.001
        )
        XCTAssertEqual(
            provider.conservativeMainOnMargin(for: 128),
            83,
            accuracy: 0.001
        )
    }

    @MainActor
    func testPreAtlasEnvelopeFallsBackToWorstMeasuredRatio() {
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            certifiedAtlasURLs: []
        )

        XCTAssertEqual(
            provider.conservativeMainOnMargin(for: 120),
            85.2,
            accuracy: 0.001
        )
    }

    @MainActor
    func testCertifiedCatalogKeepsCompatibleCachedTintOverlay() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, certifiedAtlas) = try makeCertifiedFixture(
            in: directory
        )
        var cachedAtlas = certifiedAtlas
        let color = NSColor(
            displayP3Red: 1,
            green: 0,
            blue: 0,
            alpha: 0.6
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        for (cell, matrix) in tintMatrices(
            for: sourceColor,
            seed: 0.25
        ) {
            cachedAtlas.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }

        // A cache may carry stale base data, but the certified catalog remains
        // authoritative for the reusable material payload.
        let baseCell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: true,
            hasMainParticipation: true
        )
        var staleSample = try XCTUnwrap(
            cachedAtlas.sample(for: baseCell, at: 200)
        )
        staleSample.numeric["inputFaceOpacity"] = -99
        cachedAtlas.add(staleSample, for: baseCell)

        let cacheURL = directory.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(cachedAtlas).write(to: cacheURL)

        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()

        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertEqual(
            provider.atlas.sample(for: baseCell, at: 200),
            certifiedAtlas.sample(for: baseCell, at: 200)
        )
        for cell in GlassMaterialStyleAtlas.allTintCells {
            XCTAssertNotNil(provider.atlas.tintMatrix(for: cell, matching: color))
        }
    }

    @MainActor
    func testVerifiedWideGamutTintPersistsAndRebuildsWithoutHostWindow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let color = NSColor(
            displayP3Red: 1,
            green: 0,
            blue: 0,
            alpha: 0.6
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        XCTAssertFalse(
            [sourceColor.red, sourceColor.green, sourceColor.blue]
                .allSatisfy { 0...1 ~= $0 }
        )

        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()
        XCTAssertEqual(provider.state, .ready)
        XCTAssertTrue(
            provider.persistVerifiedTintMatrices(
                sourceColor: sourceColor,
                matrices: tintMatrices(for: sourceColor, seed: 0.15)
            )
        )

        let persisted = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: cacheURL)
        )
        XCTAssertEqual(persisted.tintMatrixColorCount, 1)

        let rebuilt = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        rebuilt.ensureCaptured()
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.atlasSource, .certified)

        let resolved = try XCTUnwrap(
            GlassEffectController.resolvedTintAtlas(
                rebuilt.atlas,
                color: color,
                emphasis: .normal,
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            )
        )
        for cell in GlassMaterialStyleAtlas.allTintCells {
            XCTAssertNotNil(resolved.tintMatrix(for: cell, matching: color))
        }
    }

    @MainActor
    func testPartialAndUnverifiedTintMatricesAreNotPersistedOrLoaded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, certifiedAtlas) = try makeCertifiedFixture(
            in: directory
        )
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()

        let color = NSColor(
            displayP3Red: 0.9,
            green: 0.1,
            blue: 0.2,
            alpha: 0.6
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        var partial = tintMatrices(for: sourceColor, seed: 0.2)
        partial.removeValue(forKey: try XCTUnwrap(partial.keys.first))
        XCTAssertFalse(
            provider.persistVerifiedTintMatrices(
                sourceColor: sourceColor,
                matrices: partial
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        let invalid = tintMatrices(for: sourceColor, seed: 0.3).mapValues {
            var matrix = $0
            matrix[18] = 0.25
            return matrix
        }
        XCTAssertFalse(
            provider.persistVerifiedTintMatrices(
                sourceColor: sourceColor,
                matrices: invalid
            )
        )

        // A hand-written partial overlay must not be accepted merely because
        // the certified base is otherwise complete.
        var partialCache = certifiedAtlas
        partialCache.addTintMatrix(
            .init(
                sourceColor: sourceColor,
                matrix: Array(repeating: 0.25, count: 20)
            ),
            for: GlassMaterialStyleAtlas.allTintCells[0]
        )
        try JSONEncoder().encode(partialCache).write(to: cacheURL)
        let rebuilt = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        rebuilt.ensureCaptured()
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.atlas.tintMatrixColorCount, 0)
        XCTAssertNil(
            rebuilt.atlas.tintMatrix(
                for: GlassMaterialStyleAtlas.allTintCells[0],
                matching: color
            )
        )
    }

    @MainActor
    func testTintCacheMatchesRGBIgnoresAlphaAndPatchesOnlyCoefficient18()
        throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()

        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.3)
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        let matrices = tintMatrices(for: sourceColor, seed: 0.4)
        XCTAssertTrue(
            provider.persistVerifiedTintMatrices(
                sourceColor: sourceColor,
                matrices: matrices
            )
        )

        let cell = GlassMaterialStyleAtlas.allTintCells[0]
        let alphaVariant = color.withAlphaComponent(0.9)
        let stored = try XCTUnwrap(
            provider.atlas.tintMatrix(for: cell, matching: alphaVariant)
        )
        let patched = try XCTUnwrap(
            GlassEffectController.tintMatrixByPatchingAlpha(
                stored,
                sourceColor: try XCTUnwrap(
                    GlassMaterialColorValue(alphaVariant)
                )
            )
        )
        XCTAssertEqual(patched[18], 0.9, accuracy: 0.00001)
        for index in patched.indices where index != 18 {
            XCTAssertEqual(patched[index], stored[index])
        }

        let differentRGB = NSColor(
            srgbRed: 0.2,
            green: 0.4,
            blue: 0.65,
            alpha: 0.9
        )
        XCTAssertNil(
            provider.atlas.tintMatrix(
                for: cell,
                matching: differentRGB
            )
        )
    }

    @MainActor
    func testTintCacheIsBoundedAndKeepsNewestColor() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()

        var newestColor: NSColor?
        for index in 0...GlassMaterialStyleAtlas.tintMatrixColorLimit {
            let color = NSColor(
                srgbRed: 0.05 + Double(index) * 0.1,
                green: 0.2,
                blue: 0.7,
                alpha: 0.6
            )
            newestColor = color
            let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
            XCTAssertTrue(
                provider.persistVerifiedTintMatrices(
                    sourceColor: sourceColor,
                    matrices: tintMatrices(
                        for: sourceColor,
                        seed: Float(index) * 0.01
                    )
                )
            )
        }
        XCTAssertEqual(
            provider.atlas.tintMatrixColorCount,
            GlassMaterialStyleAtlas.tintMatrixColorLimit
        )
        XCTAssertNotNil(
            provider.atlas.tintMatrix(
                for: GlassMaterialStyleAtlas.allTintCells[0],
                matching: try XCTUnwrap(newestColor)
            )
        )
    }

    @MainActor
    func testIncompatibleAndLegacyCachesDoNotReplaceCertifiedBase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, certifiedAtlas) = try makeCertifiedFixture(
            in: directory
        )
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let color = NSColor(
            displayP3Red: 0.8,
            green: 0.1,
            blue: 0.2,
            alpha: 0.6
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        var incompatible = certifiedAtlas
        incompatible.environment?.osMajorVersion =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1
        incompatible.environment?.osBuild = "Version 999.0 (incompatible)"
        for (cell, matrix) in tintMatrices(for: sourceColor, seed: 0.6) {
            incompatible.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }
        try JSONEncoder().encode(incompatible).write(to: cacheURL)

        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()
        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertEqual(provider.atlas.tintMatrixColorCount, 0)
        XCTAssertEqual(
            provider.atlas.sample(
                for: GlassMaterialStyleAtlas.allTintCells[0],
                at: 200
            ),
            certifiedAtlas.sample(
                for: GlassMaterialStyleAtlas.allTintCells[0],
                at: 200
            )
        )

        var legacy = certifiedAtlas
        legacy.environment?.schemaVersion =
            GlassMaterialStyleAtlas.currentSchemaVersion - 1
        for (cell, matrix) in tintMatrices(for: sourceColor, seed: 0.7) {
            legacy.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }
        try JSONEncoder().encode(legacy).write(to: cacheURL)

        let rebuilt = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        rebuilt.ensureCaptured()
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.atlasSource, .certified)
        XCTAssertEqual(rebuilt.atlas.tintMatrixColorCount, 0)

        try Data("not-json".utf8).write(to: cacheURL)
        let malformed = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        malformed.ensureCaptured()
        XCTAssertEqual(malformed.state, .ready)
        XCTAssertEqual(malformed.atlasSource, .certified)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeCertifiedFixture(
        in directory: URL
    ) throws -> (URL, GlassMaterialStyleAtlas) {
        let bundledURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        var atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: bundledURL)
        )
        atlas.environment = .current(for: nil)
        let url = directory.appendingPathComponent("certified.json")
        try JSONEncoder().encode(atlas).write(to: url)
        return (url, atlas)
    }

    private func tintMatrices(
        for sourceColor: GlassMaterialColorValue,
        seed: Float
    ) -> [GlassMaterialStyleAtlas.Cell: [Float]] {
        Dictionary(uniqueKeysWithValues: GlassMaterialStyleAtlas.allTintCells
            .enumerated().map { index, cell in
                var matrix = (0..<20).map { coefficient in
                    seed + Float(index) * 0.01 + Float(coefficient) * 0.0001
                }
                matrix[18] = Float(sourceColor.alpha)
                return (cell, matrix)
            })
    }
}
