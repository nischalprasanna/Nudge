import AVFoundation
import Speech

/// Listens for one spoken phrase and returns it as text.
/// Uses on-device recognition when the phone supports it, so speech stays private and works offline.
final class Listener {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()

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

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
            if state.best.isEmpty, now.timeIntervalSince(started) > 6 { break }
        }

        engine.stop()
        input.removeTap(onBus: 0)
        request.endAudio()
        task.cancel()
        return state.best.isEmpty ? nil : state.best
    }
}
