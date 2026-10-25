import AVFoundation
import Foundation
import Speech

/// Phrase matching for "Hey Murmur", tolerant of how a recognizer tends to spell an unusual word.
enum WakePhrase {
    // Includes what recognizers commonly write for "hey" ("K. Murmer", "a murmur").
    private static let greetings: Set<String> = ["hey", "hay", "hi", "hei", "heya", "k", "ok", "okay", "a", "hate"]
    private static let target = "murmur"

    static func matches(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        // "Murmur" alone is rare enough in speech to count when it is spelled almost exactly.
        if words.contains(where: { $0.count >= 5 && distance($0, target) <= 1 }) { return true }
        for (i, word) in words.enumerated() where greetings.contains(word) {
            var candidates: [String] = []
            if i + 1 < words.count { candidates.append(words[i + 1]) }
            if i + 2 < words.count { candidates.append(words[i + 1] + words[i + 2]) }
            // Mishearings like "merma" or "rumor" are 3 edits away; only allow that for longer words so "more" doesn't match.
            if candidates.contains(where: {
                let d = distance($0, target)
                return ($0.count >= 4 && d <= 2) || ($0.count >= 5 && d <= 3)
            }) { return true }
        }
        return false
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let temp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = temp
            }
        }
        return row[b.count]
    }
}

/// Listens continuously for the wake phrase with on-device speech recognition. When it hears it,
/// it releases the microphone and calls `onWake`; the owner starts a normal dictation and
/// restarts the listener afterwards. The session is recycled every couple of minutes so memory stays flat.
final class WakeWordListener {
    var onWake: (() -> Void)?

    private let engine = AVAudioEngine()
    private var loop: Task<Void, Never>?
    private let sessionLength: Double = 120

    var isRunning: Bool { loop != nil }

    func begin(locale: Locale, format: AVAudioFormat) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                let woke = await self.runSession(locale: locale, format: format)
                if woke {
                    self.loop = nil
                    self.onWake?()
                    return
                }
                // A session that dies immediately (mic busy, model error) must not spin.
                if Date().timeIntervalSince(started) < 5 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func runSession(locale: Locale, format: AVAudioFormat) async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        defer { continuation.finish() }

        do {
            // "Murmur" is a rare word; without a hint the recognizer often writes "rumor" or "remember".
            let context = AnalysisContext()
            context.contextualStrings[.general] = ["Murmur", "Hey Murmur"]
            try await analyzer.setContext(context)
            try await analyzer.start(inputSequence: stream)
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: format) else { return false }
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
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
                if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
            }
            engine.prepare()
            try engine.start()
            Log.write("wake: listening (mic \(Int(inputFormat.sampleRate)) Hz → \(Int(format.sampleRate)) Hz)")
        } catch {
            Log.write("wake: failed to start: \(error)")
            releaseMic()
            await analyzer.cancelAndFinishNow()
            return false
        }

        let seconds = sessionLength
        let woke = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await result in transcriber.results {
                        let heard = String(result.text.characters)
                        let hit = WakePhrase.matches(heard)
                        // What was heard is private: only written when the user turned on verbose logging.
                        if hit { Log.write("wake: MATCH") }
                        else if Log.verbose { Log.write("wake: heard “\(heard.prefix(60))”") }
                        if hit { return true }
                    }
                } catch {
                    if !(error is CancellationError) { Log.write("wake: recognizer error: \(error)") }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            // A new input device or format invalidates this session; end it so the loop starts a fresh one.
            let engine = self.engine
            group.addTask {
                let started = Date()
                for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine) {
                    if Date().timeIntervalSince(started) > 1.0 {
                        Log.write("wake: input device changed, restarting listener")
                        return false
                    }
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        releaseMic()
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        return woke
    }

    private func releaseMic() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
