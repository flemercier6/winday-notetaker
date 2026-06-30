# Winday Notetaker

A native **macOS** app that records your **Google Meet** calls, transcribes them
with **Deepgram (Nova-3)**, summarizes them with **Gemini (Flash)**, and pushes
the summary, next steps and priorities to **Notion** — all through a secure
**Supabase** backend, so no API secret ever lives on the Mac.

Companion app to **Winday CRM**.

> Status: **v1 scaffold.** Backend is provisioned and live; build the macOS app
> in Xcode, set three server secrets, sign in, and iterate.

---

## How it works

```
 macOS app                         Supabase (backend)                3rd parties
┌───────────┐  upload .caf   ┌───────────────────────────┐
│  Record   │ ─────────────▶ │ Storage: recordings bucket │
│ (SCKit +  │                │                            │
│  mic mix) │  invoke fns    │ Edge Functions (hold the   │   Deepgram Nova-3
└───────────┘ ─────────────▶ │  secrets via Deno.env):    │ ─▶ transcribe
      ▲                      │   • transcribe             │   Gemini Flash
      │   transcript/summary │   • summarize              │ ─▶ summarize
      └───────────────────── │   • export-notion          │   Notion API
                             │ Postgres: meetings, RLS    │ ─▶ create page
                             └───────────────────────────┘
```

1. **Record** — mixes **system audio** (remote participants, via `ScreenCaptureKit`)
   and your **microphone** (via `AVAudioEngine`) into one `.caf` file.
2. **Upload** — the file goes to a **private** Supabase Storage bucket; a meeting
   row is created in Postgres (Row-Level-Security: you only ever see your own).
3. **Transcribe / Summarize / Export** — the app invokes Edge Functions by
   meeting id. The functions call Deepgram, Gemini and Notion **using secrets
   stored server-side**, then write the results back to the meeting row.

The third-party keys (Deepgram, Gemini, Notion) are **never shipped to the app**.
They live only as Supabase Edge Function secrets.

---

## Backend (already provisioned)

A dedicated Supabase project **"Winday Notetaker"** is live:

- Project ref: `jruoxnwhmgmajbzsjsjw` · region `eu-west-1`
- Tables: `meetings`, `user_settings` (both RLS-protected)
- Storage: private `recordings` bucket (per-user folders)
- Edge Functions: `transcribe`, `summarize`, `export-notion` (all `verify_jwt`)

### Set the three secrets (one time)

The functions need three secrets. Set them with the Supabase CLI (never commit
them):

```sh
supabase login
supabase link --project-ref jruoxnwhmgmajbzsjsjw

# copy the template and fill in your real keys
cp supabase/.env.example supabase/.env
$EDITOR supabase/.env

supabase secrets set --env-file supabase/.env
```

`supabase/.env` (gitignored) holds:

| Secret | Where to get it |
|--------|-----------------|
| `DEEPGRAM_API_KEY` | https://console.deepgram.com |
| `GEMINI_API_KEY` | https://aistudio.google.com/apikey |
| `NOTION_TOKEN` | https://notion.so/my-integrations (internal integration) |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically — don't set them.

### Enable email codes (one time)

The app signs in with a **6-digit email code**, not a magic link. In the Supabase
dashboard → **Authentication → Email Templates → Magic Link**, make sure the body
includes the token, e.g.:

```
Your Winday Notetaker code is: {{ .Token }}
```

(Email provider is enabled by default; no SMTP setup needed for low volume.)

> Already deployed via MCP, but to redeploy after edits:
> `supabase functions deploy transcribe summarize export-notion`
> and `supabase db push` for migrations.

---

## Build the macOS app

```sh
brew install xcodegen      # if you don't have it
xcodegen generate
open WindayNotetaker.xcodeproj
# Select your signing Team (target → Signing & Capabilities), then Run (⌘R)
```

Requirements: macOS **13.0+** (ScreenCaptureKit audio), Xcode **15+**.

On first launch macOS asks for **Screen Recording** and **Microphone**
permission — grant both (System Settings → Privacy & Security). Screen Recording
is what lets the app capture the other participants' audio.

The Supabase URL + publishable key are already baked into `Info.plist` (they're
safe to ship — access is gated by Auth + RLS).

### First run

1. **Sign in** — enter your email; Supabase emails a 6-digit code; type it back.
2. **(Optional) Notion** — Settings → Notion: paste the target **database ID**
   and toggle auto-export. (Add your integration to that database in Notion:
   ••• → Connections.)
3. **Record** during a Google Meet call, then **Stop & Summarize**.

---

## Project layout

```
WindayNotetaker/
├── App/            App entry point + window/scenes
├── Models/         Meeting, Transcript, MeetingSummary
├── Backend/
│   └── SupabaseClient.swift   auth (email OTP), storage upload, function calls
├── Services/
│   ├── AudioRecorder.swift       ScreenCaptureKit + AVAudioEngine mixing → file
│   ├── MeetDetector.swift        Heuristic "is a Meet call open?" detector
│   └── PipelineCoordinator.swift upload → transcribe → summarize → export
├── ViewModels/     AppViewModel (state + pipeline driver)
├── Views/          ContentView, SignInView, SummaryView, SettingsView
└── Support/        Config, Keychain, MeetingStore

supabase/
├── config.toml
├── migrations/     schema (tables, RLS, storage bucket)
├── functions/      transcribe · summarize · export-notion (Deno/TypeScript)
└── .env.example    the three secrets to set
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full data flow and
trade-offs.

---

## Roadmap / TODO

- [ ] Cross-device history: fetch `meetings` from Postgres on launch (durable
      copy already written server-side; UI currently keeps a local cache).
- [ ] Real-time / streaming transcription (Deepgram WebSocket).
- [ ] Auto-start recording when a Meet call is detected.
- [ ] Push action items into Winday CRM (deals/tasks) alongside Notion.
- [ ] App icon + notarized DMG build.
- [ ] Lock-free ring buffer for the audio FIFO (see `AudioRecorder.swift`).

---

## License

Private project — © Winday.
