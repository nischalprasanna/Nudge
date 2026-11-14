import AVFoundation
import os

/// Short guidance beeps in stereo.
///
/// - Left/right position of the beep = which way to move horizontally.
/// - Pitch = which way to move vertically (higher means move up).
/// - Beep rate = distance (faster means closer).
/// Beeps are short so they sit on top of real-world sound without masking it.
final class ToneEngine {
    enum Mode { case silent, seeking, onTarget }

    struct Note {
        var frequency: Float
        var seconds: Float
    }

    private struct Parameters {
        var mode: Mode = .silent
        var frequency: Float = 660
        var pan: Float = 0
        var interval: Float = 0.5
        var oneShot: [Note] = []
        var oneShotToken = 0
    }

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 44_100
    private let lock = OSAllocatedUnfairLock(initialState: Parameters())
    private var source: AVAudioSourceNode?

    /// When false, no beeps or chimes are produced (audio channel switched off).
    var isEnabled = true {
        didSet { if !isEnabled { silence() } }
    }

    // Render-thread state.
    private var phase: Float = 0
    private var positionInPeriod = 0
    private var playingToken = 0
    private var playingNotes: [Note] = []
    private var noteIndex = 0
    private var notePosition = 0

    func start() {
        guard source == nil else {
            if !engine.isRunning { try? engine.start() }
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.8
        try? engine.start()
    }

    func stop() {
        silence()
        engine.stop()
    }

    func silence() {
        lock.withLock { $0.mode = .silent }
    }

    /// Guidance beeps. `pan` is -1 (left) to 1 (right); `rise` is -1 (move down) to 1 (move up);
    /// `closeness` is 0 (far) to 1 (nearly there).
    func seek(pan: Float, rise: Float, closeness: Float) {
        guard isEnabled else { return }
        let frequency = 660 * powf(2, max(-1, min(1, rise)))
        let interval = 0.6 - 0.48 * max(0, min(1, closeness))
        lock.withLock {
            $0.mode = .seeking
            $0.pan = max(-1, min(1, pan))
            $0.frequency = frequency
            $0.interval = interval
        }
    }

    /// Rapid high beeps: the finger is on the target.
    func onTarget() {
        guard isEnabled else { return }
        lock.withLock { $0.mode = .onTarget }
    }

    /// Plays a short tune once, then returns to whatever mode is set.
    func play(_ notes: [Note]) {
        guard isEnabled else { return }
        lock.withLock {
            $0.oneShot = notes
            $0.oneShotToken += 1
        }
    }

    // Ready-made earcons.
    func playListening() { play([Note(frequency: 880, seconds: 0.08), Note(frequency: 1175, seconds: 0.1)]) }
    func playSuccess() { play([Note(frequency: 784, seconds: 0.1), Note(frequency: 988, seconds: 0.1), Note(frequency: 1319, seconds: 0.18)]) }
    func playError() { play([Note(frequency: 330, seconds: 0.18), Note(frequency: 247, seconds: 0.28)]) }

    private func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let parameters = lock.withLock { $0 }
        if parameters.oneShotToken != playingToken {
            playingToken = parameters.oneShotToken
            playingNotes = parameters.oneShot
            noteIndex = 0
            notePosition = 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        let rate = Float(sampleRate)
        let twoPi = 2 * Float.pi
        for frame in 0..<frameCount {
            var sample: Float = 0
            var pan: Float = 0

            if noteIndex < playingNotes.count {
                // One-shot tune, centred.
                let note = playingNotes[noteIndex]
                let length = max(1, Int(note.seconds * rate))
                let envelope = sinf(Float.pi * Float(notePosition) / Float(length))
                sample = sinf(phase) * envelope * 0.5
                phase += twoPi * note.frequency / rate
                notePosition += 1
                if notePosition >= length {
                    notePosition = 0
                    noteIndex += 1
                }
            } else {
                let frequency: Float
                let interval: Float
                let beepSeconds: Float
                switch parameters.mode {
                case .silent:
                    frequency = 0; interval = 0; beepSeconds = 0
                case .seeking:
                    frequency = parameters.frequency; interval = parameters.interval; beepSeconds = 0.07
                    pan = parameters.pan
                case .onTarget:
                    frequency = 1320; interval = 0.1; beepSeconds = 0.05
                }
                if interval > 0 {
                    let period = max(1, Int(interval * rate))
                    let beep = max(1, Int(beepSeconds * rate))
                    if positionInPeriod < beep {
                        let envelope = sinf(Float.pi * Float(positionInPeriod) / Float(beep))
                        sample = sinf(phase) * envelope * 0.5
                        phase += twoPi * frequency / rate
                    }
                    positionInPeriod += 1
                    if positionInPeriod >= period { positionInPeriod = 0 }
                } else {
                    positionInPeriod = 0
                }
            }
            if phase > twoPi { phase -= twoPi }

            // Equal-power pan.
            let angle = (pan + 1) * Float.pi / 4
            left[frame] = sample * cosf(angle)
            right[frame] = sample * sinf(angle)
        }
    }
}
