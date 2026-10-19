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
                    Text("Convert audio files to AAC (.m4a) for Spotify. Choose a song from Files → On My iPhone → Spotify → Scout, or from another folder.")
                    Text("Converted copies are saved in Spotify → Scout. Your originals stay in place, with names, artists, covers and lyrics kept where available.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { picking = true } label: { Label("Choose audio files", systemImage: "folder") }
                        .disabled(converter.busy).accessibilityIdentifier("scout.converter.choose")
                }
                if let pickerError { Section { Text(pickerError).foregroundStyle(.orange) } }
                if !converter.items.isEmpty {
                    Section("Files") {
                        ForEach(converter.items) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    Text(item.format).font(.caption).foregroundStyle(.secondary)
                                    Text(item.status).font(.caption).foregroundStyle(item.saved == nil ? Color.secondary : Color.scoutGreen)
                                }
                                Spacer()
                                TrackLength(seconds: item.duration)
                                if item.saved != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutGreen) }
                            }
                        }
                    }
                }
                Section {
                    Button { Task { await converter.convert() } } label: {
                        HStack { if converter.busy { ProgressView() }; Text(converter.busy ? "Working…" : "Convert for Spotify") }
                    }.disabled(!converter.canConvert).accessibilityIdentifier("scout.converter.convert")
                }
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
        }.preferredColorScheme(.dark).tint(.scoutGreen)
    }
}
