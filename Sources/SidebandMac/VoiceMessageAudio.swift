@preconcurrency import AVFoundation
import Foundation
import Observation
import SidebandCore

private final class AudioConverterInputBox: @unchecked Sendable {
    private var buffer: AVAudioBuffer?
    init(_ buffer: AVAudioBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else { status.pointee = .noDataNow; return nil }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

enum VoiceMessageAudioError: LocalizedError {
    case microphoneDenied
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to record a voice message. Enable it for Lower Sideband in System Settings."
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

@MainActor
@Observable
final class LiveVoiceAudioEngine {
    private(set) var isRunning = false
    var isMuted = false
    var onEncodedFrame: ((Data) -> Void)?
    private(set) var bufferedFrameCount = 0
    private(set) var playbackUnderruns = 0
    private(set) var droppedPlaybackFrames = 0
    private(set) var isPlaybackRecovering = false
    #if os(iOS)
    private(set) var audioRouteName = "Speaker"
    private(set) var isSpeakerEnabled = true
    #endif

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var captureConverter: AVAudioConverter?
    private var encoder: AVAudioConverter?
    private var decoder: AVAudioConverter?
    private var pendingSamples: [Float] = []
    private var jitterBuffer = LXSTJitterBuffer()
    private var playbackTask: Task<Void, Never>?
    private let sampleRate = 24_000.0
    private let frameLength = 1_440 // 60 ms, matching LXST's default profile.
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    @ObservationIgnored private var opusFormat: AVAudioFormat? {
        AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 8_000
        ])
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await microphonePermissionGranted() else { throw VoiceMessageAudioError.microphoneDenied }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        if CallKitCoordinator.shared.hasManagedCall {
            await CallKitCoordinator.shared.waitForAudioActivation()
            if !CallKitCoordinator.shared.isAudioSessionActive { try session.setActive(true) }
        } else {
            try session.setActive(true)
        }
        let hasExternalRoute = session.currentRoute.outputs.contains {
            $0.portType != .builtInReceiver && $0.portType != .builtInSpeaker
        }
        try session.overrideOutputAudioPort(hasExternalRoute ? .none : .speaker)
        refreshAudioRoute()
        #endif
        guard let opusFormat,
              let encoder = AVAudioConverter(from: pcmFormat, to: opusFormat),
              let decoder = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw VoiceMessageAudioError.recordingUnavailable
        }
        self.encoder = encoder
        self.decoder = decoder
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let captureConverter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw VoiceMessageAudioError.recordingUnavailable
        }
        self.captureConverter = captureConverter
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        let requestedFrames = AVAudioFrameCount(max(256, inputFormat.sampleRate * 0.02))
        input.installTap(onBus: 0, bufferSize: requestedFrames, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in self?.consumeInput(buffer) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        startPlaybackLoop()
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        captureConverter = nil
        encoder = nil
        decoder = nil
        pendingSamples.removeAll(keepingCapacity: false)
        jitterBuffer.reset()
        bufferedFrameCount = 0
        playbackUnderruns = 0
        droppedPlaybackFrames = 0
        isPlaybackRecovering = false
        isRunning = false
        #if os(iOS)
        if !CallKitCoordinator.shared.hasManagedCall {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    func play(opus payload: Data) {
        guard !payload.isEmpty else { return }
        jitterBuffer.enqueue(payload)
        bufferedFrameCount = jitterBuffer.count
        droppedPlaybackFrames = jitterBuffer.droppedFrameCount
    }

    #if os(iOS)
    func toggleSpeakerRoute() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(isSpeakerEnabled ? .none : .speaker)
            refreshAudioRoute()
        } catch {
            refreshAudioRoute()
        }
    }

    func refreshAudioRoute() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        audioRouteName = output?.portName ?? "Audio"
        isSpeakerEnabled = output?.portType == .builtInSpeaker
    }

    func recoverAudioIfNeeded() {
        guard isRunning, !engine.isRunning else { return }
        do {
            try engine.start()
            if !player.isPlaying { player.play() }
        } catch {
            // CallKit can temporarily deactivate audio during an interruption.
            // The call timer retries after the system restores the session.
        }
    }
    #endif

    private func decodeAndSchedule(_ payload: Data) {
        guard isRunning, let opusFormat, let decoder else { return }
        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: max(1_275, payload.count))
        payload.copyBytes(to: compressed.data.assumingMemoryBound(to: UInt8.self), count: payload.count)
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(frameLength), mDataByteSize: UInt32(payload.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
        let inputBox = AudioConverterInputBox(compressed)
        var error: NSError?
        let status = decoder.convert(to: output, error: &error) { _, inputStatus in
            inputBox.next(inputStatus)
        }
        guard status != .error, output.frameLength > 0 else { return }
        player.scheduleBuffer(output)
        if !player.isPlaying { player.play() }
    }

    private func consumeInput(_ input: AVAudioPCMBuffer) {
        guard isRunning, let captureConverter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * sampleRate / input.format.sampleRate)) + 8
        guard let converted = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
        let inputBox = AudioConverterInputBox(input)
        var error: NSError?
        let status = captureConverter.convert(to: converted, error: &error) { _, inputStatus in
            inputBox.next(inputStatus)
        }
        guard status != .error, let samples = converted.floatChannelData?[0] else { return }
        if isMuted {
            pendingSamples.append(contentsOf: repeatElement(0, count: Int(converted.frameLength)))
        } else {
            pendingSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        }
        while pendingSamples.count >= frameLength {
            let frame = Array(pendingSamples.prefix(frameLength))
            pendingSamples.removeFirst(frameLength)
            if let encoded = encode(frame) { onEncodedFrame?(encoded) }
        }
    }

    private func startPlaybackLoop() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                if let payload = self.jitterBuffer.nextFrame() {
                    self.decodeAndSchedule(payload)
                }
                self.bufferedFrameCount = self.jitterBuffer.count
                self.playbackUnderruns = self.jitterBuffer.underrunCount
                self.isPlaybackRecovering = self.playbackUnderruns > 0 && !self.jitterBuffer.isPrimed
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func encode(_ samples: [Float]) -> Data? {
        guard let encoder, let opusFormat,
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameLength)),
              let channel = input.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: frameLength) }
        input.frameLength = AVAudioFrameCount(frameLength)
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: 1_275)
        let inputBox = AudioConverterInputBox(input)
        var error: NSError?
        let status = encoder.convert(to: output, error: &error) { _, inputStatus in
            inputBox.next(inputStatus)
        }
        guard status != .error, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
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
