import Foundation

/// Правило замены: набор вариантов «как слышится» -> каноническое написание.
public struct ReplacementRule: Sendable {
    public let canonical: String
    public let variants: [String]

    public init(canonical: String, variants: [String]) {
        self.canonical = canonical
        self.variants = variants
    }
}

/// Детерминированные текстовые замены поверх ASR-выхлопа.
///
/// Правила:
/// - регистронезависимо (и ё == е);
/// - только по границам слов («апи» не сработает внутри «капитан»);
/// - падежные хвосты: вариант, оканчивающийся на согласную, матчится
///   с русским окончанием («в лайтдэше» -> «в Lightdash»);
/// - многословные варианты («мердж реквест»), хвост допустим у последнего слова;
/// - пунктуация вокруг слова сохраняется;
/// - каноническое написание само служит вариантом для нормализации
///   регистра («Dbt» -> «dbt»), но без падежных хвостов.
public struct ReplacementEngine: Sendable {

    /// Допустимые русские падежные окончания (после согласной основы).
    private static let endings: Set<String> = [
        "а", "я", "у", "ю", "е", "и", "ы", "о",
        "ом", "ем", "ём", "ой", "ей", "ах", "ях",
        "ам", "ям", "ов", "ев", "ами", "ями",
    ]

    private struct Variant {
        let words: [String]  // нормализованные слова варианта
        let allowEndings: Bool
        let canonical: String
    }

    /// Ключ — первое слово варианта; многословные варианты проверяются раньше коротких.
    private let variantsByFirstWord: [String: [Variant]]

    public init(rules: [ReplacementRule]) {
        var index: [String: [Variant]] = [:]

        func add(_ raw: String, canonical: String, allowEndings: Bool) {
            let words = raw.split(separator: " ").map { Self.normalize(String($0)) }
            guard let first = words.first, !first.isEmpty else { return }
            let variant = Variant(words: words, allowEndings: allowEndings, canonical: canonical)
            index[first, default: []].append(variant)
        }

        for rule in rules {
            for raw in rule.variants {
                // Хвосты — только для кириллических вариантов с согласной на конце
                let normalized = Self.normalize(raw)
                let allowEndings = normalized.last.map { Self.isRussianConsonant($0) } ?? false
                add(raw, canonical: rule.canonical, allowEndings: allowEndings)
            }
            // Каноническое написание нормализует регистр, без хвостов
            add(rule.canonical, canonical: rule.canonical, allowEndings: false)
        }

        // Длинные варианты первыми: «мердж реквест» до «мердж»
        self.variantsByFirstWord = index.mapValues { $0.sorted { $0.words.count > $1.words.count } }
    }

    public init(glossary: Glossary) {
        self.init(rules: glossary.replacementRules)
    }

    public func apply(to text: String) -> String {
        let tokens = Self.tokenize(text)
        var result = ""
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            guard token.isWord else {
                result += token.text
                i += 1
                continue
            }

            if let (canonical, consumed) = match(tokens: tokens, at: i) {
                result += canonical
                i += consumed
            } else {
                result += token.text
                i += 1
            }
        }
        return result
    }

    // MARK: - Внутренности

    private struct Token {
        let text: String
        let isWord: Bool
    }

    /// Ищет самое длинное правило, начинающееся с токена i.
    /// Возвращает каноническое написание и число потреблённых токенов.
    private func match(tokens: [Token], at start: Int) -> (String, Int)? {
        let firstWord = Self.normalize(tokens[start].text)
        // Кандидаты по точному первому слову и по первому слову с хвостом
        var candidates: [Variant] = variantsByFirstWord[firstWord] ?? []
        if candidates.isEmpty || candidates.allSatisfy({ $0.words.count > 1 }) {
            // Однословный вариант с падежным хвостом: ищем по основе
            for (key, variants) in variantsByFirstWord where firstWord.hasPrefix(key) {
                candidates.append(contentsOf: variants)
            }
        }

        for variant in candidates {
            if let consumed = tryMatch(variant, tokens: tokens, at: start) {
                return (variant.canonical, consumed)
            }
        }
        return nil
    }

    private func tryMatch(_ variant: Variant, tokens: [Token], at start: Int) -> Int? {
        var tokenIndex = start
        for (wordIndex, variantWord) in variant.words.enumerated() {
            // Пропускаем один пробельный токен между словами варианта
            if wordIndex > 0 {
                guard tokenIndex < tokens.count, !tokens[tokenIndex].isWord,
                    tokens[tokenIndex].text.allSatisfy({ $0 == " " })
                else { return nil }
                tokenIndex += 1
            }
            guard tokenIndex < tokens.count, tokens[tokenIndex].isWord else { return nil }

            let word = Self.normalize(tokens[tokenIndex].text)
            let isLast = wordIndex == variant.words.count - 1

            if word == variantWord {
                tokenIndex += 1
                continue
            }
            // Падежный хвост — только у последнего слова варианта
            if isLast, variant.allowEndings, word.hasPrefix(variantWord) {
                var tail = String(word.dropFirst(variantWord.count))
                if tail.hasPrefix("-") { tail = String(tail.dropFirst()) }
                if Self.endings.contains(tail) {
                    tokenIndex += 1
                    continue
                }
            }
            return nil
        }
        return tokenIndex - start
    }

    /// Разбивает текст на слова (буквы/цифры/дефис) и всё остальное.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool? = nil

        func flush() {
            if let isWord = currentIsWord, !current.isEmpty {
                tokens.append(Token(text: current, isWord: isWord))
            }
            current = ""
            currentIsWord = nil
        }

        for char in text {
            let isWordChar = char.isLetter || char.isNumber || char == "-"
            if currentIsWord != isWordChar { flush() }
            current.append(char)
            currentIsWord = isWordChar
        }
        flush()
        return tokens
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func isRussianConsonant(_ char: Character) -> Bool {
        "бвгджзйклмнпрстфхцчшщ".contains(char)
    }
}
