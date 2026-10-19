import Foundation

public struct MusicSearchQuery {
    public let release: String
    public let artist: String
    public init(_ text: String, artist: String = "") {
        let parts=text.components(separatedBy:" by ")
        if artist.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && parts.count==2 { release=parts[0];self.artist=parts[1] }
        else { release=text;self.artist=artist }
    }
    public static func normalize(_ text: String) -> String {
        AlbumKey.normalize(text).components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}.joined(separator:" ")
    }
    public var archiveQuery: String {
        let terms=Self.normalize(release).split(separator:" ").map{ "(title:\"\($0)\" OR creator:\"\($0)\" OR subject:\"\($0)\")" }.joined(separator:" AND ")
        let normalizedArtist=Self.normalize(artist)
        let aliases=normalizedArtist == "kanye west" ? ["kanye west","ye"] : normalizedArtist == "ye" ? ["ye","kanye west"] : [normalizedArtist]
        let artistClause=normalizedArtist.isEmpty ? "" : " AND ("+aliases.map { "creator:\"\($0)\" OR title:\"\($0)\"" }.joined(separator:" OR ")+")"
        return "mediatype:audio AND (\(terms))\(artistClause) AND NOT collection:librivoxaudio AND NOT collection:podcasts"
    }
}
public enum MusicMatch {
    public static func score(query: MusicSearchQuery, title: String, creator: String, subjects: [String] = [], collections: [String] = [], mediaType: String? = "audio") -> Int {
        if let mediaType,mediaType != "audio" { return 0 }
        let t=MusicSearchQuery.normalize(title), c=MusicSearchQuery.normalize(creator)
        let metadata=MusicSearchQuery.normalize(subjects.joined(separator:" "))
        let banned=["podcast","audiobook","audio book","interview","commentary","discussion","review","reaction","radio show","sermon","lecture","news report","documentary","fan theory","text to speech"]
        if banned.contains(where:{ (" "+t+" ").contains(" "+$0+" ") || (" "+metadata+" ").contains(" "+$0+" ") }) { return 0 }
        if collections.contains(where:{["librivox","podcast","sermon","radioprograms","audio_book"].contains(where:$0.lowercased().contains)}) { return 0 }
        let wanted=MusicSearchQuery.normalize(query.release), tokens=wanted.split(separator:" ")
        guard !tokens.isEmpty else{return 0}
        let fields=t+" "+c+" "+metadata
        let matched=tokens.filter{fields.contains($0)}.count
        guard matched==tokens.count else{return 0}
        var score=20
        if t==wanted { score+=65 }
        else if t.contains(wanted) { score+=50 }
        else { score+=Int(30*Double(tokens.filter{t.contains($0)}.count)/Double(tokens.count)) }
        if !query.artist.trimmingCharacters(in:.whitespaces).isEmpty {
            let expected=MusicSearchQuery.normalize(query.artist)
            let aliases=Set([expected,expected=="kanye west" ? "ye" : expected=="ye" ? "kanye west" : expected])
            let artistMatch=aliases.contains(where:{ c==$0 || (" "+c+" ").contains(" "+$0+" ") })
            let titleMatch=aliases.contains(where:{ (" "+t+" ").contains(" "+$0+" ") })
            guard artistMatch || titleMatch else{return 0}
            score+=artistMatch ? 25 : 12
        }
        if ["music","album","unreleased","demo","hip hop","rap","rock","electronic","rnb"].contains(where:metadata.contains) { score+=8 }
        return min(100,score)
    }
}
