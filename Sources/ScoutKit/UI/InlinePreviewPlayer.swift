import SwiftUI

struct InlinePreviewPlayer: View {
    @ObservedObject var scout: ScoutService
    @State private var scrubbing = false
    @State private var position: Double = 0
    var body: some View {
        VStack(spacing: 6) {
            if scout.previewLoading {
                HStack {
                    Text(scout.previewStatus).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
                    Spacer()
                    if let progress = scout.previewProgress { Text("\(Int(progress * 100))%").font(ScoutFont.of(11).monospacedDigit()).foregroundStyle(Color.scoutGrey) }
                    Button { scout.stopPreview() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutGrey) }.accessibilityLabel("Cancel preview")
                }
                if let progress = scout.previewProgress { ProgressView(value: progress) }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                HStack(spacing: 12) {
                    Button { scout.togglePreview() } label: {
                        Image(systemName: scout.previewPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(Color.white, in: .circle)
                    }.accessibilityLabel(scout.previewPlaying ? "Pause preview" : "Play preview")
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { scrubbing ? position : scout.previewPosition }, set: { position = $0 }),
                               in: 0...max(1, scout.previewDuration), onEditingChanged: { editing in
                            if editing { position = scout.previewPosition; scrubbing = true }
                            else { scout.seekPreview(to: position); scrubbing = false }
                        }).accessibilityLabel("Preview position")
                        HStack {
                            Text(TrackTime.position(scrubbing ? position : scout.previewPosition))
                            Spacer()
                            Text(TrackTime.text(scout.previewDuration))
                        }.font(ScoutFont.of(10).monospacedDigit()).foregroundStyle(Color.scoutGrey)
                    }
                    Button { scout.stopPreview() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutGrey) }.accessibilityLabel("Close preview")
                }
            }
        }
        .padding(10).tint(.scoutGreen).background(Color.scoutCard, in: .rect(cornerRadius: 10))
        .padding(.leading, 56).padding(.bottom, 8)
        .accessibilityIdentifier("scout.preview.player")
    }
}
