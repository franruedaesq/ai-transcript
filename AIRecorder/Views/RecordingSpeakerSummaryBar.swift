import SwiftUI

struct RecordingSpeakerSummaryBar: View {
    let speakers: [SpeakerSummaryItem]
    let hasTranscriptCues: Bool
    let isProcessing: Bool
    let progress: Double?
    let statusText: String?
    let hasPlayableAudio: Bool
    let identify: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(.blue.opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppVisualStyle.cardTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if isProcessing, let progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 150)
                } else if !speakers.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(actionTitle, action: action)
                .font(.subheadline)
                .bold()
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(isProcessing || (speakers.isEmpty && (!hasTranscriptCues || !hasPlayableAudio)))
        }
        .padding(.horizontal, AppVisualStyle.cardPadding)
        .padding(.vertical, speakers.isEmpty && !isProcessing ? 12 : AppVisualStyle.cardPadding)
        .appCardSurface()
    }

    private var title: String {
        if isProcessing {
            return statusText ?? AppLocalization.string("Identificando hablantes…")
        }
        if speakers.isEmpty {
            return AppLocalization.string("Identificar hablantes")
        }
        if speakers.count == 1 {
            return AppLocalization.string("1 hablante identificado")
        }
        return String(localized: "\(speakers.count) hablantes identificados", locale: AppLocalization.locale)
    }

    private var detail: String {
        return speakers.map(\.name).joined(separator: ", ")
    }

    private var actionTitle: String {
        speakers.isEmpty ? AppLocalization.string("Identificar") : AppLocalization.string("Editar etiquetas")
    }

    private func action() {
        speakers.isEmpty ? identify() : edit()
    }
}
