import Foundation
import SwiftData

@MainActor
enum RecordingArchiveImportService {
    enum RestoreError: LocalizedError {
        case missingJSON, invalidJSON, missingAudio(String?)
        var errorDescription: String? {
            switch self {
            case .missingJSON: AppLocalization.string("Selecciona el archivo JSON de la copia.")
            case .invalidJSON: AppLocalization.string("El JSON no es una copia portable válida de AI Recorder.")
            case .missingAudio(let name): AppLocalization.string(name.map { "Falta el audio \($0). Selecciona el JSON y el audio juntos." } ?? "Esta copia necesita el audio original. Selecciona el JSON y el audio juntos.")
            }
        }
    }

    static func restore(from selectedURLs: [URL], context: ModelContext) async throws -> Recording {
        guard let jsonURL = selectedURLs.first(where: { $0.pathExtension.lowercased() == "json" }) else { throw RestoreError.missingJSON }
        let hasAccess = jsonURL.startAccessingSecurityScopedResource(); defer { if hasAccess { jsonURL.stopAccessingSecurityScopedResource() } }
        let archive: PortableRecordingArchive
        do { archive = try JSONDecoder().decode(PortableRecordingArchive.self, from: Data(contentsOf: jsonURL)) } catch { throw RestoreError.invalidJSON }
        let audioCandidates = selectedURLs.filter { ["m4a", "caf", "wav"].contains($0.pathExtension.lowercased()) }
        let audioURL = archive.audioFilename.flatMap { expected in audioCandidates.first { $0.lastPathComponent.localizedCaseInsensitiveCompare(expected) == .orderedSame } } ?? (audioCandidates.count == 1 ? audioCandidates[0] : nil)
        guard let audioURL else { throw RestoreError.missingAudio(archive.audioFilename) }
        let id = UUID()
        let destination = try await StorageService.shared.importAudio(from: audioURL, id: id)
        let relativePath = try await StorageService.shared.relativePath(for: destination)
        let recording = Recording(id: id, title: archive.title, createdAt: archive.createdAt ?? .now, duration: archive.duration ?? archive.originalCues.map(\.endTime).max() ?? 0, audioRelativePath: relativePath, source: archive.source ?? .imported, engine: archive.engine ?? .nemotron, requestedLanguage: archive.requestedLanguage ?? .automatic, detectedLanguage: archive.detectedLanguage, transcript: archive.transcript, status: .saved, translationEnabled: archive.translationEnabled ?? !archive.translatedCues.isEmpty, translationTargetLanguage: archive.translationTargetLanguage, translationStatus: archive.translationStatus ?? (archive.translatedCues.isEmpty ? .none : .complete), expectedSpeakerCount: archive.expectedSpeakerCount)
        context.insert(recording)
        for value in archive.originalCues { let cue = TranscriptCue(value: value); cue.recording = recording; recording.cues.append(cue) }
        for (index, value) in (archive.tokens ?? []).enumerated() { let token = TranscriptToken(index: index, value: value); token.recording = recording; recording.tokens.append(token) }
        for value in archive.translatedCues { let cue = TranslatedSubtitleCue(value: value); cue.recording = recording; recording.translatedCues.append(cue) }
        for value in archive.markers ?? [] { let marker = RecordingMarker(id: value.id, time: value.time, title: value.title, createdAt: value.createdAt); marker.recording = recording; recording.markers.append(marker) }
        for value in archive.speakerProfiles ?? [] { let profile = SpeakerProfile(value: value); profile.recording = recording; recording.speakerProfiles.append(profile) }
        for value in archive.speakerTurns ?? [] { let turn = SpeakerTurn(value: value); turn.recording = recording; recording.speakerTurns.append(turn) }
        if recording.transcript.isEmpty { recording.transcript = recording.orderedCues.map(\.text).joined(separator: " ").cleanedTranscriptSpacing }
        do { try context.save(); try RecordingRecoveryStore.write(.init(recording: recording)); return recording }
        catch { context.delete(recording); try? context.save(); try? await StorageService.shared.removeRecording(id: id); throw error }
    }
}
