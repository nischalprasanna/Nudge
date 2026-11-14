import AVFoundation
import Speech

/// Listens for one spoken phrase and returns it as text.
/// Uses on-device recognition when the phone supports it, so speech stays private and works offline.
final class Listener {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()

    /// Called on the main thread while listening with the microphone level, 0 (silence) to 1 (loud).
    var onLevel: ((Float) -> Void)?

    private final class State {
        var best = ""
        var lastChange = Date()
        var finished = false
    }

    /// Asks for microphone and speech recognition permission. Returns true if both were granted.
    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    var usesOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Listens until the speaker pauses, or the time limit is reached. Returns nil if nothing was heard.
    @MainActor
    func listen(maxSeconds: TimeInterval = 10, silenceSeconds: TimeInterval = 1.3) async -> String? {
        guard let recognizer, recognizer.isAvailable else { return nil }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        // Short commands are the hardest thing to recognise; these words tell it what to expect.
        request.contextualStrings = Self.expectedWords

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.removeTap(onBus: 0)
        let onLevel = self.onLevel
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let onLevel, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            // Map roughly -50 dB (quiet room) ... -12 dB (speaking close) onto 0...1.
            let decibels = 20 * log10(max(rms, 0.000_01))
            let level = min(max((decibels + 50) / 38, 0), 1)
            DispatchQueue.main.async { onLevel(level) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }

        let state = State()
        let task = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != state.best {
                        state.best = text
                        state.lastChange = Date()
                    }
                    if result.isFinal { state.finished = true }
                }
                if error != nil { state.finished = true }
            }
        }

        let started = Date()
        while !state.finished {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { break }
            let now = Date()
            if now.timeIntervalSince(started) > maxSeconds { break }
            if !state.best.isEmpty, now.timeIntervalSince(state.lastChange) > silenceSeconds { break }
            if state.best.isEmpty, now.timeIntervalSince(started) > 7 { break }
        }

        engine.stop()
        input.removeTap(onBus: 0)
        request.endAudio()
        // The recogniser often holds back a short phrase ("press one") until it is told the
        // audio has ended. Give it a moment to hand over its final answer before giving up;
        // cancelling straight away threw that answer out and reported that nothing was heard.
        let ended = Date()
        while !state.finished, Date().timeIntervalSince(ended) < (state.best.isEmpty ? 2.0 : 0.6) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { break }
        }
        task.cancel()
        return state.best.isEmpty ? nil : state.best
    }

    private static let expectedWords = [
        "press", "heat", "cook", "defrost", "reheat", "popcorn", "start", "stop", "clear", "cancel",
        "seconds", "minutes", "degrees", "power level", "timer", "time cook", "time defrost",
        "add thirty seconds", "bake", "broil", "preheat", "yes", "no",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "zero",
    ]
}
