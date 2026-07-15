import Foundation

/// Один термин глоссария: каноническое написание, алиасы для acoustic boosting
/// (использует FluidAudio) и варианты «как слышится» для текстовых замен.
public struct GlossaryTerm: Codable, Sendable {
    /// Каноническое написание («Lightdash»)
    public let text: String
    /// Фонетические алиасы для keyword boosting («лайтдэш»)
    public let aliases: [String]?
    /// Per-term порог схожести для рескорера FluidAudio
    public let minSimilarity: Float?
    /// Варианты для детерминированной текстовой замены («лайтдэш» -> «Lightdash»).
    /// В отличие от aliases срабатывают без акустического подтверждения,
    /// поэтому сюда нельзя класть обычные русские слова.
    public let replacements: [String]?

    public init(
        text: String,
        aliases: [String]? = nil,
        minSimilarity: Float? = nil,
        replacements: [String]? = nil
    ) {
        self.text = text
        self.aliases = aliases
        self.minSimilarity = minSimilarity
        self.replacements = replacements
    }
}

/// glossary.json целиком. Формат совместим с CustomVocabularyContext.load(from:)
/// из FluidAudio: неизвестные ему поля (replacements) игнорируются при декодировании.
public struct Glossary: Codable, Sendable {
    public let minTermLength: Int?
    public let terms: [GlossaryTerm]

    public init(minTermLength: Int? = nil, terms: [GlossaryTerm]) {
        self.minTermLength = minTermLength
        self.terms = terms
    }

    public static func load(from url: URL) throws -> Glossary {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Glossary.self, from: data)
    }

    /// Правила замен для ReplacementEngine: варианты из replacements
    /// плюс каноническое написание (нормализация регистра: «Dbt» -> «dbt»).
    public var replacementRules: [ReplacementRule] {
        terms.map { term in
            ReplacementRule(canonical: term.text, variants: term.replacements ?? [])
        }
    }
}
