import AVFoundation
import CallKit

/// `.voiceChat` turns on the system's voice processing. The simulator deadlocks in it, so it uses `.default` there.
let callAudioMode: AVAudioSession.Mode = {
    #if targetEnvironment(simulator)
    .default
    #else
    .voiceChat
    #endif
}()

/// Mic capture and speech playback for a voice call, both as 24 kHz mono PCM16 (the realtime API's format).
///
/// The watch has no echo cancellation we can rely on, so the mic is gated while the Bot speaks
/// (plus a short tail). Interrupting is a button, not barge-in.
final class CallAudio: @unchecked Sendable {
    static let sampleRate = 24_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private let lock = NSLock()
    /// Serializes `start` and `stop`, which run on different threads.
    private let engineLock = NSLock()
    private var isStopped = false
    /// Bumped by `flush`, so completions of dropped buffers do not count against new ones.
    private var generation = 0
    private var queuedBuffers = 0
    private var speechEndedAt = Date.distantPast
    private var muted = false
    /// Debug only: no audio engine at all (simulator tests; the simulator's call audio hangs CoreAudio).
    var isSilent = false

    /// Speech still queued or playing.
    var isPlaying: Bool { lock.withLock { queuedBuffers > 0 } }

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// The mic is open when you are not muted and the Bot has been quiet for a moment (its own voice must not reach the server).
    private var isCaptureOpen: Bool {
        lock.withLock { !muted && queuedBuffers == 0 && Date.now.timeIntervalSince(speechEndedAt) > 0.4 }
    }

    /// Starts the engine. `onCapture` gets ~100 ms PCM16 chunks on the audio thread. Blocks, so call it off the main actor.
    func start(onCapture: @escaping @Sendable (Data) -> Void) throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !isSilent, !isStopped else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        try startCapture(onCapture)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func startCapture(_ onCapture: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else { throw CallError.audio }
        let wireFormat = wireFormat
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10), format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isCaptureOpen else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            onCapture(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        }
    }

    /// Queues PCM16 speech from the server.
    func play(_ pcm16: Data) {
        let count = pcm16.count / 2
        guard !isSilent else { return }
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        let generation = lock.withLock {
            queuedBuffers += 1
            return self.generation
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard generation == self.generation else { return }
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                if self.queuedBuffers == 0 { self.speechEndedAt = .now }
            }
        }
    }

    /// Drops speech that has not played yet (you interrupted the Bot).
    func flush() {
        lock.withLock {
            generation += 1
            queuedBuffers = 0
            speechEndedAt = .now
        }
        guard !isSilent else { return }
        player.stop()
        player.play()
    }

    /// After an interruption or a route change: drop queued speech and start the engine again.
    func restart() throws {
        flush()
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !isSilent, !isStopped, !engine.isRunning else { return }
        try engine.start()
        player.play()
    }

    /// Idempotent. A `start` that comes later does nothing.
    func stop() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !isStopped else { return }
        isStopped = true
        guard !isSilent, engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// The engine posts this when the audio route or format changes; it stops itself.
    var configurationChanges: NotificationCenter.Notifications {
        NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine)
    }

    enum CallError: LocalizedError {
        case audio
        var errorDescription: String? { "The watch could not start call audio." }
    }
}

/// Reports the call to CallKit. On watchOS, a WebSocket is only allowed during audio streaming or a CallKit VoIP call,
/// and CallKit also keeps the call alive when you lower your wrist.
@MainActor
final class CallLine: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let controller = CXCallController()
    private var callUUID: UUID?
    private var activation: CheckedContinuation<Void, Never>?
    private var isActivated = false
    /// The system or the user ended the call outside the app (e.g. from the call banner).
    var onEnded: (() -> Void)?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Starts the call and waits until CallKit activates the audio session.
    /// Returns false when CallKit did not activate it within 3 s (the simulator never does); the caller then activates it.
    func start(calling name: String) async throws -> Bool {
        let uuid = UUID()
        callUUID = uuid
        isActivated = false
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        try await controller.request(CXTransaction(action: action))
        if isActivated { return true }
        Task {
            try? await Task.sleep(for: .seconds(3))
            activation?.resume()
            activation = nil
        }
        await withCheckedContinuation { activation = $0 }
        return isActivated
    }

    func connected() {
        guard let callUUID else { return }
        provider.reportOutgoingCall(with: callUUID, connectedAt: nil)
    }

    func end() async {
        guard let callUUID else { return }
        self.callUUID = nil
        try? await controller.request(CXTransaction(action: CXEndCallAction(call: callUUID)))
    }

    // The delegate queue is nil, which is the main queue.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: callAudioMode)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            isActivated = true
            activation?.resume()
            activation = nil
        }
    }

    private func finish() {
        activation?.resume()
        activation = nil
        if callUUID != nil {
            callUUID = nil
            onEnded?()
        }
    }
}
