import AVFoundation

/// Shared audio setup. Output goes to AirPods (or the speaker) while the phone's own mic listens.
enum AudioSession {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }
}

/// Speaks instructions aloud.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    /// When false, nothing is spoken (voice channel switched off).
    var isEnabled = true
    /// BCP 47 language code for the voice, e.g. "en-US". Nil uses the system language.
    var language: String?
    /// Called on the main thread with every line that is spoken, for the on-screen log.
    var onSpeak: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak now. By default this cuts off whatever was being said, so guidance stays current.
    func say(_ text: String, interrupt: Bool = true) {
        DispatchQueue.main.async {
            self.onSpeak?(text)
            guard self.isEnabled else { return }
            if interrupt { self.synthesizer.stopSpeaking(at: .immediate) }
            self.synthesizer.speak(self.utterance(text))
        }
    }

    /// Speak and return when the sentence has finished (or was cut off).
    @MainActor
    func sayAndWait(_ text: String) async {
        onSpeak?(text)
        guard isEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = utterance(text)
        await withCheckedContinuation { continuation in
            waiters[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        DispatchQueue.main.async { self.synthesizer.stopSpeaking(at: .immediate) }
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.53
        utterance.voice = AVSpeechSynthesisVoice(language: language ?? AVSpeechSynthesisVoice.currentLanguageCode())
        return utterance
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.waiters.removeValue(forKey: ObjectIdentifier(utterance))?.resume()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }
}
