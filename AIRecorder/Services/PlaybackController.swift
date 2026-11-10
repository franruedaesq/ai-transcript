@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    private var player: AVPlayer?
    private var timer: Timer?
    private var clipEndTime: TimeInterval?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var isLoading = false
    var isReady = false
    var playbackRate: Float = 1.0
    let supportedRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    func load(url: URL) async throws {
        stop()
        isLoading = true
        defer { isLoading = false }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        let assetDuration = try await asset.load(.duration)
        try Task.checkCancellation()

        let seconds = assetDuration.seconds
        guard isPlayable, seconds.isFinite, seconds > 0 else {
            throw AppError.unsupportedAudio
        }

        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        duration = seconds
        currentTime = 0
        isPlaying = false
        isReady = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            clipEndTime = nil
            player.playImmediately(atRate: playbackRate); isPlaying = true; startTimer()
        }
    }

    func playClip(from startTime: TimeInterval, to endTime: TimeInterval) {
        guard let player, isReady else { return }
        let start = min(max(0, startTime), duration)
        let end = min(duration, max(start + 0.35, endTime))
        seek(to: start)
        clipEndTime = end
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        clipEndTime = nil
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration)
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
    }

    func skip(_ interval: TimeInterval) { seek(to: currentTime + interval) }
    func setRate(_ rate: Float) {
        playbackRate = min(2, max(0.5, rate))
        if isPlaying { player?.playImmediately(atRate: playbackRate) }
    }

    func stop() {
        player?.pause()
        player = nil
        clipEndTime = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                let seconds = player.currentTime().seconds
                if seconds.isFinite { self.currentTime = seconds }
                if let clipEndTime = self.clipEndTime,
                   self.currentTime >= clipEndTime - 0.03 {
                    self.pause()
                    return
                }
                if self.duration > 0, self.currentTime >= self.duration - 0.05 {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}

private extension AVPlayer {
    var isPlaying: Bool { rate != 0 }
}
