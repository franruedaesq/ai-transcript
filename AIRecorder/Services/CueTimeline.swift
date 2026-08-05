import Foundation

enum CueTimeline {
    static func activeIndex(at time: TimeInterval, cues: [TranscriptionCueValue]) -> Int? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.startTime { high = mid - 1 }
            else if time > cue.endTime { low = mid + 1 }
            else { return mid }
        }
        return nil
    }
}
