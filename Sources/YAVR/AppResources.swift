import Foundation
import TranscribeCpp
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
        // The packaged app looks only inside its own bundle.
        guard try glossaryURL().path.hasPrefix(Bundle.main.bundleURL.path + "/") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // transcribe.cpp is loaded from Contents/Frameworks and matches the wrapper ABI.
        try Transcribe.ensureCompatible()
        print("OK: bundled glossary and transcribe.cpp \(Transcribe.version()); no build-directory fallback")
    }
}
