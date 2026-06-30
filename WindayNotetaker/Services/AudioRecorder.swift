import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// Records a meeting by mixing two sources into one file:
///   1. System audio (the remote participants you hear) via ScreenCaptureKit.
///   2. Your microphone (your side of the call) via AVAudioEngine.
///
/// The two streams are summed by an `AVAudioEngine` graph and written to a
/// single `.caf` file, ready to upload to Deepgram.
///
/// Requires macOS 13+ (ScreenCaptureKit audio capture) and Screen Recording +
/// Microphone permissions (granted by the user on first run).
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum RecorderError: LocalizedError {
        case noDisplay
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available to capture system audio from."
            case let .engineFailed(m): return "Audio engine failed to start: \(m)"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0   // 0...1 rough input level for the UI

    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var outputFile: AVAudioFile?

    /// Canonical mixing format: 48 kHz stereo float, matches SCStream output.
    private let mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Thread-safe FIFO holding system-audio samples awaiting the render block.
    private let systemAudioFIFO = SampleFIFO()
    private var converter: AVAudioConverter?

    /// Starts recording to `url` (a `.caf` file). Throws if capture can't start.
    func start(to url: URL) async throws {
        guard !isRecording else { return }

        try await startSystemAudioCapture()
        try startEngine(writingTo: url)

        isRecording = true
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        level = 0

        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        sourceNode = nil

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
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        // Capture audio for the whole display (includes the Google Meet tab).
        // To capture a single app instead, build the filter from that app's
        // SCRunningApplication — see MeetDetector.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

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

    // MARK: - Engine graph (mic + system → file)

    private func startEngine(writingTo url: URL) throws {
        let input = engine.inputNode
        let micFormat = input.inputFormat(forBus: 0)

        // Source node feeds buffered system-audio samples into the mixer.
        let source = AVAudioSourceNode(format: mixFormat) { [systemAudioFIFO] _, _, frameCount, audioBufferList -> OSStatus in
            systemAudioFIFO.render(into: audioBufferList, frameCount: frameCount)
            return noErr
        }
        self.sourceNode = source

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mixFormat)
        engine.connect(input, to: engine.mainMixerNode, format: micFormat)

        let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: outFormat.settings)
        self.outputFile = file

        // Tap the summed mix and write it to disk.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: outFormat) { [weak self] buffer, _ in
            try? self?.outputFile?.write(from: buffer)
            self?.updateLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    private nonisolated func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(data[i])) }
        Task { @MainActor in self.level = peak }
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
        Task { @MainActor in
            self.isRecording = false
        }
    }
}

// MARK: - Thread-safe sample FIFO

/// A simple lock-protected float FIFO bridging the SCStream callback thread and
/// the real-time render thread. Stores interleaved stereo float samples.
///
/// Note: a lock-free ring buffer would be preferable for production audio; this
/// is intentionally simple and good enough for a meeting recorder. The lock is
/// only held for fast memcpy-style copies.
private final class SampleFIFO {
    private var buffer: [Float] = []
    private let lock = NSLock()
    private let channels = 2

    func enqueue(_ pcm: AVAudioPCMBuffer) {
        guard let channelData = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for ch in 0..<channels {
                let src = channelData[min(ch, Int(pcm.format.channelCount) - 1)]
                interleaved[frame * channels + ch] = src[frame]
            }
        }
        lock.lock()
        buffer.append(contentsOf: interleaved)
        // Cap latency: never let the FIFO grow past ~2 seconds.
        let maxSamples = 48_000 * channels * 2
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        lock.unlock()
    }

    func render(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
        let needed = Int(frameCount) * channels
        lock.lock()
        let available = min(needed, buffer.count)
        let samples = Array(buffer.prefix(available))
        if available > 0 { buffer.removeFirst(available) }
        lock.unlock()

        let bufferList = UnsafeMutableAudioBufferListPointer(abl)
        for (bufferIndex, audioBuffer) in bufferList.enumerated() {
            guard let dst = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(frameCount)
            for frame in 0..<frames {
                let idx = frame * channels + min(bufferIndex, channels - 1)
                dst[frame] = idx < samples.count ? samples[idx] : 0
            }
        }
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

        // If the source already matches the mix format, return as-is.
        if sourceFormat == format { return pcm }

        // Otherwise convert (sample-rate / layout) into the canonical format.
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
