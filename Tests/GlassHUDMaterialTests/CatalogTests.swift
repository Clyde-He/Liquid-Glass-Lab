import AppKit
import Foundation
import XCTest
@testable import GlassHUDMaterial

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
    func testCertifiedCatalogKeepsCompatibleCachedTintOverlay() throws {
        let catalogURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        let catalogData = try Data(contentsOf: catalogURL)
        var certifiedAtlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: catalogData
        )
        certifiedAtlas.environment = .current(for: nil)
        var cachedAtlas = certifiedAtlas
        let color = NSColor(
            calibratedRed: 0.123,
            green: 0.456,
            blue: 0.789,
            alpha: 1
        )
        let cell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: true,
            hasMainParticipation: true
        )
        let matrix = GlassMaterialStyleAtlas.TintMatrix(
            sourceColor: try XCTUnwrap(GlassMaterialColorValue(color)),
            matrix: Array(repeating: 0.25, count: 20)
        )
        cachedAtlas.addTintMatrix(matrix, for: cell)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let certifiedURL = directory.appendingPathComponent("certified.json")
        let cacheURL = directory.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(certifiedAtlas).write(to: certifiedURL)
        try JSONEncoder().encode(cachedAtlas).write(to: cacheURL)

        let provider = GlassMaterialAtlasProvider(
            hostWindow: NSWindow(),
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()

        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertNotNil(
            provider.atlas.tintMatrix(for: cell, matching: color)
        )
    }
}
