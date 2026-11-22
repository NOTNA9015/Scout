import SwiftUI

// spoti.pw's look, so Scout reads as part of the same mod: black pages, inset grouped cards with a
// hairline between rows, a 13pt bold white title over an 11pt grey subtitle, uppercase grey section
// headers, symbols on small rounded tiles, Spotify's green for what is chosen and a soft red for
// what went wrong.

extension Color {
    static let scoutGreen = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
    static let scoutBackground = Color.black
    /// A card on the black: iOS's own grouped grey, as spoti.pw uses on black.
    static let scoutCard = Color(white: 0x1C / 255)
    static let scoutGrey = Color(white: 0xB3 / 255)
    static let scoutRed = Color(red: 0xF1 / 255, green: 0x5E / 255, blue: 0x6B / 255)
    static let scoutHairline = Color.white.opacity(0.1)
}

/// Spotify's own typeface when Scout runs inside Spotify (found among the fonts it registered), the
/// system's in the test host.
enum ScoutFont {
    private static let names: (regular: String?, bold: String?) = {
        let families = UIFont.familyNames.filter { let name = $0.lowercased(); return name.contains("circular") || name.contains("spotify") }
        let fonts = families.flatMap { UIFont.fontNames(forFamilyName: $0) }.filter { !$0.lowercased().contains("italic") }
        func pick(_ endings: [String]) -> String? {
            for ending in endings { if let name = fonts.first(where: { $0.lowercased().hasSuffix(ending) }) { return name } }
            return nil
        }
        return (pick(["-book", "-regular", "book", "regular"]), pick(["-bold", "bold"]))
    }()
    static func of(_ size: CGFloat, bold: Bool = false) -> Font {
        if let name = bold ? names.bold : names.regular { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: bold ? .bold : .regular)
    }
}

extension Font {
    static var scoutTitle: Font { ScoutFont.of(13, bold: true) }
    static var scoutSubtitle: Font { ScoutFont.of(11) }
    static var scoutBody: Font { ScoutFont.of(13) }
    static var scoutInput: Font { ScoutFont.of(15) }
    static var scoutHeading: Font { ScoutFont.of(24, bold: true) }
}

extension View {
    /// A page of cards: inset grouped on black.
    func scoutList() -> some View {
        listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.scoutBackground)
            .listSectionSpacing(20).environment(\.defaultMinListRowHeight, 44)
    }
    /// A card drawn outside a list, the same grey and corners as a list's.
    func scoutCard(padding: CGFloat = 0) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).background(Color.scoutCard, in: .rect(cornerRadius: 12))
    }
}

/// A section's uppercase grey title.
struct ScoutHeader: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).textCase(.uppercase) }
}

/// A grey note under a section or at the top of a page.
struct ScoutNote: View {
    var text: String
    var color: Color = .scoutGrey
    init(_ text: String, color: Color = .scoutGrey) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.scoutSubtitle).foregroundStyle(color).multilineTextAlignment(.leading) }
}

/// A symbol on a small rounded tile, the leading slot of a row.
struct SymbolTile: View {
    var symbol: String
    var tint: Color = .white
    var fill: Color = .white.opacity(0.12)
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            .frame(width: 28, height: 28).background(fill, in: .rect(cornerRadius: 7)).accessibilityHidden(true)
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
            if let symbol { SymbolTile(symbol: symbol, tint: tint) }
            VStack(alignment: .leading, spacing: 1) {
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
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).accessibilityHidden(true) }
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
                if let value { Text(value).font(.scoutTitle).foregroundStyle(Color.scoutGrey).fixedSize() }
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
                    Text("Song \(flow.page + 1) of \(flow.drafts.count)").font(.scoutTitle).foregroundStyle(Color.scoutGreen)
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
            }.buttonStyle(.glassProminent).tint(.scoutGreen).foregroundStyle(.black).controlSize(.large)
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
                    .overlay(alignment: .leading) { Capsule().fill(Color.scoutGreen).scaleEffect(x: fill, anchor: .leading) }
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
                    Text(title).font(.scoutTitle).foregroundStyle(selected ? Color.scoutGreen : .white).multilineTextAlignment(.leading)
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
                .foregroundStyle(selected ? Color.scoutGreen : Color.scoutGrey.opacity(0.5))
        } else if selected {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.scoutGreen)
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
                SymbolTile(symbol: "bolt.fill", tint: .black, fill: .scoutGreen)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.scoutTitle).foregroundStyle(Color.scoutGreen)
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
                Button("Search") { run() }.font(.scoutTitle).foregroundStyle(Color.scoutGreen).buttonStyle(.borderless)
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
            .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.scoutGreen : .clear, lineWidth: 3) }
            .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, Color.scoutGreen).padding(6) } }
            Text(option.label).font(.scoutSubtitle).foregroundStyle(selected ? Color.scoutGreen : Color.scoutGrey).lineLimit(1)
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
            }.tint(.scoutGreen).accessibilityIdentifier("scout.album.date.toggle")
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
