# Architecture

## Data flow

```
                ┌──────────────────────────────────────────────┐
                │                AppViewModel                   │
                │   (state, history, drives the pipeline)       │
                └───────┬───────────────────────────────┬──────┘
                        │ start/stop                     │ process
                        ▼                                ▼
                ┌───────────────┐              ┌────────────────────┐
   mic  ───────▶│ AudioRecorder │── .caf ─────▶│ PipelineCoordinator│
 system audio ─▶│ (SCKit+Engine)│   file       └─────────┬──────────┘
                └───────────────┘                        │
                                                         ▼
                                   ┌───────────┐   ┌───────────┐   ┌────────────┐
                                   │ Deepgram  │──▶│  Gemini   │──▶│   Notion   │
                                   │  Nova-3   │   │  Flash    │   │  page      │
                                   └───────────┘   └───────────┘   └────────────┘
                                     Transcript      MeetingSummary   notionPageURL
```

## Stages

1. **Record** (`AudioRecorder`)
   - `ScreenCaptureKit` `SCStream` captures system audio (remote participants).
     Each `CMSampleBuffer` is converted to PCM and pushed into a thread-safe
     `SampleFIFO`.
   - `AVAudioEngine` taps the **microphone** (`inputNode`) and an
     `AVAudioSourceNode` pulls system-audio samples from the FIFO. Both are
     summed by `mainMixerNode`.
   - A tap on `mainMixerNode` writes the mixed stream to a `.caf` file.

2. **Transcribe** (`DeepgramService`)
   - `POST https://api.deepgram.com/v1/listen?model=nova-3&diarize=true&utterances=true&smart_format=true`
   - Returns a diarized `Transcript` (per-speaker utterances).

3. **Summarize** (`GeminiService`)
   - `POST …/models/{model}:generateContent` with `responseMimeType:
     application/json` + a `responseSchema`, so the model returns exactly the
     `MeetingSummary` shape (headline, summary, key_points, next_steps).
   - Default model `gemini-flash-latest` always tracks the newest Flash.

4. **Export** (`NotionService`)
   - `POST https://api.notion.com/v1/pages` — title from the summary headline,
     body blocks for summary / key points / prioritized to-dos.

## Known trade-offs (v1)

- **Audio FIFO uses a lock.** The bridge between the SCStream callback thread
  and the real-time render thread is an `NSLock`-protected float buffer. It's
  simple and fine for a meeting recorder, but a lock-free ring buffer is the
  production-grade choice. See `AudioRecorder.SampleFIFO`.
- **Whole-display audio capture.** v1 captures all system audio rather than just
  the browser tab. `MeetDetector` already finds the host browser; scoping the
  `SCContentFilter` to that app is a small follow-up.
- **App Sandbox is off.** Simplifies the first build. Re-enable + add the
  screen-capture entitlement before any Mac App Store distribution.
- **Batch (post-call) transcription.** Chosen for robustness and cost. A
  streaming path (Deepgram WebSocket) is on the roadmap.

## Security

- API keys live in the **Keychain** (`Support/Keychain.swift`), entered via the
  Settings UI. Nothing secret is committed; `Config.xcconfig` holds only model
  names and the Notion API version.
