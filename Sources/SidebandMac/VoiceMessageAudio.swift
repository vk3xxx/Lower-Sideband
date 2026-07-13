import AVFoundation
import Foundation
import Observation

enum VoiceMessageAudioError: LocalizedError {
    case microphoneDenied
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to record a voice message. Enable it for Sideband in System Settings."
        case .recordingUnavailable:
            "Voice recording could not be started on this device."
        }
    }
}

@MainActor
@Observable
final class VoiceMessageRecorder {
    private(set) var isRecording = false
    private(set) var isPreparing = false
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var elapsedTask: Task<Void, Never>?
    private var recordingURL: URL?

    func start() async throws {
        guard !isRecording, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard await microphonePermissionGranted() else { throw VoiceMessageAudioError.microphoneDenied }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appending(path: "Sideband-Voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let candidate = try AVAudioRecorder(url: url, settings: settings)
        candidate.isMeteringEnabled = true
        guard candidate.prepareToRecord(), candidate.record() else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceMessageAudioError.recordingUnavailable
        }
        recorder = candidate
        recordingURL = url
        elapsed = 0
        isRecording = true
        elapsedTask = Task { @MainActor [weak self] in
            while let self, self.isRecording, !Task.isCancelled {
                self.elapsed = self.recorder?.currentTime ?? self.elapsed
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        finishSession()
        let url = recordingURL
        recorder = nil
        recordingURL = nil
        return url
    }

    func cancel() {
        recorder?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recorder = nil
        recordingURL = nil
        finishSession()
    }

    private func finishSession() {
        elapsedTask?.cancel()
        elapsedTask = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func microphonePermissionGranted() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
        #endif
    }
}

@MainActor
@Observable
final class AudioAttachmentPlayer {
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func load(_ url: URL) {
        guard player?.url != url else { return }
        stop()
        guard let candidate = try? AVAudioPlayer(contentsOf: url) else { return }
        candidate.prepareToPlay()
        player = candidate
        duration = candidate.duration
        currentTime = 0
        isReady = true
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            progressTask?.cancel()
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { return }
            isPlaying = true
            startProgressUpdates()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while let self, let player = self.player, !Task.isCancelled {
                self.currentTime = player.currentTime
                self.isPlaying = player.isPlaying
                if !player.isPlaying { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
