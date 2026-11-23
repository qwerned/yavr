import Foundation

/// Известные галлюцинации Whisper: титры и подписи из субтитров, на которых
/// училась модель. Появляются в конце записи, когда там шум без речи
/// (выдох, щелчок клавиши). Срезаются только в самом конце текста — посреди
/// фразы сказанное остаётся.
public enum WhisperHallucinations {
    /// Нормализованные (нижний регистр, без пунктуации) хвосты.
    private static let phrases: [String] = [
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры делал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова",
        "спасибо за просмотр",
        "спасибо за внимание",
        "подписывайтесь на канал",
        "ставьте лайки и подписывайтесь на канал",
        "thank you for watching",
        "thanks for watching",
        "subtitles by the amara org community",
    ]

    public static func strip(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for phrase in phrases {
                if let cut = cutTail(result, phrase: phrase) {
                    result = cut
                    changed = true
                }
            }
        }
        return result
    }

    /// Текст без хвоста `phrase`, если он им заканчивается с границы слова.
    private static func cutTail(_ text: String, phrase: String) -> String? {
        let chars = Array(text)
        let target = Array(phrase)
        // Идём с конца: буквы/цифры сравниваем, пунктуацию и пробелы пропускаем.
        var i = chars.count - 1
        var j = target.count - 1
        while i >= 0, !isWordChar(chars[i]) { i -= 1 }
        while j >= 0 {
            if target[j] == " " {
                guard i >= 0, !isWordChar(chars[i]) else { return nil }
                while i >= 0, !isWordChar(chars[i]) { i -= 1 }
                j -= 1
                continue
            }
            guard i >= 0, Character(chars[i].lowercased()) == target[j] else { return nil }
            i -= 1
            j -= 1
        }
        // Фраза должна начинаться с начала слова.
        if i >= 0, isWordChar(chars[i]) { return nil }
        let kept = i >= 0 ? String(chars[0...i]) : ""
        return kept.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:—–-")))
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
