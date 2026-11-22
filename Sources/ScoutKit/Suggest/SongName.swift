import Foundation

/// Tidies a song's name where Scout picks or suggests it: emojis come out (trackers mark songs
/// with ⭐, ✨, 🗑️…) and capitalisation is fixed where it is plainly off.
///
/// Words in lowercase get capitals ("new body" → "New Body"), small words in the middle stay
/// lowercase ("Love on the Brain"), and credits stay as written ("feat.", "prod."). A name all in
/// capitals is recased too ("NEW BODY" → "New Body"), keeping acronyms like DJ. Words already in
/// mixed case keep their spelling, so a stylised name stays as it is: "iPhone", "DNA" in a longer
/// name, or a one-word name in capitals like "HUMBLE.".
public enum SongName {
    public static func tidy(_ raw: String) -> String {
        let tidied = recased(withoutEmoji(raw))
        return tidied.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : tidied
    }

    // MARK: Emojis

    static func withoutEmoji(_ text: String) -> String {
        let kept = String(text.filter { !isEmoji($0) })
        var result = collapsed(kept)
        guard kept.count != text.count else { return result }
        // Brackets an emoji was alone in, and separators it leaves dangling at either end.
        result = collapsed(result.replacingOccurrences(of: #"[\(\[\{]\s*[\)\]\}]"#, with: " ", options: .regularExpression))
        return result.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-–—|·•:,~")))
    }

    /// Pictographs and anything drawn as an emoji: ⭐ 🔥 🗑️ 👍🏽 🇺🇸 1️⃣. Text symbols like ♥ © ™ ★
    /// stay unless they're asked to look like emojis (♥️), and so do letters, digits, # and *.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        guard let first = scalars.first, !(first.isASCII && scalars.count == 1) else { return false }
        if scalars.contains(where: { $0.value == 0x20E3 || $0.value == 0xFE0F || $0.properties.isEmojiModifier }) {
            return scalars.contains { $0.properties.isEmoji }
        }
        return scalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value >= 0x1F000) }
    }

    static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Capitals

    static let minor: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on",
                                     "onto", "or", "the", "to", "vs", "via", "with"]
    static let credits: Set<String> = ["feat", "ft", "featuring", "prod", "w/"]
    static let acronyms: Set<String> = ["dj", "mc", "og", "tv", "uk", "usa", "nyc", "atl", "ceo", "r&b"]
    static let romans: Set<String> = ["ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii"]
    static let separators: Set<String> = ["-", "–", "—", "|", "/", "·", "•", "x"]
    static let opening = CharacterSet(charactersIn: "([{\"'“‘¿¡")
    static let closing = CharacterSet(charactersIn: ")]}\"'”’.,!?:;")

    static func recased(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        // All in capitals, over more than one word: shouted, not stylised. Words with digits don't
        // count ("V1").
        let counted = words.filter { $0.contains(where: \.isLetter) && !$0.contains(where: \.isNumber) }
        let shouting = counted.count >= 2 && counted.allSatisfy { !$0.contains(where: \.isLowercase) }
            && counted.contains { $0.contains(where: \.isUppercase) }
        return words.indices.map { index in
            let word = words[index]
            let start = index == 0 || separators.contains(words[index - 1]) || words[index - 1].hasSuffix(":")
                || word.unicodeScalars.first.map(opening.contains) == true
            let end = index == words.count - 1 || separators.contains(words[index + 1])
                || word.unicodeScalars.last.map { CharacterSet(charactersIn: ")]}:").contains($0) } == true
                || words[index + 1].unicodeScalars.first.map { CharacterSet(charactersIn: "([{").contains($0) } == true
            return recased(word, shouting: shouting, start: start, end: end)
        }.joined(separator: " ")
    }

    static func recased(_ word: String, shouting: Bool, start: Bool, end: Bool) -> String {
        let key = word.lowercased().trimmingCharacters(in: opening).trimmingCharacters(in: closing)
        if word.contains(where: \.isNumber) {
            // Version tags read V1, V2.
            if key.range(of: #"^v\d+$"#, options: .regularExpression) != nil, let v = word.firstIndex(of: "v") { return word.replacingCharacters(in: v...v, with: "V") }
            return word
        }
        let cased = word.filter { $0.isLowercase || $0.isUppercase }
        guard !cased.isEmpty else { return word }
        let lower: String
        if cased.allSatisfy(\.isLowercase) { lower = word }
        else if cased.allSatisfy(\.isUppercase), shouting {
            if acronyms.contains(key) || romans.contains(key) { return word }
            lower = word.lowercased()
        } else { return word }

        if credits.contains(key) || (key == "with" && word.hasPrefix("(")) || (key == "x" && !start && !end) { return lower }
        if romans.contains(key) || acronyms.contains(key) { return lower.uppercased() }
        if minor.contains(key), !start, !end { return lower }
        return capitalized(lower)
    }

    /// The first letter up, and the first after a hyphen, slash or underscore ("Self-Control");
    /// never after an apostrophe ("Don't") or a digit.
    static func capitalized(_ word: String) -> String {
        var result = "", upNext = true
        for character in word {
            if upNext, character.isLetter { result += character.uppercased(); upNext = false; continue }
            if character.isLetter || character.isNumber || character == "'" || character == "’" { upNext = false }
            else if "-/_".contains(character) { upNext = true }
            result.append(character)
        }
        return result
    }
}
