import AVFoundation
import Foundation
import Speech

enum DictationError: LocalizedError {
    case unsupportedLanguage
    case noAudioFormat
    case microphoneDenied
    case notReady

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "This language isn't supported by on-device speech recognition."
        case .noAudioFormat: return "No compatible audio format for speech recognition."
        case .microphoneDenied: return "Microphone access is denied. Enable it in System Settings → Privacy & Security."
        case .notReady: return "The speech model isn't ready yet."
        }
    }
}

/// Microphone capture + on-device transcription with Apple's SpeechAnalyzer.
/// Audio never leaves the Mac: the speech model is a system asset that runs locally.
///
/// `@unchecked Sendable`: the audio tap and the configuration observer run off the main thread, but they
/// only use values captured when the session started; mutable state is changed from one async flow at a time.
final class Dictation: @unchecked Sendable {
    /// RMS level (0...1) of each captured buffer, called on an audio thread.
    var onLevel: ((Float) -> Void)?
    /// In-progress text while speaking. Only used when `start(livePreview: true)`; never part of the final transcript.
    var onPartial: ((String) -> Void)?
    /// The input device or its format changed while capturing (headphones connected, device unplugged…).
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private(set) var locale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var configObserver: NSObjectProtocol?
    private var startedAt = Date.distantPast

    var isReady: Bool { analyzerFormat != nil }

    /// Resolves the locale, downloads the speech model if needed and caches the audio format.
    func prepare(locale requested: Locale, progress: ((String) -> Void)? = nil) async throws {
        analyzerFormat = nil
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw DictationError.unsupportedLanguage
        }
        let probe = makeTranscriber(supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            progress?("Downloading speech model…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            throw DictationError.noAudioFormat
        }
        locale = supported
        analyzerFormat = format
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeTranscriber(_ locale: Locale, livePreview: Bool = false) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: livePreview ? [.volatileResults] : [], attributeOptions: [])
    }

    /// Starts capture. If anything fails midway, everything already started is torn down so the
    /// next `start()` begins from a clean slate (a leftover audio tap would crash the next one).
    func start(vocabulary: [String] = [], livePreview: Bool = false) async throws {
        guard let locale, let format = analyzerFormat else { throw DictationError.notReady }
        guard await Self.requestMicrophone() else { throw DictationError.microphoneDenied }
        do {
            try await begin(locale: locale, format: format, vocabulary: vocabulary, livePreview: livePreview)
        } catch {
            await teardown()
            throw error
        }
    }

    private func begin(locale: Locale, format: AVAudioFormat, vocabulary: [String], livePreview: Bool) async throws {
        let transcriber = makeTranscriber(locale, livePreview: livePreview)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        inputContinuation = continuation

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        let partialHandler = onPartial
        resultsTask = Task {
            var finalized = ""
            var pending = ""
            func joined(_ a: String, _ b: String) -> String { a.isEmpty ? b : (b.isEmpty ? a : a + " " + b) }
            for try await result in transcriber.results {
                let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if livePreview, !result.isFinal {
                    pending = piece
                    partialHandler?(joined(finalized, pending))
                    continue
                }
                pending = ""
                if piece.isEmpty { continue }
                finalized = joined(finalized, piece)
                if livePreview { partialHandler?(finalized) }
            }
            return joined(finalized, pending)
        }
        try await analyzer.start(inputSequence: stream)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw DictationError.noAudioFormat
        }
        // The tap runs on a realtime audio thread: it only touches values captured here, never `self`.
        let levelHandler = onLevel
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            levelHandler?(Dictation.level(of: buffer))
            let ratio = format.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        startedAt = Date()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.startedAt) > 0.6 else { return }
            self.onInterrupted?()
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture, lets the analyzer finish what it heard and returns the transcript.
    func stop() async throws -> String {
        stopCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        defer { analyzer = nil; resultsTask = nil }
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        return try await resultsTask?.value ?? ""
    }

    func cancel() async {
        await teardown()
    }

    /// Releases everything a session may hold. Safe to call at any point, any number of times.
    private func teardown() async {
        stopCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        resultsTask = nil
    }

    private func stopCapture() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 9)
    }
}
