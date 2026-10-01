import Foundation

/// The user's custom dictionary (#33).
///
/// Three kinds of entry, all optional:
/// - `terms`: canonical spellings. A term heard in any casing is rewritten to
///   this one ("posthog" becomes "PostHog").
/// - `replacements`: what the model writes instead of a word, mapped to the
///   word ("post hog" becomes "PostHog").
/// - `examples`: one natural sentence per language, keyed by language code,
///   that the engine may condition on. Whisper reads it as speech that came
///   just before the dictation, so it biases spelling without being a list.
///
/// Terms and replacements come from `Paths.dictionaryFile`, a plain-text
/// table (see `parse(_:)`); every word in it is a term, and its Replaces
/// column is a replacement to it. Examples live in `settings.json` under
/// `dictionary.examples` (`DictionarySettings`), because they cost decoding
/// time and don't fit the table.
///
/// This is the only user-authored text Parrot stores. It never holds
/// transcript text.
struct UserDictionary: Codable, Equatable, Sendable {
    struct Replacement: Codable, Equatable, Sendable {
        /// What the model writes. Matched as whole words, ignoring case.
        var from: [String]
        /// What to write instead, inserted exactly as given.
        var to: String
    }

    var terms: [String]
    var replacements: [Replacement]
    /// One sentence per language code (`en`, `pt-BR`).
    var examples: [String: String]

    init(terms: [String] = [], replacements: [Replacement] = [], examples: [String: String] = [:]) {
        self.terms = terms
        self.replacements = replacements
        self.examples = examples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        examples = try c.decodeIfPresent([String: String].self, forKey: .examples) ?? [:]
    }

    static let empty = UserDictionary()

    /// The example sentence for `language`, or nil when there is none.
    ///
    /// Matches the exact code first, then its primary subtag, ignoring case:
    /// `pt-BR` and `pt` share a section. There is no fallback to another
    /// language: a prompt in the wrong language pulls the decoder into that
    /// language, which is worse than no prompt (#23).
    func example(for language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        // Sorted so the choice among several matching sections is stable.
        let sections = examples
            .map { (code: $0.key.lowercased(), text: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.code < $1.code }
        let code = language.lowercased()
        let primary = Self.primarySubtag(code)
        if let exact = sections.first(where: { $0.code == code }) { return exact.text }
        if let base = sections.first(where: { $0.code == primary }) { return base.text }
        // `en` spoken, only `en-US` written: still the same language.
        return sections.first { Self.primarySubtag($0.code) == primary }?.text
    }

    /// Canonical spellings for engines that accept a vocabulary list, such as
    /// contextual strings: every term and every replacement target.
    var vocabulary: [String] {
        var seen = Set<String>()
        return (terms + replacements.map(\.to))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func primarySubtag(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code))
    }
}

// MARK: - The text file

extension UserDictionary {
    /// Parses the plain-text dictionary, or throws a `DictionaryParseError`
    /// that names the line and never quotes the file.
    ///
    /// ```
    /// # Comment
    /// Word          Replaces
    /// Vercel        Versailles, Vercell, ver cell
    /// Parakeet
    /// ```
    ///
    /// - Lines are trimmed; blank lines and lines starting with `#` are skipped.
    /// - The header line ("Word", "Replaces", any case) is skipped wherever it is.
    /// - A tab or two or more spaces separate the columns. The first column is
    ///   the word, single spaces included ("Claude Code"); everything after the
    ///   first separator is Replaces, a comma-separated list.
    /// - A comma in the word column means a missing separator, so the file is
    ///   refused rather than guessed at.
    static func parse(_ data: Data) throws -> UserDictionary {
        guard var text = String(data: data, encoding: .utf8) else { throw DictionaryParseError.notText }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var dictionary = UserDictionary()
        // "\r\n" is one Character, so CRLF files count lines correctly too.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (word, replaces) = Self.columns(line)
            if Self.isHeader(word: word, replaces: replaces) { continue }
            if word.contains(",") { throw DictionaryParseError.missingSeparator(line: index + 1) }
            let from = replaces?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            dictionary.terms.append(word)
            if !from.isEmpty { dictionary.replacements.append(Replacement(from: from, to: word)) }
        }
        return dictionary
    }

    /// Splits a trimmed line at its first tab or run of two or more spaces.
    static func columns(_ line: String) -> (word: String, replaces: String?) {
        let chars = Array(line)
        for i in chars.indices {
            let isSeparator = chars[i] == "\t" || (chars[i] == " " && i + 1 < chars.count && chars[i + 1] == " ")
            if isSeparator {
                let word = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                return (word, rest.isEmpty ? nil : rest)
            }
        }
        return (line, nil)
    }

    static func isHeader(word: String, replaces: String?) -> Bool {
        word.caseInsensitiveCompare("Word") == .orderedSame
            && replaces?.caseInsensitiveCompare("Replaces") == .orderedSame
    }

    /// The comment lines at the top of every file Parrot writes.
    static let preamble = """
        # Words Parrot should spell your way. Replaces lists what it writes instead.
        # Separate the columns with two spaces or a tab.


        """

    /// This dictionary as the text file: the preamble, the header and one
    /// aligned row per word. Every term is a row; a replacement's target that
    /// is not a term becomes one too, and several replacements to the same
    /// word share its row. `examples` are not part of the file.
    ///
    /// What the table cannot hold is left out and counted in `skipped`: a word
    /// with a comma or starting with `#`, and a Replaces item with a comma.
    /// Runs of whitespace inside a word or an item become one space, which the
    /// replacement pass treats the same.
    func text() -> (text: String, rows: Int, skipped: Int) {
        func clean(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        var order: [String] = []
        var from: [String: [String]] = [:]
        var skipped = 0
        func add(_ raw: String, _ items: [String]) {
            let word = clean(raw)
            guard !word.isEmpty else { return }
            guard !word.contains(","), !word.hasPrefix("#") else {
                skipped += 1
                return
            }
            var list = from[word] ?? []
            if from[word] == nil { order.append(word) }
            for item in items.map(clean) where !item.isEmpty {
                if item.contains(",") {
                    skipped += 1
                } else if !list.contains(item) {
                    list.append(item)
                }
            }
            from[word] = list
        }
        for term in terms { add(term, []) }
        for replacement in replacements { add(replacement.to, replacement.from) }

        let width = max(order.map(\.count).max() ?? 0, "Word".count) + 4
        func row(_ word: String, _ replaces: String) -> String {
            replaces.isEmpty ? word : word.padding(toLength: width, withPad: " ", startingAt: 0) + replaces
        }
        var lines = [row("Word", "Replaces")]
        for word in order { lines.append(row(word, (from[word] ?? []).joined(separator: ", "))) }
        return (Self.preamble + lines.joined(separator: "\n") + "\n", order.count, skipped)
    }
}

/// Why the dictionary file did not load. Descriptions give a line number and
/// never quote the file.
enum DictionaryParseError: Error, Equatable, CustomStringConvertible {
    case notText
    case missingSeparator(line: Int)

    var description: String {
        switch self {
        case .notText:
            return "not UTF-8 text"
        case .missingSeparator(let line):
            return "line \(line): separate the word from Replaces with two spaces or a tab"
        }
    }
}

// MARK: - First-run template

extension UserDictionary {
    /// Written on first run so the file shows its shape. It only touches
    /// Parrot's own dependency name, so it changes nothing a new user is
    /// likely to say. It has no example sentence: those live in settings and
    /// add decoding time to every dictation, so they should be the user's own.
    static let template = UserDictionary(
        terms: ["WhisperKit"],
        replacements: [Replacement(from: ["whisper kit"], to: "WhisperKit")]
    ).text().text
}

