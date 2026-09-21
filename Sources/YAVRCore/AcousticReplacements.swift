import Foundation

/// Restores original punctuation using the rescorer's complete, ordered output.
/// Ambiguous or unalignable output leaves the original transcript untouched.
public enum AcousticReplacements {
    public struct Change: Sendable {
        public let original: String
        public let replacement: String
        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }
    private struct Word {
        let text: String
        let range: Range<String.Index>
    }
    private static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { part in
            guard let first = part.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = part.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let range = first..<text.index(after: last)
            return Word(text: String(text[range]), range: range)
        }
    }
    private struct Position: Hashable { let input: Int; let output: Int }
    private struct Edit { let range: Range<String.Index>; let text: String }
    private struct Alignment { let count: Int; let edits: [Edit] }

    public static func apply(to original: String, rescored: String, changes: [Change]) -> String {
        let input = words(original), output = words(rescored).map(\.text)
        let rules = changes.map { (words($0.original).map(\.text), words($0.replacement).map(\.text), $0.replacement) }
        var memo: [Position: Alignment] = [:]
        func align(_ i: Int, _ j: Int) -> Alignment {
            let key = Position(input: i, output: j)
            if let cached = memo[key] { return cached }
            if i == input.count && j == output.count { return Alignment(count: 1, edits: []) }
            guard i < input.count, j < output.count else { return Alignment(count: 0, edits: []) }
            var paths = 0
            var edits: [Edit] = []
            func accept(_ tail: Alignment, edit: Edit?) {
                guard tail.count > 0 else { return }
                if paths == 0 { edits = (edit.map { [$0] } ?? []) + tail.edits }
                paths = min(2, paths + tail.count)
            }
            if input[i].text == output[j] { accept(align(i + 1, j + 1), edit: nil) }
            var seen = Set<String>()
            for (before, after, replacement) in rules {
                guard !before.isEmpty, !after.isEmpty, before != after,
                      i + before.count <= input.count, j + after.count <= output.count,
                      input[i..<(i + before.count)].map(\.text) == before,
                      Array(output[j..<(j + after.count)]) == after,
                      seen.insert(before.joined(separator: "\u{0}") + "\u{1}" + replacement).inserted else { continue }
                let range = input[i].range.lowerBound..<input[i + before.count - 1].range.upperBound
                // Do not erase punctuation between words in a multi-word match.
                guard String(original[range]).split(whereSeparator: \.isWhitespace).map(String.init) == before else { continue }
                accept(align(i + before.count, j + after.count), edit: Edit(range: range, text: replacement))
            }
            let result = Alignment(count: paths, edits: edits)
            memo[key] = result
            return result
        }
        let result = align(0, 0)
        guard result.count == 1 else { return original }
        var text = original
        for edit in result.edits.reversed() { text.replaceSubrange(edit.range, with: edit.text) }
        return text
    }
}
