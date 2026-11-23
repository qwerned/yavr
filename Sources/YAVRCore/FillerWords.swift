import Foundation

/// Удаление звуков-заполнителей («э-э», «хм», «um») из распознанного текста.
/// Слова вроде «ну», «типа», «короче» не трогаются: у них есть нормальные
/// значения, и автоматически их от паразитов не отличить.
public enum FillerWords {
    private static let patterns: [String: String] = [
        "ru": "э+м*|х+м+|м{3,}",
        "en": "u+m+|u+h+m*|er|e+r+m+|h+m+|m{3,}",
    ]

    private static let regexCache: [String: NSRegularExpression] = patterns.mapValues {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^(?:\($0))$", options: [.caseInsensitive])
    }

    /// Символы, которые не могут стоять вплотную к паразиту (иначе это часть слова).
    private static func isWordGlue(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "_/'’-".contains(c)
    }

    private static func isSentenceEnd(_ c: Character) -> Bool { ".!?…".contains(c) }

    /// `languages` — коды «ru», «en»; неизвестные игнорируются.
    public static func remove(from text: String, languages: [String]) -> String {
        let regexes = languages.compactMap { regexCache[$0] }
        guard !regexes.isEmpty, !text.isEmpty else { return text }

        var chars = Array(text)
        let textIsAllCaps = text.uppercased() == text
        var out = ""
        var cursor = 0
        var changed = false
        var i = 0

        func isFiller(_ word: String) -> Bool {
            let range = NSRange(word.startIndex..., in: word)
            return regexes.contains { $0.firstMatch(in: word, range: range) != nil }
        }

        while i < chars.count {
            guard chars[i].isLetter else { i += 1; continue }
            var e = i
            while e < chars.count, chars[e].isLetter { e += 1 }
            let s = i
            i = e
            let word = String(chars[s..<e])

            // 1. Только целое слово.
            if s > 0, isWordGlue(chars[s - 1]) || chars[s - 1] == "." { continue }
            if e < chars.count {
                if isWordGlue(chars[e]) { continue }
                if chars[e] == ".", e + 1 < chars.count, chars[e + 1].isLetter { continue }
            }
            guard isFiller(word) else { continue }

            // 2. «Хм?», «Эм!» — осмысленная реплика.
            var look = e
            while look < chars.count, chars[look].isWhitespace { look += 1 }
            if look < chars.count, chars[look] == "?" || chars[look] == "!" { continue }

            // 3. «ER», «HM» в обычном тексте — скорее аббревиатуры.
            if !textIsAllCaps, word.uppercased() == word { continue }

            out += String(chars[cursor..<s])
            changed = true
            let trimmedOut = out.trimmingTrailing { $0.isWhitespace }
            let sentenceStart = trimmedOut.last.map(isSentenceEnd) ?? true

            // 4. Пауза после паразита: «,», «…», «...» и пробелы вокруг.
            var pos = e
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            var pause = false
            if pos < chars.count, chars[pos] == "," || chars[pos] == "…" {
                pos += 1; pause = true
            } else if pos + 2 < chars.count, chars[pos] == ".", chars[pos + 1] == ".", chars[pos + 2] == "." {
                pos += 3; pause = true
            }
            if pause { while pos < chars.count, chars[pos].isWhitespace { pos += 1 } }

            // 5. Пунктуация вокруг.
            if pos < chars.count, isSentenceEnd(chars[pos]) {
                if sentenceStart {
                    while pos < chars.count, isSentenceEnd(chars[pos]) { pos += 1 }
                    while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                } else {
                    out = out.trimmingTrailing { $0 == "," || $0.isWhitespace }
                }
            } else if pause, let comma = out.lastIndex(of: ","),
                out[out.index(after: comma)...].allSatisfy(\.isWhitespace) {
                out.remove(at: comma)
            }

            // 6. Заглавная буква у следующего слова.
            if sentenceStart, word.first?.isUppercase == true, pos < chars.count,
                chars[pos].isLowercase {
                chars[pos] = Character(String(chars[pos]).uppercased())
            }

            // 7. Паразит в конце текста.
            if pos >= chars.count {
                out = out.trimmingTrailing { $0 == "," || $0.isWhitespace }
            }

            cursor = pos
            i = max(i, pos)
        }

        guard changed else { return text }
        if cursor < chars.count { out += String(chars[cursor...]) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailing(while predicate: (Character) -> Bool) -> String {
        var s = self
        while let last = s.last, predicate(last) { s.removeLast() }
        return s
    }
}
