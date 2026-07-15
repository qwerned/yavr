import Foundation
import VoxCore

/// Глоссарий в ~/Library/Application Support/Vox/glossary.json.
/// Дефолтный вшит в бандл и копируется при первом запуске.
@MainActor
final class GlossaryStore: ObservableObject {
    static let shared = GlossaryStore()

    @Published private(set) var glossary: Glossary = Glossary(terms: [])

    let fileURL: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vox", isDirectory: true)
        return dir.appendingPathComponent("glossary.json")
    }()

    private init() {
        bootstrapIfNeeded()
        reload()
    }

    /// Копирует дефолтный глоссарий из бандла, если файла ещё нет.
    private func bootstrapIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bundled = Bundle.module.url(forResource: "glossary", withExtension: "json") {
            try? fm.copyItem(at: bundled, to: fileURL)
        }
    }

    func reload() {
        if let loaded = try? Glossary.load(from: fileURL) {
            glossary = loaded
        }
    }

    func save(_ new: Glossary) {
        glossary = new
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(new) {
            try? data.write(to: fileURL)
        }
    }

    var replacementEngine: ReplacementEngine {
        ReplacementEngine(glossary: glossary)
    }
}
