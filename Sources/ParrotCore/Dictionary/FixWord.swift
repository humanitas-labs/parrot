import Foundation

/// What Fix Word… writes (#54): the spelling the user typed as a Word, and,
/// with `replace`, what the model wrote as one of the words it replaces.
/// Pure, except that `warnings` asks `CommonWords`.
struct FixWord: Equatable {
    /// What the model wrote, usually the selection.
    var heard: String
    /// The spelling the user wants.
    var word: String
    /// Rewrite `heard` to `word` in every dictation. Without it, the row
    /// only gives `word` its spelling in any case.
    var replace: Bool

    /// Fix Word adds a word or a name, never a sentence.
    static let maxWords = 4
    static let maxLength = 64

    /// Whether `text` is short enough to be a word or a name.
    static func fits(_ text: String) -> Bool {
        let cleaned = DictionaryText.clean(text)
        return !cleaned.isEmpty && cleaned.count <= maxLength && cleaned.split(separator: " ").count <= maxWords
    }

    var cleanHeard: String { DictionaryText.clean(heard) }
    var cleanWord: String { DictionaryText.clean(word) }

    /// `heard` can be replaced: it is there, and it is more than the word in
    /// another case, which the row fixes on its own.
    var canReplace: Bool {
        !cleanHeard.isEmpty && cleanHeard.caseInsensitiveCompare(cleanWord) != .orderedSame
    }

    /// The edit to write.
    var edit: DictionaryEdit {
        .add(word: cleanWord, replaces: replace && canReplace ? [cleanHeard] : [])
    }

    /// The edit that takes this fix back: the whole row when Fix Word made
    /// it, else only the item it added to the user's row. Nil when the fix
    /// changed nothing.
    func undo(createdRow: Bool) -> DictionaryEdit? {
        if createdRow { return .remove(word: cleanWord, replaces: []) }
        if replace && canReplace { return .remove(word: cleanWord, replaces: [cleanHeard]) }
        return nil
    }

    /// Whether Replace starts on: off when the heard form is a common word,
    /// which would change ordinary text in every dictation.
    static func suggestsReplace(heard: String, common: CommonWords = EmbeddingCommonWords.shared) -> Bool {
        let cleaned = DictionaryText.clean(heard)
        return !cleaned.isEmpty && !common.isCommon(cleaned)
    }

    /// What the row would change beyond the misheard word.
    func warnings(common: CommonWords = EmbeddingCommonWords.shared) -> [String] {
        guard !cleanWord.isEmpty else { return [] }
        var result: [String] = []
        if replace, canReplace, common.isCommon(cleanHeard) {
            result.append("Every “\(cleanHeard)” in every dictation becomes “\(cleanWord)”.")
        }
        if common.isCommon(cleanWord) {
            result.append("Every “\(cleanWord.lowercased())”, in any case, becomes “\(cleanWord)”.")
        } else if !Self.hasShape(cleanWord) {
            result.append("Every capitalized “\(cleanWord.capitalized)” becomes “\(cleanWord)”, even at the start of a sentence.")
        }
        return result
    }

    /// A spelling that ordinary text rarely has by chance: a capital letter,
    /// a digit, or inner punctuation.
    static func hasShape(_ word: String) -> Bool {
        word.split(separator: " ").contains { part in
            part.contains(where: \.isUppercase)
                || part.contains(where: \.isNumber)
                || part.dropFirst().dropLast().contains { "-._".contains($0) }
        }
    }
}
