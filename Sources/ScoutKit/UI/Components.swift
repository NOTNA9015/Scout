import SwiftUI

// Chroma's look, so Scout reads as part of the same app: black pages with a soft glow, grouped
// cards with large corners and a glass rim, colored rounded tiles before each row, the system font
// (a semibold title over a grey subtitle), plain uppercase section headers, glass buttons, Spotify's
// green for what is chosen and a soft red for what went wrong.

/// Chroma's accent colour (Chroma Settings → Appearance → Accent colour), so what Scout highlights
/// matches the rest of the app. Read each time it is drawn, so a new pick shows the next time Scout
/// opens. Outside Chroma (the test host) it is Spotify's green.
enum ScoutAccent {
    static let redesignKey = "spotifyglass.redesign.accent", classicKey = "spotifyglass.accent"
    /// Chroma's own default for its redesigned look, and Spotify's green.
    static let chromaDefault = 0x37F200, spotifyGreen = 0x1ED760

    static func rgb(_ defaults: UserDefaults = .standard) -> Int {
        guard Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil else { return spotifyGreen }
        let redesigned = defaults.bool(forKey: "spotifyglass.redesign")
        let stored = defaults.object(forKey: redesigned ? redesignKey : classicKey)
        return parse(stored) ?? (redesigned ? chromaDefault : spotifyGreen)
    }
    /// An RGB integer (how Chroma stores it) or "#RRGGBB".
    static func parse(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { let rgb = number.intValue; return (0...0xFFFFFF).contains(rgb) ? rgb : nil }
        if let text = value as? String {
            let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if hex.count == 6, let rgb = Int(hex, radix: 16) { return rgb }
        }
        return nil
    }
    static func components(_ rgb: Int) -> (Double, Double, Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }
    /// Black on light accents (Chroma's lime, Spotify's green), white on dark ones (Apple Music's red).
    static func prefersBlackText(_ rgb: Int) -> Bool {
        let (r, g, b) = components(rgb)
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        // Lime 0.65 and Spotify's green 0.50 take black; Apple Music's red 0.23 takes white, as it does there.
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) > 0.35
    }
}

extension Color {
    static var scoutAccent: Color { let (r, g, b) = ScoutAccent.components(ScoutAccent.rgb()); return Color(red: r, green: g, blue: b) }
    /// Text and symbols drawn on the accent.
    static var onScoutAccent: Color { ScoutAccent.prefersBlackText(ScoutAccent.rgb()) ? .black : .white }
    static let scoutBackground = Color.black
    /// A card on the black, Chroma's grey.
    static let scoutCard = Color(white: 0x1E / 255)
    static let scoutGrey = Color(white: 0x98 / 255)
    static let scoutRed = Color(red: 0xF1 / 255, green: 0x5E / 255, blue: 0x6B / 255)
    static let scoutHairline = Color.white.opacity(0.1)
    // Row tiles, as Chroma colours its settings.
    static let tileBlue = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xF5 / 255)
    static let tileIndigo = Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255)
    static let tilePurple = Color(red: 0xB4 / 255, green: 0x4F / 255, blue: 0xE8 / 255)
    static let tilePink = Color(red: 0xF2 / 255, green: 0x3D / 255, blue: 0x6E / 255)
    static let tileOrange = Color(red: 0xF5 / 255, green: 0x8A / 255, blue: 0x1F / 255)
    static let tileTeal = Color(red: 0x12 / 255, green: 0xB8 / 255, blue: 0xB0 / 255)
    static let tileGrey = Color(white: 0x63 / 255)
}

/// The system font, as Chroma's own pages use.
enum ScoutFont {
    static func of(_ size: CGFloat, bold: Bool = false) -> Font { .system(size: size, weight: bold ? .semibold : .regular) }
}

extension Font {
    static var scoutTitle: Font { .system(size: 17, weight: .semibold) }
    static var scoutSubtitle: Font { .system(size: 13) }
    static var scoutBody: Font { .system(size: 15) }
    static var scoutInput: Font { .system(size: 17) }
    static var scoutHeading: Font { .system(size: 28, weight: .bold) }
    /// A page's big centred title (Chroma's "Chroma 1.1.0").
    static var scoutHero: Font { .system(size: 34, weight: .bold) }
}

extension View {
    /// A page of cards: inset grouped on black, with the glow behind.
    func scoutList() -> some View {
        listStyle(.insetGrouped).scrollContentBackground(.hidden).background { ScoutBackdrop() }
            .listSectionSpacing(28).environment(\.defaultMinListRowHeight, 52)
    }
    /// A card drawn outside a list, the same grey and corners as a list's, with a glass rim.
    func scoutCard(padding: CGFloat = 0) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.scoutCard, in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(ScoutRim.gradient, lineWidth: 1) }
    }
}

/// A glass edge: light along the top, gone by the bottom.
enum ScoutRim {
    static let gradient = LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
}

/// Black with a faint green glow at the top, for the glass to pick up.
struct ScoutBackdrop: View {
    var body: some View {
        ZStack {
            Color.scoutBackground
            RadialGradient(colors: [Color.scoutAccent.opacity(0.16), .clear], center: .init(x: 0.5, y: -0.05), startRadius: 0, endRadius: 420)
        }.ignoresSafeArea()
    }
}

/// A section's uppercase grey title.
struct ScoutHeader: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(Color.scoutGrey).textCase(.uppercase) }
}

/// A grey note under a section or at the top of a page.
struct ScoutNote: View {
    var text: String
    var color: Color = .scoutGrey
    init(_ text: String, color: Color = .scoutGrey) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.scoutSubtitle).foregroundStyle(color).multilineTextAlignment(.leading) }
}

/// A symbol on a coloured rounded tile, the leading slot of a row.
struct SymbolTile: View {
    var symbol: String
    var tint: Color = .white
    var fill: Color?
    var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 30, height: 30).background(fill ?? Self.color(for: symbol), in: .rect(cornerRadius: 8)).accessibilityHidden(true)
    }
    /// Each kind of row keeps its colour wherever it appears.
    static func color(for symbol: String) -> Color {
        switch symbol {
        case "music.note", "music.mic", "waveform": return .tilePink
        case "square.stack", "opticaldisc", "shippingbox", "photo": return .tileOrange
        case "pencil", "arrow.down.circle", "square.and.arrow.up", "text.alignleft", "plus.square.on.square": return .tileBlue
        case "arrow.triangle.2.circlepath", "arrow.clockwise": return .tileTeal
        case "music.note.list", "checkmark.circle", "bolt.fill": return .scoutAccent
        case "sparkles", "paintpalette", "person.2", "person": return .tilePurple
        case "trash", "exclamationmark.circle", "exclamationmark.triangle": return .scoutRed
        case "calendar", "number", "list.number": return .tileIndigo
        default: return .tileGrey
        }
    }
}

/// A row's title over its subtitle, with an optional tile before them.
struct RowLabel: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .white
    var body: some View {
        HStack(spacing: 14) {
            if let symbol { SymbolTile(symbol: symbol) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.scoutTitle).foregroundStyle(tint).multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.scoutSubtitle).foregroundStyle(tint == .white ? Color.scoutGrey : tint).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).accessibilityHidden(true) }
}

/// A row that opens something: tile, title and subtitle, a grey value, then the chevron.
struct NavRow: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    var value: String?
    var tint: Color = .white
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowLabel(title: title, subtitle: subtitle, symbol: symbol, tint: tint)
                if let value { Text(value).font(.system(size: 17)).foregroundStyle(Color.scoutGrey).fixedSize() }
                Chevron()
            }.padding(.vertical, 3).contentShape(.rect)
        }.buttonStyle(.plain)
    }
}

/// Every step: where you are in the import, the step's title, the song it is about, its cards, and
/// Back / Next floating at the bottom.
struct StepPage<Content: View>: View {
    @ObservedObject var flow: ScoutFlow
    var title: String
    var subtitle: String?
    var nextTitle = "Next"
    var nextEnabled = true
    @ViewBuilder var content: Content
    var body: some View {
        List {
            Section { header }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            content
        }
        .scoutList()
        .safeAreaInset(edge: .bottom) { bar }
        .navigationTitle(flow.mode == .song ? "Import a song" : "Import an album")
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepProgress(flow: flow)
            VStack(alignment: .leading, spacing: 4) {
                if flow.perSong {
                    Text("Song \(flow.page + 1) of \(flow.drafts.count)").font(.scoutTitle).foregroundStyle(Color.scoutAccent)
                        .accessibilityIdentifier("scout.step.counter")
                }
                Text(title).font(.scoutHeading).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.scoutBody).foregroundStyle(Color.scoutGrey) }
            }
            if let step = flow.current, [.names, .artists, .cover, .lyrics].contains(step), flow.drafts.indices.contains(flow.page) {
                SongCard(draft: flow.drafts[flow.page])
            }
        }.padding(.top, 4)
    }
    private var bar: some View {
        HStack(spacing: 12) {
            Button { withAnimation { flow.back() } } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 28, height: 28)
            }.buttonStyle(.glass).controlSize(.large).accessibilityLabel("Back")
                .disabled(flow.path.count <= 1 && flow.page == 0)
            Button { withAnimation { flow.next() } } label: {
                Text(nextTitle).font(ScoutFont.of(15, bold: true)).frame(maxWidth: .infinity)
            }.buttonStyle(.glassProminent).tint(.scoutAccent).foregroundStyle(Color.onScoutAccent).controlSize(.large)
                .disabled(!nextEnabled).accessibilityIdentifier("scout.next")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
        .background(LinearGradient(colors: [Color.scoutBackground.opacity(0), Color.scoutBackground], startPoint: .top, endPoint: .center))
    }
}

/// One bar per step of the import, filling as you go; a per-song step fills song by song.
struct StepProgress: View {
    @ObservedObject var flow: ScoutFlow
    var body: some View {
        let steps = flow.order
        let at = flow.current.flatMap { steps.firstIndex(of: $0) } ?? steps.count
        let within = flow.perSong ? Double(flow.page + 1) / Double(max(flow.drafts.count, 1)) : 1
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                let fill = index < at ? 1 : index == at ? within : 0
                Capsule().fill(Color.white.opacity(0.15))
                    .overlay(alignment: .leading) { Capsule().fill(Color.scoutAccent).scaleEffect(x: fill, anchor: .leading) }
                    .frame(height: 3)
            }
        }
        .animation(.easeOut(duration: 0.25), value: at).animation(.easeOut(duration: 0.25), value: flow.page)
        .accessibilityElement().accessibilityLabel("Step \(min(at, steps.count - 1) + 1) of \(steps.count)")
    }
}

/// The song a step is about: its cover, name, artists and length.
struct SongCard: View {
    var draft: SongDraft
    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(data: draft.cover ?? draft.song.embeddedArtwork ?? draft.song.artwork, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title).font(.scoutTitle).foregroundStyle(.white).lineLimit(2)
                Text(draft.artistText).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
            }
            Spacer(minLength: 8)
            TrackLength(seconds: draft.song.duration, track: draft.song.source, file: draft.song.file)
        }.scoutCard(padding: 10)
    }
}

/// A selectable row: chosen rows turn green and get the checkmark; a row of a several-choice list has
/// a circle to tick.
struct OptionRow: View {
    var title: String
    var detail: String?
    var selected: Bool
    var multiple = false
    var duration: Double?
    var showsDuration = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.scoutTitle).foregroundStyle(selected ? Color.scoutAccent : .white).multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty { Text(detail).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if showsDuration { TrackLength(seconds: duration) }
                mark.frame(width: 22).accessibilityHidden(true)
            }
            .padding(.vertical, 4).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var mark: some View {
        if multiple {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                .foregroundStyle(selected ? Color.scoutAccent : Color.scoutGrey.opacity(0.5))
        } else if selected {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.scoutAccent)
        }
    }
}

/// The green one-tap Quick setup row.
struct QuickButton: View {
    var title: String
    var detail: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SymbolTile(symbol: "bolt.fill", tint: .onScoutAccent, fill: .scoutAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.scoutTitle).foregroundStyle(Color.scoutAccent)
                    Text(detail).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Chevron()
            }.padding(.vertical, 3).contentShape(.rect)
        }.buttonStyle(.plain)
    }
}

/// A text field row in a card.
struct FieldRow: View {
    var placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.scoutGrey).accessibilityHidden(true)
            TextField(placeholder, text: $text).font(.scoutInput)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

/// One duration treatment for results, selections, setup, conversion, and saved songs.
struct TrackLength: View {
    var seconds: Double? = nil
    var track: ScoutTrack? = nil
    var file: URL? = nil
    @State private var measured: Double?
    @State private var finished = false
    private var known: Double? { TrackTime.valid(seconds) ?? TrackTime.valid(track?.duration) }
    var body: some View {
        Text(known != nil || measured != nil ? TrackTime.text(known ?? measured) : finished ? "Length unavailable" : "Length…")
            .font(ScoutFont.of(11).monospacedDigit()).foregroundStyle(Color.scoutGrey).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Track length")
            .accessibilityValue(TrackTime.text(known ?? measured))
            .accessibilityIdentifier("scout.track.length")
            .task(id: track?.id ?? file?.absoluteString ?? "") {
                guard known == nil else { return }
                measured = nil; finished = false
                if let file { measured = await TrackDurationLookup.shared.duration(address: file.absoluteString) }
                else if let track { measured = await TrackDurationLookup.shared.duration(for: track) }
                if !Task.isCancelled { finished = true }
            }
    }
}

/// A one-line search row that runs on submit.
struct SearchBox: View {
    var placeholder: String
    @State var text: String
    var busy = false
    var onSearch: (String) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.scoutGrey)
            TextField(placeholder, text: $text).font(.scoutInput).submitLabel(.search).autocorrectionDisabled().onSubmit { run() }
            if busy { ProgressView().controlSize(.small) }
            else if !text.isEmpty {
                Button("Search") { run() }.font(.scoutTitle).foregroundStyle(Color.scoutAccent).buttonStyle(.borderless)
            }
        }
        .frame(minHeight: 36)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
    private func run() { let term = text.trimmingCharacters(in: .whitespaces); if !term.isEmpty { onSearch(term) } }
}

/// A cover from bytes or a URL, with a selection ring.
struct CoverTile: View {
    var option: CoverOption
    var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let data = option.data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
                else if let url = option.url {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { ZStack { Color.white.opacity(0.06); ProgressView() } }
                } else { ZStack { Color.white.opacity(0.06); Image(systemName: "photo").foregroundStyle(Color.scoutGrey) } }
            }
            .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.scoutAccent : .clear, lineWidth: 3) }
            .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.onScoutAccent, Color.scoutAccent).padding(6) } }
            Text(option.label).font(.scoutSubtitle).foregroundStyle(selected ? Color.scoutAccent : Color.scoutGrey).lineLimit(1)
        }
    }
}

/// Fetches a cover's bytes when it is picked from a URL.
enum CoverLoader {
    static func data(_ option: CoverOption) async -> Data? {
        if let data = option.data { return data }
        guard let url = option.url, let (data, response) = await Net.get(url, session: .shared),
              response.statusCode == 200, data.count < 15_000_000, UIImage(data: data) != nil else { return nil }
        return data
    }
}

/// An album's release date: the catalogs' dates to pick from, or any day; off means none.
struct ReleaseDatePicker: View {
    @Binding var date: Date?
    var suggestions: [Date] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { day in
                            Button { date = day } label: {
                                Chip(title: day.formatted(date: .abbreviated, time: .omitted), icon: nil,
                                     selected: date.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false)
                            }.buttonStyle(.borderless)
                        }
                    }
                }.scrollClipDisabled()
            }
            Toggle(isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? suggestions.first ?? Date()) : nil })) {
                Text("Set a release date").font(.scoutTitle)
            }.tint(.scoutAccent).accessibilityIdentifier("scout.album.date.toggle")
            if date != nil {
                DatePicker(selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date) {
                    Text("Released").font(.scoutTitle)
                }.accessibilityIdentifier("scout.album.date")
            } else {
                ScoutNote("Without one, the songs get no release date.")
            }
        }.padding(.vertical, 4)
    }
}
