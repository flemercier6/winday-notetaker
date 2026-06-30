# Architecture

## Overview

The macOS app is a thin client. It records audio and drives the UI, but every
privileged operation (calling Deepgram, Gemini, Notion) happens in **Supabase
Edge Functions** that hold the secrets server-side. The app authenticates with
Supabase Auth and is authorized per-user by Row-Level Security.

## Data flow

```
   mic ────▶┌───────────────┐
            │ AudioRecorder │── mixed .caf ──┐
sys audio ─▶│ (SCKit+Engine)│                │
            └───────────────┘                ▼
            ┌──────────────────────────────────────────┐
            │              AppViewModel                  │
            │      (state, history, drives pipeline)     │
            └───────────────────┬────────────────────────┘
                                │ PipelineCoordinator
                                ▼
            ┌──────────────────────────────────────────┐
            │            SupabaseClient                  │
            │  auth (email OTP) · storage · functions    │
            └───────────────────┬────────────────────────┘
                  upload .caf    │   invoke by meeting_id
                                 ▼
   Supabase ┌────────────────────────────────────────────┐
            │ Storage: recordings/<userId>/<id>.caf (RLS) │
            │ Postgres: meetings, user_settings (RLS)     │
            │ Edge Functions (secrets via Deno.env):      │
            │   transcribe ─▶ Deepgram Nova-3             │
            │   summarize  ─▶ Gemini Flash                │
            │   export-notion ─▶ Notion API               │
            └────────────────────────────────────────────┘
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

2. **Upload + create row** (`PipelineCoordinator` → `SupabaseClient`)
   - Uploads the `.caf` to the private `recordings` bucket at
     `<userId>/<meetingId>.caf`.
   - Inserts a `meetings` row (RLS ensures `user_id = auth.uid()`).

3. **Transcribe** (Edge Function `transcribe`)
   - Verifies the caller's JWT, signs a short-lived URL for the audio, and calls
     `POST https://api.deepgram.com/v1/listen?model=nova-3&diarize=true&utterances=true&smart_format=true`.
   - Stores the diarized transcript on the meeting row and returns it.

4. **Summarize** (Edge Function `summarize`)
   - Calls `…/models/{model}:generateContent` with `responseMimeType:
     application/json` + a `responseSchema`, so Gemini returns exactly the
     `MeetingSummary` shape. Default `gemini-flash-latest` tracks the newest Flash.

5. **Export** (Edge Function `export-notion`)
   - `POST https://api.notion.com/v1/pages` — title from the summary headline,
     body blocks for summary / key points / prioritized to-dos. Reads the target
     database id from the user's `user_settings` row.

## Security

- **Third-party secrets** (`DEEPGRAM_API_KEY`, `GEMINI_API_KEY`, `NOTION_TOKEN`)
  live ONLY as Supabase Edge Function secrets. They are never shipped to the app
  and never committed (`supabase/.env` is gitignored).
- The app holds only the **publishable** Supabase URL + key (in `Info.plist`),
  which are safe to distribute — access is gated by Supabase Auth + RLS.
- **RLS** on `meetings`, `user_settings` and `storage.objects` scopes every row
  and file to its owner (`auth.uid()`).
- Edge Functions run with `verify_jwt = true`; they authenticate the user from
  the JWT, then use the service-role key only for signed URLs / row writes.
- The user session (access/refresh tokens) is stored in the macOS **Keychain**.

## Known trade-offs (v1)

- **Local-first history.** The UI list is a local cache (`MeetingStore`); the
  durable copy is written to Postgres by the functions. Fetching `meetings` on
  launch for cross-device sync is a small follow-up (see Roadmap).
- **Audio FIFO uses a lock.** The bridge between the SCStream callback thread and
  the real-time render thread is an `NSLock`-protected float buffer. Fine for a
  meeting recorder; a lock-free ring buffer is the production-grade choice.
- **Whole-display audio capture.** v1 captures all system audio rather than just
  the browser tab. `MeetDetector` already finds the host browser; scoping the
  `SCContentFilter` is a small follow-up.
- **App Sandbox is off.** Simplifies the first build. Re-enable + add the
  screen-capture entitlement before any Mac App Store distribution.
- **Batch (post-call) transcription.** Chosen for robustness and cost. A
  streaming path (Deepgram WebSocket) is on the roadmap.
- **Function timeouts.** Very long meetings could approach Edge Function limits;
  move to async/background processing if needed.
