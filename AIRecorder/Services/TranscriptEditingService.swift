import Foundation
import SwiftData

@MainActor
enum RecordingLanguageResolver {
    static func sourceLanguage(for recording: Recording) -> String? {
        switch recording.requestedLanguage {
        case .spanish: "es"; case .english: "en"; case .german: "de"
        case .automatic: recording.detectedLanguage.flatMap(SpokenLanguageResolver.canonicalCode) ?? SpokenLanguageResolver.detect(in: recording.transcript)
        }
    }
}

@MainActor
enum TranscriptEditingService {
    struct EditResult: Sendable { let translationWasUpdated: Bool; let translationError: String? }
    static func updateCue(recording: Recording, cueID: UUID, newText: String, context: ModelContext) async throws -> EditResult {
        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines).cleanedTranscriptSpacing
        guard !clean.isEmpty, let cue = recording.cues.first(where: { $0.id == cueID }) else { throw AppError.invalidState }
        cue.text = clean
        recording.transcript = recording.orderedCues.map(\.text).joined(separator: " ").cleanedTranscriptSpacing
        let affected = recording.translatedCues.filter { cue.index >= $0.sourceStartIndex && cue.index <= $0.sourceEndIndex }
        affected.forEach { $0.needsRetranslation = true }
        let legacy = cue.translatedText?.isEmpty == false
        if !affected.isEmpty || legacy { recording.translationStatus = .partial }
        try context.save(); try? RecordingRecoveryStore.write(.init(recording: recording))
        guard recording.translationEnabled, let target = recording.translationTargetLanguage, let source = RecordingLanguageResolver.sourceLanguage(for: recording), !TranslationPolicy.sameLanguage(source, target) else { return .init(translationWasUpdated: affected.isEmpty && !legacy, translationError: nil) }
        let translator = SubtitleTranslationController(); var errorMessage: String?; var didUpdate = false
        for translated in affected {
            let sourceCues = recording.orderedCues.filter { $0.index >= translated.sourceStartIndex && $0.index <= translated.sourceEndIndex }
            guard !sourceCues.isEmpty else { continue }
            do { translated.text = try await translator.translate(sourceCues.map(\.text).joined(separator: " "), source: source, target: target, quality: .highFidelity); translated.startTime = sourceCues.first?.startTime ?? translated.startTime; translated.endTime = sourceCues.last?.endTime ?? translated.endTime; translated.needsRetranslation = false; didUpdate = true }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
        }
        if legacy { do { cue.translatedText = try await translator.translate(cue.text, source: source, target: target, quality: .highFidelity); didUpdate = true } catch { if errorMessage == nil { errorMessage = error.localizedDescription } } }
        if !recording.translatedCues.isEmpty { recording.translationStatus = recording.translatedCues.contains(where: \.needsRetranslation) ? .partial : .complete }
        try context.save(); try? RecordingRecoveryStore.write(.init(recording: recording))
        return .init(translationWasUpdated: didUpdate && !recording.translatedCues.contains(where: \.needsRetranslation), translationError: errorMessage)
    }
}
