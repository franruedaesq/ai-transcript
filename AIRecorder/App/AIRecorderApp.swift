import SwiftData
import SwiftUI

@main
struct AIRecorderApp: App {
    private let container: ModelContainer
    @State private var settings = AppSettings()
    @State private var session = RecordingSessionController()
    @AppStorage("appUiLanguage") private var appUiLanguage: String = "system"
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    init() {
        var resolvedContainer: ModelContainer!
        do {
            resolvedContainer = try ModelContainer(
                for: Recording.self,
                TranscriptCue.self,
                TranscriptToken.self,
                TranslatedSubtitleCue.self,
                RecordingMarker.self,
                SpeakerProfile.self,
                SpeakerTurn.self
            )
            let context = ModelContext(resolvedContainer)
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.statusRaw == "recording" || $0.statusRaw == "paused" || $0.statusRaw == "processing" })
            for recording in try context.fetch(descriptor) { recording.status = .interrupted }
            try context.save()
            Self.restoreRecoverySnapshots(in: resolvedContainer, onlyMissing: true)
        } catch {
            // The audio and recovery sidecars remain usable even when SwiftData
            // fails to open. Start with an in-memory index instead of crashing.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            resolvedContainer = try! ModelContainer(
                for: Recording.self,
                TranscriptCue.self,
                TranscriptToken.self,
                TranslatedSubtitleCue.self,
                RecordingMarker.self,
                SpeakerProfile.self,
                SpeakerTurn.self,
                configurations: fallback
            )
            Self.restoreRecoverySnapshots(in: resolvedContainer, onlyMissing: false)
        }
        container = resolvedContainer
    }

    private static func restoreRecoverySnapshots(in container: ModelContainer, onlyMissing: Bool) {
        guard let snapshots = try? RecordingRecoveryStore.loadAll() else { return }
        let context = ModelContext(container)
        let existing = onlyMissing ? Set((try? context.fetch(FetchDescriptor<Recording>()))?.map(\.id) ?? []) : []
        for snapshot in snapshots where !existing.contains(snapshot.id) {
            let recording = Recording(
                id: snapshot.id,
                title: snapshot.title,
                createdAt: snapshot.createdAt,
                duration: snapshot.duration,
                audioRelativePath: snapshot.audioRelativePath,
                source: snapshot.source,
                engine: snapshot.engine,
                requestedLanguage: snapshot.requestedLanguage,
                detectedLanguage: snapshot.detectedLanguage,
                transcript: snapshot.transcript,
                status: snapshot.status == .recording || snapshot.status == .paused || snapshot.status == .processing ? .interrupted : snapshot.status,
                translationEnabled: snapshot.translationEnabled,
                translationTargetLanguage: snapshot.translationTargetLanguage,
                translationStatus: snapshot.translationStatus ?? .none,
                expectedSpeakerCount: snapshot.expectedSpeakerCount
            )
            context.insert(recording)
            for value in snapshot.cues ?? [] { let cue = TranscriptCue(value: value); cue.recording = recording; recording.cues.append(cue) }
            for (index, value) in (snapshot.tokens ?? []).enumerated() { let token = TranscriptToken(index: index, value: value); token.recording = recording; recording.tokens.append(token) }
            for value in snapshot.translatedCues ?? [] { let cue = TranslatedSubtitleCue(value: value); cue.recording = recording; recording.translatedCues.append(cue) }
            for value in snapshot.markers ?? [] { let marker = RecordingMarker(id: value.id, time: value.time, title: value.title, createdAt: value.createdAt); marker.recording = recording; recording.markers.append(marker) }
            for value in snapshot.speakerProfiles ?? [] { let profile = SpeakerProfile(value: value); profile.recording = recording; recording.speakerProfiles.append(profile) }
            for value in snapshot.speakerTurns ?? [] { let turn = SpeakerTurn(value: value); turn.recording = recording; recording.speakerTurns.append(turn) }
        }
        try? context.save()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(settings: settings, session: session)
                .modelContainer(container)
                .environment(\.locale, appUiLanguage == "system" ? Locale.current : Locale(identifier: appUiLanguage))
                .preferredColorScheme(preferredColorScheme)
                .id(appUiLanguage)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
