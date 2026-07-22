import AVFoundation
import Foundation
import os

/// The board's voice: a tiny NES-flavoured synthesiser that turns `BoardSound`
/// events into short square/pulse/triangle motifs.
///
/// Nothing here ships as an audio file. Every cue is generated from a note
/// list at play time, which keeps the bundle free of binary blobs and makes the
/// motifs editable as code rather than as assets. A user who disagrees with the
/// taste on display can drop `<case>.wav` into `~/.andoncord/sounds` and
/// override any individual cue (see `customSamples(for:)`).
///
/// ## Design constraints
///
/// These sounds fire dozens of times an hour, all day. That pushed three rules:
/// every cue is under ~350ms, amplitudes are graded so the cues you must not
/// miss (`cordPulled`) sit well above the ones that are merely informational
/// (`sessionStart`), and repeats inside a short window are dropped rather than
/// stacked — a burst of six hook events must not turn into a chord.
public final class ChiptuneEngine {

    // MARK: - Tuning constants

    /// Fixed internal rate. The engine's main mixer resamples to whatever the
    /// hardware wants, so the synthesiser never has to care what device is
    /// attached — which is also what lets a device change be handled by simply
    /// rebuilding the graph.
    private static let sampleRate: Double = 44_100

    /// 2.5 seconds. Caps both a synthesised cue and a decoded custom sample, so
    /// every voice slot can be one fixed allocation made once at init.
    private static let maxVoiceFrames = 110_250

    /// Enough for overlapping cues without ever needing to allocate mid-flight.
    /// If all six are busy the seventh sound is dropped, which is the right
    /// failure: at that point it is noise, not information.
    private static let voiceCount = 6

    /// Repeats of the same cue inside this window collapse into one.
    private static let coalesceWindow: TimeInterval = 0.15

    private static let stateFree: Int32 = 0
    private static let stateBuilding: Int32 = 1
    private static let stateQueued: Int32 = 2
    private static let statePlaying: Int32 = 3

    // MARK: - Voice pool

    /// One pre-rendered cue waiting for, or being consumed by, the render thread.
    ///
    /// `samples` is allocated once at init and never moves, so the render block
    /// can dereference it without touching the allocator or ARC.
    private struct Voice {
        var samples: UnsafeMutablePointer<Float>
        var frameCount: Int
        var playhead: Int
        var state: Int32
    }

    /// Shared with the realtime thread. Deliberately raw memory rather than a
    /// Swift array: the render block must not retain, release, or trigger
    /// copy-on-write checks, and a captured `UnsafeMutablePointer` is a trivial
    /// value that does none of those things.
    private let voices: UnsafeMutablePointer<Voice>

    /// Guards only the `state` word of each voice — never the sample data and
    /// never the mixing loop.
    ///
    /// The producer (`queue`) takes it blocking, for a handful of instructions.
    /// The render thread only ever *tries* it: if the producer happens to hold
    /// it at that instant, the render thread declines and picks the new voice up
    /// on the next buffer, roughly 5–10ms later, which nobody can hear. That is
    /// what keeps the realtime thread free of priority inversion without needing
    /// a real lock-free queue. A raw `os_unfair_lock_t` is used in preference to
    /// `OSAllocatedUnfairLock` because the raw pointer captures into the render
    /// block as a trivial value, with no chance of ARC traffic per callback.
    private let voiceLock: os_unfair_lock_t

    // MARK: - Engine

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?

    /// Everything that touches the engine, the voice pool's producer side, and
    /// the sample-pack cache runs here. `play` therefore never blocks the main
    /// actor, including on the first call where a `.wav` may be decoded.
    private let queue = DispatchQueue(label: "app.andoncord.chiptune", qos: .userInitiated)

    private var lastPlayed: [BoardSound: DispatchTime] = [:]
    /// `nil` value caches a confirmed absence, so a miss costs one lookup rather
    /// than a stat per cue.
    private var packCache: [BoardSound: [Float]?] = [:]
    private var packDirectoryStamp: Date?

    private let stateLock = NSLock()
    private var mutedStorage = false
    private var volumeStorage: Float = 0.7

    public var isMuted: Bool {
        get { stateLock.withLock { mutedStorage } }
        set { stateLock.withLock { mutedStorage = newValue } }
    }

    /// Clamped to `0...1` on write.
    public var volume: Float {
        get { stateLock.withLock { volumeStorage } }
        set { stateLock.withLock { volumeStorage = min(max(newValue, 0), 1) } }
    }

    public init() {
        voiceLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        voiceLock.initialize(to: os_unfair_lock())

        voices = UnsafeMutablePointer<Voice>.allocate(capacity: Self.voiceCount)
        for index in 0..<Self.voiceCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxVoiceFrames)
            buffer.initialize(repeating: 0, count: Self.maxVoiceFrames)
            (voices + index).initialize(
                to: Voice(samples: buffer, frameCount: 0, playhead: 0, state: Self.stateFree)
            )
        }
    }

    deinit {
        // Order matters: the render block holds raw pointers into `voices` and
        // does not keep them alive. Stopping the engine is what guarantees no
        // callback is in flight by the time the memory goes away.
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine?.stop()

        for index in 0..<Self.voiceCount {
            voices[index].samples.deallocate()
        }
        voices.deinitialize(count: Self.voiceCount)
        voices.deallocate()
        voiceLock.deinitialize(count: 1)
        voiceLock.deallocate()
    }

    // MARK: - Public API

    public func play(_ sound: BoardSound) {
        guard !isMuted else { return }
        queue.async { [weak self] in
            guard let self, self.admit(sound) else { return }
            self.perform(sound)
        }
    }

    /// Audition a cue from Settings.
    ///
    /// Bypasses both the mute flag and the coalescing window: someone poking at
    /// a preview button wants to hear the sound they poked, including while the
    /// board is muted, and repeated pokes should not be swallowed. It also does
    /// not update the coalescing timestamps, so previewing never suppresses a
    /// real event that lands a moment later.
    public func preview(_ sound: BoardSound) {
        queue.async { [weak self] in self?.perform(sound) }
    }

    /// Stops the engine and hands the audio device back.
    ///
    /// The voice pool survives — a later `play` lazily rebuilds the graph — so
    /// this is safe to call when the board goes idle, not only at quit.
    public func shutdown() {
        queue.sync {
            self.teardownEngine()
            self.resetVoices()
        }
    }

    // MARK: - Producer side

    /// Drops a repeat of the same cue inside `coalesceWindow`.
    private func admit(_ sound: BoardSound) -> Bool {
        let now = DispatchTime.now()
        if let previous = lastPlayed[sound] {
            let elapsed = Double(now.uptimeNanoseconds &- previous.uptimeNanoseconds) / 1_000_000_000
            guard elapsed >= Self.coalesceWindow else { return false }
        }
        lastPlayed[sound] = now
        return true
    }

    private func perform(_ sound: BoardSound) {
        ensureEngineRunning()
        guard engine?.isRunning == true else { return }

        let gain = volume
        guard gain > 0 else { return }

        if let custom = customSamples(for: sound) {
            enqueue { destination in
                let count = min(custom.count, Self.maxVoiceFrames)
                custom.withUnsafeBufferPointer { source in
                    for index in 0..<count { destination[index] = source[index] * gain }
                }
                Self.applyEdgeFades(destination, frames: count)
                return count
            }
        } else {
            enqueue { destination in
                Self.render(Self.score(for: sound), gain: gain, into: destination)
            }
        }
    }

    /// Claims a voice slot, lets `build` fill it, then publishes it.
    ///
    /// The slot is marked `building` while `build` runs so the render thread
    /// cannot observe a half-written buffer; the lock release at the end of the
    /// claim and the lock acquisition at publish give the render thread's own
    /// acquire the happens-before edge it needs to see the samples.
    private func enqueue(_ build: (UnsafeMutablePointer<Float>) -> Int) {
        var slot = -1
        os_unfair_lock_lock(voiceLock)
        for index in 0..<Self.voiceCount where voices[index].state == Self.stateFree {
            slot = index
            voices[index].state = Self.stateBuilding
            break
        }
        os_unfair_lock_unlock(voiceLock)

        guard slot >= 0 else {
            Log.ui.debug("chiptune: all voices busy, dropping cue")
            return
        }

        let frames = build(voices[slot].samples)

        os_unfair_lock_lock(voiceLock)
        voices[slot].frameCount = frames
        voices[slot].playhead = 0
        voices[slot].state = frames > 0 ? Self.stateQueued : Self.stateFree
        os_unfair_lock_unlock(voiceLock)
    }

    private func resetVoices() {
        os_unfair_lock_lock(voiceLock)
        for index in 0..<Self.voiceCount {
            voices[index].state = Self.stateFree
            voices[index].playhead = 0
            voices[index].frameCount = 0
        }
        os_unfair_lock_unlock(voiceLock)
    }

    // MARK: - Realtime side

    /// Builds the render callback.
    ///
    /// Everything the block touches is captured by value as a trivial type —
    /// two pointers and four integers. There are no allocations, no Swift
    /// runtime calls that could take a lock, no `Array`, no `Dictionary`, and no
    /// blocking wait. The only synchronisation is a `trylock` that is allowed to
    /// fail.
    private func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        let voices = self.voices
        let lock = self.voiceLock
        let slotCount = Self.voiceCount
        let freeState = Self.stateFree
        let queuedState = Self.stateQueued
        let playingState = Self.statePlaying

        return { isSilence, _, frameCount, audioBufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for bufferIndex in 0..<buffers.count {
                if let data = buffers[bufferIndex].mData {
                    memset(data, 0, Int(buffers[bufferIndex].mDataByteSize))
                }
            }

            if os_unfair_lock_trylock(lock) {
                for index in 0..<slotCount {
                    let voice = voices + index
                    if voice.pointee.state == queuedState {
                        voice.pointee.playhead = 0
                        voice.pointee.state = playingState
                    } else if voice.pointee.state == playingState,
                              voice.pointee.playhead >= voice.pointee.frameCount {
                        voice.pointee.state = freeState
                    }
                }
                os_unfair_lock_unlock(lock)
            }

            var rendered = false
            for index in 0..<slotCount {
                let voice = voices + index
                guard voice.pointee.state == playingState else { continue }
                let head = voice.pointee.playhead
                let available = voice.pointee.frameCount - head
                guard available > 0 else { continue }

                let count = min(frames, available)
                let source = voice.pointee.samples + head
                for bufferIndex in 0..<buffers.count {
                    guard let raw = buffers[bufferIndex].mData else { continue }
                    let destination = raw.assumingMemoryBound(to: Float.self)
                    for frame in 0..<count { destination[frame] += source[frame] }
                }
                voice.pointee.playhead = head + count
                rendered = true
            }

            // Six simultaneous cues can sum past full scale. Hard-clipping a
            // chiptune blip is inaudible; letting it wrap in the output unit is
            // not.
            if rendered {
                for bufferIndex in 0..<buffers.count {
                    guard let raw = buffers[bufferIndex].mData else { continue }
                    let destination = raw.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        destination[frame] = min(max(destination[frame], -1), 1)
                    }
                }
            }

            isSilence.pointee = ObjCBool(!rendered)
            return noErr
        }
    }

    // MARK: - Engine lifecycle

    private func ensureEngineRunning() {
        if engine == nil { buildEngine() }
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            Log.ui.error("chiptune: engine failed to start: \(error.localizedDescription, privacy: .public)")
            teardownEngine()
        }
    }

    private func buildEngine() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else {
            Log.ui.error("chiptune: could not create render format")
            return
        }

        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format, renderBlock: makeRenderBlock())
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        // Scoped to this engine instance so a rebuild does not leave a stale
        // observer firing against a detached graph.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.handleConfigurationChange() }
        }

        self.engine = engine
        self.sourceNode = source
    }

    /// Headphones unplugged, a display with speakers disconnected, an output
    /// device switched in Sound preferences: the engine stops itself and its
    /// node connections are no longer valid against the new hardware format.
    /// Rebuilding from scratch is cheaper to reason about than patching the
    /// existing graph, and the cost is paid once per device change.
    private func handleConfigurationChange() {
        Log.ui.notice("chiptune: audio configuration changed, rebuilding engine")
        teardownEngine()
        // Voices mid-flight are abandoned. Half a blip is not worth carrying
        // across a device switch, and resuming one would click.
        resetVoices()
        ensureEngineRunning()
    }

    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.stop()
            if let sourceNode { engine.detach(sourceNode) }
        }
        engine = nil
        sourceNode = nil
    }

    // MARK: - Custom sound packs

    /// Returns decoded samples for `~/.andoncord/sounds/<case>.wav` (or `.mp3`)
    /// if the user has supplied one.
    ///
    /// Results are cached, including negative ones. The directory's modification
    /// date is checked on each call so dropping a file in takes effect without
    /// relaunching the app — one `stat` per cue, off the main thread.
    private func customSamples(for sound: BoardSound) -> [Float]? {
        let stamp = try? Paths.sounds.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if stamp != packDirectoryStamp {
            packDirectoryStamp = stamp
            packCache.removeAll(keepingCapacity: true)
        }

        if let cached = packCache[sound] { return cached }

        var decoded: [Float]?
        for ext in ["wav", "mp3"] {
            let url = Paths.sounds.appendingPathComponent(sound.rawValue).appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                decoded = try Self.decode(url)
            } catch {
                Log.ui.error("chiptune: could not decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            break
        }

        packCache[sound] = .some(decoded)
        return decoded
    }

    /// Decodes any format Core Audio understands down to mono float at the
    /// synthesiser's rate, so a custom pack flows through the same voice pool as
    /// a generated cue instead of needing a second playback path.
    private static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(maxVoiceFrames)
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var exhausted = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !exhausted,
                  let input = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: 8_192
                  ) else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input)
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                exhausted = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if status == .error, let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: - Synthesis

    private enum Waveform {
        /// `duty` below 0.5 thins the wave and pushes energy into the upper
        /// harmonics — the classic NES trick for making one voice cut through
        /// the others without simply being louder.
        case pulse(duty: Double)
        case triangle

        static let square = Waveform.pulse(duty: 0.5)

        /// Anti-aliasing: pulse waves get PolyBLEP correction at both edges,
        /// which cancels the worst of the aliased partials for a couple of
        /// multiply-adds per sample. Triangle is left naive on purpose — its
        /// harmonics fall off as 1/n², so the reflected energy at these
        /// fundamentals sits far below the noise floor. Combined with a top
        /// fundamental of ~1.3kHz, that is enough; a full band-limited table
        /// would be a lot of machinery for blips this short.
        func value(phase: Double, increment: Double) -> Double {
            switch self {
            case .pulse(let duty):
                var value = phase < duty ? 1.0 : -1.0
                value += polyBLEP(phase, increment)
                var falling = phase - duty
                if falling < 0 { falling += 1 }
                value -= polyBLEP(falling, increment)
                return value
            case .triangle:
                return 2.0 * abs(2.0 * phase - 1.0) - 1.0
            }
        }

        private func polyBLEP(_ t: Double, _ dt: Double) -> Double {
            guard dt > 0 else { return 0 }
            if t < dt {
                let x = t / dt
                return x + x - x * x - 1.0
            }
            if t > 1.0 - dt {
                let x = (t - 1.0) / dt
                return x * x + x + x + 1.0
            }
            return 0
        }
    }

    /// A square wave switched on at full amplitude produces a step, and a step
    /// is a click — audibly worse than the note itself. Every note therefore
    /// ramps in over `attack`, falls to `sustain` over `decay`, and ramps back
    /// to silence over `release`, so the waveform always starts and ends at zero.
    private struct Envelope {
        var attack: Double = 0.004
        var decay: Double = 0.045
        var sustain: Float = 0.55
        var release: Double = 0.025

        /// Fast, hard, and held — for cues that must be noticed.
        static let punchy = Envelope(attack: 0.002, decay: 0.030, sustain: 0.90, release: 0.015)
        /// Slow in, quick to fade — for cues that must not startle.
        static let gentle = Envelope(attack: 0.008, decay: 0.060, sustain: 0.45, release: 0.030)
        /// Holds its level so a low buzz reads as a buzz rather than a pluck.
        static let sustained = Envelope(attack: 0.008, decay: 0.050, sustain: 0.80, release: 0.040)
    }

    private struct Note {
        var waveform: Waveform
        var frequency: Double
        var endFrequency: Double?
        var duration: Double
        var amplitude: Float
        var envelope: Envelope

        init(
            _ waveform: Waveform,
            _ frequency: Double,
            _ duration: Double,
            _ amplitude: Float,
            slideTo endFrequency: Double? = nil,
            envelope: Envelope = Envelope()
        ) {
            self.waveform = waveform
            self.frequency = frequency
            self.endFrequency = endFrequency
            self.duration = duration
            self.amplitude = amplitude
            self.envelope = envelope
        }

        static func rest(_ duration: Double) -> Note {
            Note(.triangle, 0, duration, 0)
        }
    }

    /// Equal-tempered frequencies, spelled out rather than computed so the
    /// motifs below read as music.
    private enum Pitch {
        static let f4Sharp = 369.99
        static let a4 = 440.00
        static let c5 = 523.25
        static let e5 = 659.25
        static let g5 = 783.99
        static let a5 = 880.00
        static let b5 = 987.77
        static let c6 = 1046.50
        static let d6 = 1174.66
        static let e6 = 1318.51
    }

    /// The motifs.
    ///
    /// Everything except `denied` sits in C major so the cues sound like one
    /// instrument rather than eight unrelated beeps; `denied` borrows an F♯ to
    /// land slightly outside that set, which is what makes it read as a "no"
    /// without needing to be loud or harsh.
    private static func score(for sound: BoardSound) -> [Note] {
        switch sound {
        case .cordPulled:
            // The alarm. A rising fifth stated twice — the interval and the
            // repetition are both things ears treat as "this is addressed to
            // you". Thin 25% pulse so it cuts through music and a fan rather
            // than competing on volume alone.
            return [
                Note(.pulse(duty: 0.25), Pitch.a5, 0.070, 0.90, envelope: .punchy),
                Note(.pulse(duty: 0.25), Pitch.e6, 0.070, 0.90, envelope: .punchy),
                .rest(0.030),
                Note(.pulse(duty: 0.25), Pitch.a5, 0.070, 0.90, envelope: .punchy),
                Note(.pulse(duty: 0.25), Pitch.e6, 0.110, 0.90, envelope: .punchy),
            ]

        case .question:
            // Rising fourth, and the second note itself slides up a tone: the
            // same terminal rise that turns a spoken sentence into a question.
            // Plain square and two-thirds the amplitude keeps it clearly below
            // cordPulled.
            return [
                Note(.square, Pitch.e5, 0.090, 0.45),
                Note(.square, Pitch.a5, 0.150, 0.45, slideTo: Pitch.b5),
            ]

        case .planReview:
            // Three notes, the last one leaping a fifth and held: a phrase that
            // opens rather than resolves, which is the point — something is
            // waiting, but nothing is on fire. Triangle keeps it soft.
            return [
                Note(.triangle, Pitch.e5, 0.080, 0.42),
                Note(.triangle, Pitch.g5, 0.080, 0.42),
                Note(.triangle, Pitch.d6, 0.150, 0.42),
            ]

        case .cleared:
            // Fourth up onto the tonic: the shortest gesture that sounds
            // finished.
            return [
                Note(.square, Pitch.g5, 0.060, 0.50),
                Note(.square, Pitch.c6, 0.110, 0.50),
            ]

        case .denied:
            // Falling minor third, triangle, soft attack. Negative by contour
            // instead of by timbre, so it never feels like a scolding.
            return [
                Note(.triangle, Pitch.a4, 0.070, 0.40, envelope: .gentle),
                Note(.triangle, Pitch.f4Sharp, 0.140, 0.40, envelope: .gentle),
            ]

        case .done:
            // Major triad up to the octave. Pleasant, unremarkable, forgettable
            // — which is what you want from the cue that fires most often after
            // sessionStart.
            return [
                Note(.triangle, Pitch.c5, 0.055, 0.38),
                Note(.triangle, Pitch.e5, 0.055, 0.38),
                Note(.triangle, Pitch.g5, 0.055, 0.38),
                Note(.triangle, Pitch.c6, 0.090, 0.38),
            ]

        case .failed:
            // Two octaves below the alert, sliding down and losing pitch: the
            // "power cut" sound. Unmistakably bad news, but low frequencies do
            // not trigger the startle response that a high alarm does.
            return [
                Note(.square, 220.00, 0.180, 0.45, slideTo: 130.81, envelope: .sustained),
                Note(.square, 110.00, 0.130, 0.35, envelope: .sustained),
            ]

        case .sessionStart:
            // One short triangle tick at a seventh of the alert's amplitude.
            // Sessions appear constantly; this should register as texture, not
            // as an event.
            return [Note(.triangle, Pitch.c6, 0.045, 0.13, envelope: .gentle)]
        }
    }

    /// Renders a note list into `destination` and returns the frame count.
    ///
    /// Notes are laid end to end rather than overlapped. Each one has already
    /// released to silence by its final frame, so butting them together cannot
    /// produce a discontinuity, and the arithmetic stays trivial.
    private static func render(
        _ notes: [Note],
        gain: Float,
        into destination: UnsafeMutablePointer<Float>
    ) -> Int {
        var cursor = 0
        for note in notes {
            let frames = min(Int(note.duration * sampleRate), maxVoiceFrames - cursor)
            guard frames > 0 else { break }
            if note.frequency > 0 && note.amplitude > 0 {
                renderNote(note, frames: frames, gain: gain, into: destination + cursor)
            } else {
                // Slot buffers are reused, so a rest has to write silence rather
                // than skip.
                (destination + cursor).update(repeating: 0, count: frames)
            }
            cursor += frames
        }
        applyEdgeFades(destination, frames: cursor)
        return cursor
    }

    private static func renderNote(
        _ note: Note,
        frames: Int,
        gain: Float,
        into destination: UnsafeMutablePointer<Float>
    ) {
        let envelope = note.envelope
        let attackFrames = max(1, min(Int(envelope.attack * sampleRate), frames / 4))
        let releaseFrames = max(1, min(Int(envelope.release * sampleRate), frames / 2))
        let decayFrames = max(1, Int(envelope.decay * sampleRate))
        let endFrequency = note.endFrequency ?? note.frequency

        var phase = 0.0
        for index in 0..<frames {
            let progress = Double(index) / Double(frames)
            let frequency = note.frequency + (endFrequency - note.frequency) * progress
            let increment = frequency / sampleRate

            var level: Float
            if index < attackFrames {
                level = Float(index) / Float(attackFrames)
            } else {
                let decayProgress = Float(index - attackFrames) / Float(decayFrames)
                level = envelope.sustain + (1 - envelope.sustain) * max(0, 1 - decayProgress)
            }
            let remaining = frames - index
            if remaining < releaseFrames {
                level *= Float(remaining) / Float(releaseFrames)
            }

            destination[index] =
                Float(note.waveform.value(phase: phase, increment: increment))
                * level * note.amplitude * gain

            phase += increment
            if phase >= 1 { phase -= 1 }
        }
    }

    /// A ~2ms taper across the whole cue.
    ///
    /// Per-note envelopes already handle the musical shaping; this is insurance
    /// for the two cases they do not cover — a custom `.wav` that starts on a
    /// non-zero sample, and one truncated by `maxVoiceFrames`.
    private static func applyEdgeFades(_ destination: UnsafeMutablePointer<Float>, frames: Int) {
        let fade = min(96, frames / 2)
        guard fade > 0 else { return }
        for index in 0..<fade {
            let scale = Float(index) / Float(fade)
            destination[index] *= scale
            destination[frames - 1 - index] *= scale
        }
    }
}
