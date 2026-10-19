import Foundation

public enum LyricMatching {
    public static func accepts(title: String, artist: String, duration: Double, candidateTitle: String, candidateArtist: String, candidateDuration: Double?) -> Bool {
        guard duration.isFinite, duration > 0, let length = candidateDuration, length.isFinite,
              abs(length-duration) <= min(3, max(1.5,duration*0.01)) else { return false }
        // Alternate takes, remixes and demos keep their version markers. Stripping
        // them would silently attach the released version's timings.
        return MusicSearchQuery.normalize(title) == MusicSearchQuery.normalize(candidateTitle)
            && MusicSearchQuery.normalize(artist) == MusicSearchQuery.normalize(candidateArtist)
    }
    public static func lrc(_ lines: [(Double,String)]) -> String {
        lines.filter { $0.0.isFinite && $0.0 >= 0 && $0.0 <= 86400 }.map { time,text in
            let cents=Int((time*100).rounded())
            return String(format:"[%02d:%02d.%02d]",cents/6000,(cents/100)%60,cents%100)+text
        }.joined(separator:"\n")
    }
}
