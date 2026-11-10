import SwiftUI
import UIKit

struct AppRootView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    @State private var selectedRecordingID: UUID?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            padRoot
                .environment(\.appLayoutMode, .pad)
        } else {
            phoneRoot
                .environment(\.appLayoutMode, .phone)
        }
    }

    private var phoneRoot: some View {
        NavigationStack {
            LibraryView(settings: settings, session: session)
                .navigationDestination(for: UUID.self) { id in
                    RecordingDetailLookupView(recordingID: id, settings: settings)
                }
        }
        .tint(.blue)
    }

    private var padRoot: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            LibraryView(
                settings: settings,
                session: session,
                selectedRecordingID: selectedRecordingID,
                openRecording: { id in
                    selectedRecordingID = id
                    preferredCompactColumn = .detail
                },
                recordingDeleted: { id in
                    if selectedRecordingID == id {
                        selectedRecordingID = nil
                        preferredCompactColumn = .sidebar
                    }
                }
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            if let selectedRecordingID {
                RecordingDetailLookupView(
                    recordingID: selectedRecordingID,
                    settings: settings,
                    recordingDeleted: { id in
                        guard self.selectedRecordingID == id else { return }
                        self.selectedRecordingID = nil
                        preferredCompactColumn = .sidebar
                    }
                )
                    .id(selectedRecordingID)
            } else {
                ContentUnavailableView(
                    "Selecciona una grabación",
                    systemImage: "waveform",
                    description: Text("El audio, la transcripción y sus acciones aparecerán aquí.")
                )
            }
        }
        .tint(.blue)
    }
}
