import Foundation
import SwiftData

struct SpeakerProfileValue: Codable, Hashable, Sendable {
    let id: UUID
    let speakerID: String
    let name: String?
    let colorIndex: Int

    init(id: UUID = UUID(), speakerID: String, name: String? = nil, colorIndex: Int) {
        self.id = id
        self.speakerID = speakerID
        self.name = name
        self.colorIndex = colorIndex
    }
}

struct SpeakerTurnValue: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float

    init(
        id: UUID = UUID(),
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    var duration: TimeInterval { max(0, endTime - startTime) }
}

@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var speakerID: String
    var name: String?
    var colorIndex: Int
    var recording: Recording?

    init(id: UUID = UUID(), speakerID: String, name: String? = nil, colorIndex: Int) {
        self.id = id
        self.speakerID = speakerID
        self.name = name
        self.colorIndex = colorIndex
    }

    convenience init(value: SpeakerProfileValue) {
        self.init(id: value.id, speakerID: value.speakerID, name: value.name, colorIndex: value.colorIndex)
    }

    var value: SpeakerProfileValue {
        .init(id: id, speakerID: speakerID, name: name, colorIndex: colorIndex)
    }

    var sortOrder: Int {
        Int(speakerID.drop(while: { !$0.isNumber })) ?? Int.max
    }
}

@Model
final class SpeakerTurn {
    @Attribute(.unique) var id: UUID
    var speakerID: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float
    var recording: Recording?

    init(value: SpeakerTurnValue) {
        id = value.id
        speakerID = value.speakerID
        startTime = value.startTime
        endTime = value.endTime
        confidence = value.confidence
    }

    var value: SpeakerTurnValue {
        .init(id: id, speakerID: speakerID, startTime: startTime, endTime: endTime, confidence: confidence)
    }

    var duration: TimeInterval { max(0, endTime - startTime) }
}
