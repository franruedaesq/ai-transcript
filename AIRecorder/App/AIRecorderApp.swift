import SwiftData
import SwiftUI

@main
struct AIRecorderApp: App {
    private let container: ModelContainer
    @State private var settings = AppSettings()
    @State private var session = RecordingSessionController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ModelContainer(
                for: Recording.self,
                TranscriptCue.self,
                TranslatedSubtitleCue.self
            )
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.statusRaw == "recording" || $0.statusRaw == "paused" })
            for recording in try context.fetch(descriptor) { recording.status = .interrupted }
            try context.save()
        } catch {
            fatalError("No se pudo abrir la base de datos local: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(settings: settings, session: session)
                .modelContainer(container)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await session.handleBackgroundTransition() } }
                }
        }
    }
}
