import Foundation
import YAVRCore

enum AppResources {
    static func glossaryURL() throws -> URL {
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL,
                  let packaged = Bundle(url: resources.appendingPathComponent("YAVR_YAVR.bundle")) else {
                throw CocoaError(.fileNoSuchFile)
            }
            bundle = packaged
        } else {
            bundle = Bundle.module
        }
        guard let url = bundle.url(forResource: "glossary", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// Runs before AppDelegate: no settings, model downloads, or microphone access.
    static func checkInstallation() throws {
        _ = try Glossary.load(from: glossaryURL())
        // Both app and Hub look only inside the installed bundle when packaged.
        guard try glossaryURL().path.hasPrefix(Bundle.main.bundleURL.path + "/"),
              let resources = Bundle.main.resourceURL,
              let hub = Bundle(url: resources.appendingPathComponent("swift-transformers_Hub.bundle")),
              !(hub.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        print("OK: bundled glossary and tokenizer resources; no build-directory fallback")
    }
}
