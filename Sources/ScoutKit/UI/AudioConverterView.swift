import SwiftUI
import UniformTypeIdentifiers

struct AudioConverterView: View {
    @StateObject private var converter: AudioFileConverter
    @State private var picking = false
    @State private var pickerError: String?
    @Environment(\.dismiss) private var dismiss
    init(library: ScoutLibrary) { _converter = StateObject(wrappedValue: AudioFileConverter(library: library)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavRow(title: "Choose audio files", subtitle: "From Spotify → Scout, or any other folder.", symbol: "folder") { picking = true }
                        .disabled(converter.busy).accessibilityIdentifier("scout.converter.choose")
                } header: {
                    Text("Convert audio files to AAC (.m4a) for Spotify. Converted copies are saved in Spotify → Scout. Your originals stay in place, with names, artists, covers and lyrics kept where available.")
                        .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).textCase(nil).padding(.bottom, 8)
                }
                if let pickerError { Section { RowLabel(title: pickerError, symbol: "exclamationmark.circle", tint: .scoutRed) } }
                if !converter.items.isEmpty {
                    Section {
                        ForEach(converter.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.scoutTitle)
                                    Text(item.format).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
                                    Text(item.status).font(.scoutSubtitle).foregroundStyle(item.saved == nil ? Color.scoutGrey : Color.scoutAccent)
                                }
                                Spacer()
                                TrackLength(seconds: item.duration)
                                if item.saved != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutAccent) }
                            }
                        }
                    } header: { ScoutHeader("Files") }
                }
            }
            .scoutList()
            .safeAreaInset(edge: .bottom) {
                Button { Task { await converter.convert() } } label: {
                    HStack { if converter.busy { ProgressView().tint(Color.onScoutAccent) }; Text(converter.busy ? "Working…" : "Convert for Spotify") }
                        .font(ScoutFont.of(15, bold: true)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).tint(.scoutAccent).foregroundStyle(Color.onScoutAccent).controlSize(.large)
                .disabled(!converter.canConvert).accessibilityIdentifier("scout.converter.convert")
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                .background(LinearGradient(colors: [Color.scoutBackground.opacity(0), Color.scoutBackground], startPoint: .top, endPoint: .center))
            }
            .navigationTitle("File converter").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(converter.busy) } }
            .interactiveDismissDisabled(converter.busy)
            // Include data so a mislabeled audio file remains selectable.
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): pickerError = nil; Task { await converter.add(urls) }
                case .failure(let error): pickerError = error.localizedDescription
                }
            }
        }.preferredColorScheme(.dark).tint(.scoutAccent)
    }
}
