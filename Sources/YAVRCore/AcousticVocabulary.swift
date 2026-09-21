import Foundation

/// FluidAudio reads its vocabulary from JSON. Keep disabled terms out of that
/// file without altering the user's dictionary or losing their aliases.
public enum AcousticVocabulary {
    public static func withFile<T>(from source: URL, operation: (URL) async throws -> T) async throws -> T? {
        let glossary = try Glossary.load(from: source).acousticGlossary
        guard !glossary.terms.isEmpty else { return nil }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("yavr-vocabulary-\(UUID().uuidString).json")
        try JSONEncoder().encode(glossary).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await operation(temporary)
    }
}
