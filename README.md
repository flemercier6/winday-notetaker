# Winday Notetaker

A native **macOS** app that records your **Google Meet** calls, transcribes them
with **Deepgram (Nova-3)**, summarizes them with **Gemini (Flash)**, and pushes
the summary, next steps and priorities to **Notion**.

Companion app to **Winday CRM**.

> Status: **v1 scaffold.** All the architecture and service integrations are in
> place. Build it in Xcode on your Mac, drop in your API keys, and iterate.

---

## What it does

1. **Record** — captures the meeting audio by mixing two sources into one file:
   - the **system audio** you hear (remote participants) via `ScreenCaptureKit`
   - your **microphone** (your side) via `AVAudioEngine`
2. **Transcribe** — uploads the recording to Deepgram Nova-3 with speaker
   diarization.
3. **Summarize** — sends the diarized transcript to Gemini Flash, which returns
   a structured summary: headline, key points, and prioritized next steps.
4. **Export** — creates a Notion page with the summary and a checklist of next
   steps sorted by priority.

Only Google Meet is targeted for now (the detector looks for a Meet browser
tab), but recording is source-agnostic — it captures whatever system audio is
playing, so Zoom/Teams would work too with a tweak to `MeetDetector`.

---

## Requirements

- macOS **13.0+** (ScreenCaptureKit audio capture)
- Xcode **15+**
- [XcodeGen](https://github.com/yonkimi/XcodeGen) to generate the project:
  `brew install xcodegen`
- API keys: **Deepgram**, **Gemini (Google AI Studio)**, and a **Notion**
  internal integration token.

---

## Setup

```sh
# 1. Generate the Xcode project from project.yml
brew install xcodegen      # if you don't have it
xcodegen generate

# 2. Open it
open WindayNotetaker.xcodeproj

# 3. In Xcode: select your signing Team (target → Signing & Capabilities),
#    then Run (⌘R).
```

On first launch macOS will ask for **Screen Recording** and **Microphone**
permission — grant both (System Settings → Privacy & Security). Screen Recording
is what allows capturing the other participants' audio.

Then open **Settings (⌘,)** and paste your keys:

| Field | Where to get it |
|-------|-----------------|
| Deepgram API key | https://console.deepgram.com |
| Gemini API key | https://aistudio.google.com/apikey |
| Notion token | https://notion.so/my-integrations (internal integration) |
| Notion database ID | the 32-char id in your database URL |

Keys are stored in the **macOS Keychain**, never on disk in plain text.

### Notion setup (one time)

1. Create an **internal integration** at notion.so/my-integrations, copy its
   token (`secret_…` / `ntn_…`).
2. Open the database you want summaries to land in → **•••** → **Connections** →
   add your integration (so it has write access).
3. Copy the **database ID** from the URL and paste both into Settings → Notion.

The exporter only requires a **Title** property, so it works with any database.
Everything else (summary, key points, prioritized to-dos) is written as page
content.

---

## Architecture

```
WindayNotetaker/
├── App/            App entry point (WindayNotetakerApp) + window/scenes
├── Models/         Meeting, Transcript, MeetingSummary
├── Services/
│   ├── AudioRecorder.swift       ScreenCaptureKit + AVAudioEngine mixing → file
│   ├── DeepgramService.swift     Nova-3 pre-recorded transcription
│   ├── GeminiService.swift       Flash summarization (JSON schema enforced)
│   ├── NotionService.swift       Create a Notion page from a summary
│   ├── MeetDetector.swift        Heuristic "is a Meet call open?" detector
│   └── PipelineCoordinator.swift transcribe → summarize → export orchestration
├── ViewModels/     AppViewModel (state + pipeline driver)
├── Views/          ContentView, SummaryView, SettingsView
└── Support/        Config, Keychain, MeetingStore
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the data flow and the
known trade-offs in the audio-mixing path.

---

## Roadmap / TODO

- [ ] Real-time / streaming transcription option (Deepgram WebSocket)
- [ ] Auto-start recording when a Meet call is detected
- [ ] Push action items straight into Winday CRM (deals/tasks) as well as Notion
- [ ] App icon + notarized DMG build
- [ ] Lock-free ring buffer for the audio FIFO (see `AudioRecorder.swift`)

---

## License

Private project — © Winday.
