import Observation
import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct RecordingTextSizeOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

@MainActor
@Observable
final class RecordingExportCoordinator {
    var sharePayload: SharePayload?
    var errorMessage: String?
    var isPreparing = false

    func prepare(_ kind: RecordingExportKind, recording: Recording) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let snapshot = RecordingExportSnapshot(recording: recording)
            let url = try await RecordingExportService.shared.prepare(kind, snapshot: snapshot)
            sharePayload = SharePayload(urls: [url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareAll(_ recording: Recording) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let snapshot = RecordingExportSnapshot(recording: recording)
            var kinds: [RecordingExportKind] = [.audio, .transcriptText, .transcriptSRT, .transcriptVTT, .archiveJSON]
            if !snapshot.translatedCues.isEmpty { kinds += [.translationText, .translationSRT, .translationVTT, .bilingualText, .bilingualSRT, .bilingualVTT] }
            sharePayload = SharePayload(urls: try await RecordingExportService.shared.prepareMany(kinds, snapshot: snapshot))
        } catch { errorMessage = error.localizedDescription }
    }

    func copyTranscript(_ recording: Recording) {
        UIPasteboard.general.string = recording.transcript
    }

    func copyTranslation(_ recording: Recording) {
        let snapshot = RecordingExportSnapshot(recording: recording)
        UIPasteboard.general.string = snapshot.translationText
    }
}

struct RecordingActionsMenu: View {
    let recording: Recording
    let coordinator: RecordingExportCoordinator
    var includeDelete = false
    var textSizeOptions: [RecordingTextSizeOption] = []
    var rename: (() -> Void)?
    var delete: (() -> Void)?

    private var hasOriginalCues: Bool { !recording.orderedCues.isEmpty }
    private var hasTranslation: Bool {
        !recording.orderedTranslatedCues.isEmpty
            || recording.orderedCues.contains(where: { $0.translatedText?.isEmpty == false })
    }

    var body: some View {
        Menu {
            if !textSizeOptions.isEmpty {
                Menu("Tamaño del texto", systemImage: "textformat.size") {
                    ForEach(textSizeOptions) { option in
                        Button(action: option.select) {
                            if option.isSelected {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
                Divider()
            }

            if let rename {
                Button(action: rename) { Label("Renombrar", systemImage: "pencil") }
                Divider()
            }
            Button {
                coordinator.copyTranscript(recording)
            } label: {
                Label("Copiar transcripción", systemImage: "doc.on.doc")
            }
            .disabled(recording.transcript.isEmpty)

            if hasTranslation {
                Button {
                    coordinator.copyTranslation(recording)
                } label: {
                    Label("Copiar traducción", systemImage: "translate")
                }
            }

            Divider()

            Button { Task { await coordinator.prepareAll(recording) } } label: {
                Label("Exportar todo", systemImage: "square.and.arrow.up.on.square")
            }

            Button {
                Task { await coordinator.prepare(.audio, recording: recording) }
            } label: {
                Label("Guardar o compartir audio", systemImage: "square.and.arrow.up")
            }

            Menu("Exportar transcripción", systemImage: "doc.text") {
                exportButton(.transcriptText)
                exportButton(.transcriptSRT, disabled: !hasOriginalCues)
                exportButton(.transcriptVTT, disabled: !hasOriginalCues)
            }

            if hasTranslation {
                Menu("Exportar traducción", systemImage: "translate") {
                    exportButton(.translationText)
                    exportButton(.translationSRT)
                    exportButton(.translationVTT)
                    exportButton(.bilingualText)
                    exportButton(.bilingualSRT, disabled: !hasOriginalCues)
                    exportButton(.bilingualVTT, disabled: !hasOriginalCues)
                }
            }

            if includeDelete, let delete {
                Divider()
                Button(role: .destructive, action: delete) {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        } label: {
            if coordinator.isPreparing {
                ProgressView()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .disabled(coordinator.isPreparing)
        .accessibilityLabel("Más acciones para \(recording.title)")
    }

    private func exportButton(_ kind: RecordingExportKind, disabled: Bool = false) -> some View {
        Button {
            Task { await coordinator.prepare(kind, recording: recording) }
        } label: {
            Label(kind.title, systemImage: kind.rawValue.contains("SRT") ? "captions.bubble" : "doc.plaintext")
        }
        .disabled(disabled)
    }
}

struct SystemShareSheet: UIViewControllerRepresentable {
    let payload: SharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: payload.urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
