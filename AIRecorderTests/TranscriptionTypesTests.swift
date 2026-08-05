import Foundation
import Testing
@testable import AIRecorder

struct TranscriptionTypesTests {
    @Test func languageCodesAreStable() {
        #expect(TranscriptionLanguage.automatic.nemotronCode == "auto")
        #expect(TranscriptionLanguage.spanish.nemotronCode == "es-ES")
        #expect(TranscriptionLanguage.english.nemotronCode == "en-US")
        #expect(TranscriptionLanguage.german.nemotronCode == "de-DE")
    }

    @Test func recordingStatesRoundTrip() {
        for state in [RecordingStatus.recording, .paused, .processing, .saved, .interrupted, .failed] {
            #expect(RecordingStatus(rawValue: state.rawValue) == state)
        }
    }


    @Test func modelPreparationOnlyPublishesRealDownloadProgress() {
        #expect(ModelPreparationState.downloading(0.42).progress == 0.42)
        #expect(ModelPreparationState.loading.progress == nil)
        #expect(ModelPreparationState.loading.isBusy)
        #expect(!ModelPreparationState.ready.isBusy)
    }
}
