import SwiftUI

struct AppRootView: View {
    let settings: AppSettings
    let session: RecordingSessionController

    var body: some View {
        NavigationStack {
            LibraryView(settings: settings, session: session)
                .navigationDestination(for: UUID.self) { id in
                    RecordingDetailLookupView(recordingID: id, settings: settings)
                }
        }
        .tint(.blue)
    }
}
