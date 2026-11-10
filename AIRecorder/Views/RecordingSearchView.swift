import SwiftUI

struct RecordingSearchResult: Identifiable {
    enum Kind {
        case transcript
        case translation

        var title: String {
            AppLocalization.string(self == .transcript ? "Transcripción" : "Traducción")
        }

        var systemImage: String {
            self == .transcript ? "text.quote" : "translate"
        }
    }

    let id: String
    let kind: Kind
    let tab: RecordingTextTab
    let destinationID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerName: String?
    let text: String

    var searchableText: String {
        [speakerName, text].compactMap { $0 }.joined(separator: " ")
    }
}

struct RecordingSearchView: View {
    let recordingTitle: String
    let results: [RecordingSearchResult]
    let select: (RecordingSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isSearchPresented = true

    var body: some View {
        NavigationStack {
            Group {
                if normalizedQuery.isEmpty {
                    ContentUnavailableView(
                        "Buscar en la transcripción o traducción",
                        systemImage: "text.magnifyingglass",
                        description: Text("Busca palabras, frases o nombres de hablantes.")
                    )
                } else if filteredResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(filteredResults) { result in
                        Button {
                            select(result)
                            dismiss()
                        } label: {
                            RecordingSearchResultRow(result: result, query: normalizedQuery)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(recordingTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Buscar en la transcripción o traducción"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredResults: [RecordingSearchResult] {
        guard !normalizedQuery.isEmpty else { return [] }
        return results.filter {
            $0.searchableText.localizedStandardContains(normalizedQuery)
        }
    }
}

private struct RecordingSearchResultRow: View {
    let result: RecordingSearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(result.kind.title, systemImage: result.kind.systemImage)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.blue)

                if let speakerName = result.speakerName {
                    Text(speakerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(result.startTime.formattedDuration) – \(result.endTime.formattedDuration)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            highlightedText
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var highlightedText: Text {
        guard let match = result.text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return Text(result.text)
        }

        let prefix = Text(String(result.text[..<match.lowerBound]))
        let highlighted = Text(String(result.text[match])).bold().foregroundStyle(.blue)
        let suffix = Text(String(result.text[match.upperBound...]))
        return Text("\(prefix)\(highlighted)\(suffix)")
    }
}
