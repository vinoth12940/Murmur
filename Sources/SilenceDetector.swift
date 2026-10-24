import Foundation

/// Decides when a hands-free ("latched") recording should end by itself.
/// Pure logic with the clock passed in, so it can be tested without audio.
struct SilenceDetector {
    enum Decision: Equatable { case keepGoing, stop, cancel }

    let voiceThreshold: Float
    let silenceTimeout: TimeInterval
    let noSpeechTimeout: TimeInterval

    private var heardSpeech = false
    private var lastVoice: Date
    private var started: Date

    init(now: Date, voiceThreshold: Float = 0.12, silenceTimeout: TimeInterval = 2.5, noSpeechTimeout: TimeInterval = 12) {
        self.voiceThreshold = voiceThreshold
        self.silenceTimeout = silenceTimeout
        self.noSpeechTimeout = noSpeechTimeout
        lastVoice = now
        started = now
    }

    mutating func reset(now: Date) {
        heardSpeech = false
        lastVoice = now
        started = now
    }

    /// Feed every audio level. Push-to-talk (not latched) never ends on its own.
    mutating func update(level: Float, now: Date, latched: Bool) -> Decision {
        if level > voiceThreshold {
            heardSpeech = true
            lastVoice = now
        }
        guard latched else { return .keepGoing }
        if heardSpeech, now.timeIntervalSince(lastVoice) > silenceTimeout { return .stop }
        if !heardSpeech, now.timeIntervalSince(started) > noSpeechTimeout { return .cancel }
        return .keepGoing
    }
}
