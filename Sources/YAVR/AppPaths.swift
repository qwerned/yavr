import Foundation

/// All application data lives in ~/Library/Application Support/YAVR.
enum AppPaths {
    static let supportDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YAVR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var glossaryFile: URL { supportDirectory.appendingPathComponent("glossary.json") }
    static var statsFile: URL { supportDirectory.appendingPathComponent("stats.json") }
}
