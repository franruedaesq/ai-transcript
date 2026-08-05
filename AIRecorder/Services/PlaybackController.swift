@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false

    func load(url: URL) throws {
        stopTimer()
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        isPlaying = false
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause(); isPlaying = false; stopTimer()
        } else {
            player.play(); isPlaying = true; startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = min(max(0, time), duration)
        currentTime = player?.currentTime ?? 0
    }

    func skip(_ interval: TimeInterval) { seek(to: currentTime + interval) }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
