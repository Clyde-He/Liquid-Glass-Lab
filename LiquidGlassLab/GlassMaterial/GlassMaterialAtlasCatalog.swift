//
//  GlassMaterialAtlasCatalog.swift
//  LiquidGlassLab
//
//  Convention-based discovery for one certified atlas per macOS major:
//  glass-macos-26.json, glass-macos-27.json, and so on.
//

#if os(macOS)
import Foundation

enum GlassMaterialAtlasCatalog {
    static let resourcePrefix = "glass-macos-"

    /// Finds every conventionally named major catalog in a bundle. The
    /// Provider decodes candidates and admits only the current schema + macOS
    /// major.
    static func bundledAtlasURLs(
        in bundle: Bundle? = nil
    ) -> [URL] {
        let bundles = bundle.map { [$0] } ?? defaultBundles
        let urls = bundles.flatMap { catalogURLs(in: $0) }
        let unique = Dictionary(
            urls.map { ($0.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        return unique.filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(resourcePrefix) else { return false }
            let majorText = name.dropFirst(resourcePrefix.count)
            return Int(majorText) != nil
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Direct lookup for a known major.
    static func bundledAtlasURL(
        forMacOSMajor major: Int,
        in bundle: Bundle? = nil
    ) -> URL? {
        bundledAtlasURLs(in: bundle).first {
            $0.deletingPathExtension().lastPathComponent
                == resourcePrefix + String(major)
        }
    }

    private static var defaultBundles: [Bundle] {
#if SWIFT_PACKAGE
        [Bundle.module, Bundle.main]
#else
        [Bundle.main]
#endif
    }

    private static func catalogURLs(in bundle: Bundle) -> [URL] {
        let root = bundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: nil
        ) ?? []
        let catalog = bundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: "Catalog"
        ) ?? []
        return root + catalog
    }
}
#endif
