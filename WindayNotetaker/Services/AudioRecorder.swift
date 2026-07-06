import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// Records a meeting into a single 16-bit PCM WAV by mixing two sources:
///   1. Your microphone (your side) — a direct tap on `AVAudioEngine.inputNode`.
///   2. System audio (remote participants) — captured via ScreenCaptureKit and
///      summed into the mic stream in software.
///
/// The microphone tap is the master clock: for every mic buffer we pull the
/// matching amount of system audio from a FIFO and sum them. Nothing is routed
/// to the speakers, so there is no monitoring/echo, and the input node is the
/// canonical (reliable) way to capture the mic.
///
/// Requires macOS 13+ (ScreenCaptureKit audio) and Screen Recording +
/// Microphone permissions.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum RecorderError: LocalizedError {
        case noDisplay
        case micDenied
        case noMicInput
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available to capture system audio from."
            case .micDenied: return "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            case .noMicInput: return "No microphone input device was found."
            case let .engineFailed(m): return "Audio engine failed to start: \(m)"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0   // 0...1 rough input level for the UI

    /// When set, capture only this window's app audio (the Google Meet tab's
    /// browser) instead of the whole display. Set before calling `start`.
    var targetWindowID: CGWindowID?

    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var mixer: FileMixer?

    /// Canonical mixing format: 48 kHz stereo float. `nonisolated` so the
    /// SCStream callback (a background queue) can read it.
    private nonisolated let mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// System-audio samples (48 kHz stereo, interleaved) awaiting the mic tap.
    /// `nonisolated` so the SCStream callback can enqueue into it.
    private nonisolated let systemAudioFIFO = SampleFIFO()

    /// Starts recording to `url` (a `.wav` file). Throws if capture can't start.
    func start(to url: URL) async throws {
        guard !isRecording else { return }

        // macOS only feeds live microphone audio once the user has authorized
        // it. Without this the input node silently yields zeros (silent file).
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw RecorderError.micDenied }

        systemAudioFIFO.reset()
        try await startSystemAudioCapture()
        try startEngine(writingTo: url)

        isRecording = true
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        level = 0

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        mixer?.close()
        mixer = nil

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        systemAudioFIFO.reset()
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)

        // Prefer capturing just the meeting window's app audio; fall back to the
        // whole display if we don't have a specific target.
        let filter: SCContentFilter
        if let targetWindowID,
           let window = content.windows.first(where: { $0.windowID == targetWindowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = content.displays.first {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            throw RecorderError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't record our own sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        // A tiny video stream is still required alongside audio on macOS 13;
        // we register the output but ignore the frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - Microphone tap (master clock) → mixed WAV

    private func startEngine(writingTo url: URL) throws {
        // Fresh engine each time, created AFTER microphone access is granted so
        // its input unit initializes with mic access.
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw RecorderError.noMicInput
        }

        let mixer = try FileMixer(url: url, micFormat: micFormat, mixFormat: mixFormat, fifo: systemAudioFIFO)
        mixer.onLevel = { [weak self] peak in
            Task { @MainActor in self?.level = peak }
        }
        self.mixer = mixer

        // Tap the mic directly. Nothing is connected to the engine's output, so
        // there is no playback (no echo). This block runs on a background thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            mixer.writeMic(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension AudioRecorder: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.toPCMBuffer(format: mixFormat) else { return }
        systemAudioFIFO.enqueue(pcm)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.isRecording = false }
    }
}

// MARK: - File mixer (runs on the mic tap thread)

/// Owns the output file and the mic converter. For each microphone buffer it
/// converts the mic to 48 kHz mono, pulls the matching system audio from the
/// FIFO, and writes a STEREO frame where the left channel is your mic and the
/// right channel is the meeting audio. Keeping the two on separate channels lets
/// Deepgram (multichannel) attribute "You" vs "the others" with certainty, while
/// diarization still splits multiple remote participants on the right channel.
/// Lives off the main actor because the mic tap calls it on a real-time thread.
private final class FileMixer: @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?

    private let file: AVAudioFile
    private let stereoFormat: AVAudioFormat
    private let monoFormat: AVAudioFormat
    private let micToMono: AVAudioConverter?
    private let fifo: SampleFIFO
    private let lock = NSLock()
    private var closed = false

    init(url: URL, micFormat: AVAudioFormat, mixFormat: AVAudioFormat, fifo: SampleFIFO) throws {
        self.fifo = fifo
        self.stereoFormat = mixFormat
        let mono = AVAudioFormat(standardFormatWithSampleRate: mixFormat.sampleRate, channels: 1)!
        self.monoFormat = mono
        self.micToMono = micFormat == mono ? nil : AVAudioConverter(from: micFormat, to: mono)

        // Stereo 16-bit WAV: left = your mic, right = the meeting audio.
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: mixFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: wavSettings)
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    func writeMic(_ micBuffer: AVAudioPCMBuffer) {
        // 1) Mic → 48 kHz mono.
        let mono: AVAudioPCMBuffer
        if let micToMono {
            let ratio = monoFormat.sampleRate / micBuffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(micBuffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            micToMono.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return micBuffer
            }
            if error != nil { return }
            mono = out
        } else {
            mono = micBuffer
        }

        let frames = Int(mono.frameLength)
        guard frames > 0, let micData = mono.floatChannelData?[0] else { return }

        // 2) Pull matching system audio (interleaved stereo) and downmix to mono.
        var sys = [Float](repeating: 0, count: frames * 2)
        fifo.dequeue(into: &sys, frames: frames)

        // 3) Compose the stereo output: L = you (mic), R = the meeting.
        guard let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let left = stereo.floatChannelData?[0],
              stereo.format.channelCount > 1,
              let right = stereo.floatChannelData?[1] else { return }
        stereo.frameLength = AVAudioFrameCount(frames)

        var peak: Float = 0
        for i in 0..<frames {
            let you = max(-1, min(1, micData[i]))
            let them = max(-1, min(1, 0.5 * (sys[i * 2] + sys[i * 2 + 1])))
            left[i] = you
            right[i] = them
            let a = max(abs(you), abs(them))
            if a > peak { peak = a }
        }

        // 4) Write one buffer to disk.
        lock.lock()
        let isClosed = closed
        if !isClosed { try? file.write(from: stereo) }
        lock.unlock()

        if !isClosed { onLevel?(peak) }
    }
}

// MARK: - Thread-safe sample FIFO

/// Lock-protected interleaved-stereo float FIFO bridging the SCStream callback
/// thread and the mic tap thread. Simple by design (a lock-free ring buffer
/// would be the production-grade choice).
private final class SampleFIFO: @unchecked Sendable {
    private var buffer: [Float] = []
    private let lock = NSLock()
    private let channels = 2

    func enqueue(_ pcm: AVAudioPCMBuffer) {
        guard let channelData = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        let srcChannels = Int(pcm.format.channelCount)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for ch in 0..<channels {
                interleaved[frame * channels + ch] = channelData[min(ch, srcChannels - 1)][frame]
            }
        }
        lock.lock()
        buffer.append(contentsOf: interleaved)
        // Cap latency: never let the FIFO grow past ~3 seconds.
        let maxSamples = 48_000 * channels * 3
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        lock.unlock()
    }

    /// Pops `frames` stereo frames (interleaved) into `out`, zero-filling if the
    /// FIFO is short (e.g. no system audio playing).
    func dequeue(into out: inout [Float], frames: Int) {
        let needed = frames * channels
        lock.lock()
        let available = min(needed, buffer.count)
        for i in 0..<available { out[i] = buffer[i] }
        if available < needed {
            for i in available..<needed { out[i] = 0 }
        }
        if available > 0 { buffer.removeFirst(available) }
        lock.unlock()
    }

    func reset() {
        lock.lock(); buffer.removeAll(keepingCapacity: false); lock.unlock()
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    /// Converts a system-audio sample buffer into a PCM buffer in `format`.
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let sourceFormat = AVAudioFormat(streamDescription: asbd) ?? format
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)

        if sourceFormat == format { return pcm }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return pcm
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        return error == nil ? out : pcm
    }
}
