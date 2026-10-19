import SwiftUI

extension Color {
    static let scoutGreen = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let scoutBackground = Color(red: 0.07, green: 0.07, blue: 0.08)
}

/// Every step: a title, an optional "Song 2 of 5" line, its content, and Back / Next.
struct StepPage<Content: View>: View {
    @ObservedObject var flow: ScoutFlow
    var title: String
    var subtitle: String?
    var nextTitle = "Next"
    var nextEnabled = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        if flow.perSong {
                            Text("Song \(flow.page + 1) of \(flow.drafts.count)").font(.caption.weight(.semibold)).foregroundStyle(Color.scoutGreen)
                                .accessibilityIdentifier("scout.step.counter")
                        }
                        Text(title).font(.title2.bold())
                        if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        if let step = flow.current, [.names, .artists, .cover, .lyrics].contains(step), flow.drafts.indices.contains(flow.page) {
                            let draft = flow.drafts[flow.page]
                            HStack(alignment: .firstTextBaseline) {
                                Text(draft.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Spacer()
                                TrackLength(seconds: draft.song.duration, track: draft.song.source, file: draft.song.file)
                            }
                        }
                    }
                    content
                }.padding(20)
            }
            HStack(spacing: 12) {
                Button("Back") { withAnimation { flow.back() } }.buttonStyle(.glass).controlSize(.large)
                    .disabled(flow.path.count <= 1 && flow.page == 0)
                Button(nextTitle) { withAnimation { flow.next() } }.buttonStyle(.glassProminent).tint(.scoutGreen).foregroundStyle(.black).controlSize(.large)
                    .frame(maxWidth: .infinity).disabled(!nextEnabled).accessibilityIdentifier("scout.next")
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .background(Color.scoutBackground)
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A selectable row with a circle or checkmark.
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
                Image(systemName: selected ? (multiple ? "checkmark.square.fill" : "checkmark.circle.fill") : (multiple ? "square" : "circle"))
                    .font(.title3).foregroundStyle(selected ? Color.scoutGreen : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.white).multilineTextAlignment(.leading)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if showsDuration { TrackLength(seconds: duration) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(selected ? Color.scoutGreen.opacity(0.12) : .white.opacity(0.05), in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
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

/// A one-line search box that runs on submit.
struct SearchBox: View {
    var placeholder: String
    @State var text: String
    var busy = false
    var onSearch: (String) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).submitLabel(.search).autocorrectionDisabled().onSubmit { run() }
            if busy { ProgressView().controlSize(.small) }
            else if !text.isEmpty { Button("Search") { run() }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutGreen) }
        }
        .padding(.horizontal, 14).frame(height: 44).glassEffect(in: .capsule)
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
                } else { ZStack { Color.white.opacity(0.06); Image(systemName: "photo").foregroundStyle(.secondary) } }
            }
            .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.scoutGreen : .clear, lineWidth: 3) }
            .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, Color.scoutGreen).padding(6) } }
            Text(option.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
