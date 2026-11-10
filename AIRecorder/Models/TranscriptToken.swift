import Foundation
import SwiftData

@Model
final class TranscriptToken {
    @Attribute(.unique) var id: UUID
    var index: Int
    var token: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float
    var recording: Recording?

    init(id: UUID = UUID(), index: Int, value: AppTokenTiming) {
        self.id = id
        self.index = index
        token = value.token
        startTime = value.startTime
        endTime = value.endTime
        confidence = value.confidence
    }

    var value: AppTokenTiming {
        .init(token: token, startTime: startTime, endTime: endTime, confidence: confidence)
    }
}
