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
final class Dictation {
    /// RMS level (0...1) of each captured buffer, called on an audio thread.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private(set) var locale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?

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

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [], attributeOptions: [])
    }

    func start() async throws {
        guard let locale, let format = analyzerFormat else { throw DictationError.notReady }
        guard await Self.requestMicrophone() else { throw DictationError.microphoneDenied }

        let transcriber = makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        inputContinuation = continuation

        resultsTask = Task {
            var text = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.isEmpty { continue }
                text += (text.isEmpty ? "" : " ") + piece
            }
            return text
        }
        try await analyzer.start(inputSequence: stream)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw DictationError.noAudioFormat
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.level(of: buffer))
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
                self.inputContinuation?.yield(AnalyzerInput(buffer: out))
            }
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
        stopCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        resultsTask = nil
    }

    private func stopCapture() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 9)
    }
}
