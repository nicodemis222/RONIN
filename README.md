# RONIN

A local-first meeting copilot for macOS. Real-time transcription, AI-powered suggestions, and post-meeting summaries — all running on your machine with zero cloud dependencies.

![Version](https://img.shields.io/badge/version-1.0.0-00FF41)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=00FF41)
![Swift](https://img.shields.io/badge/Swift-5.10-00FF41?logo=swift&logoColor=00FF41)
![Python](https://img.shields.io/badge/Python-3.14-00FF41?logo=python&logoColor=00FF41)
![Tests](https://img.shields.io/badge/tests-128%20passing-00FF41)
![License](https://img.shields.io/badge/license-MIT-00FF41)

## What It Does

RONIN listens to your microphone during meetings and provides:

- **Live transcription** — MLX Whisper running natively on Apple Silicon
- **Suggested responses** — 2-3 tone-varied replies (direct, diplomatic, curious) generated in real-time
- **Follow-up questions** — keeps the conversation on track toward your meeting goal
- **Risk flags** — alerts when discussion conflicts with your constraints or goals
- **Relevant facts** — surfaces info from your prep notes when the conversation touches on those topics
- **Post-meeting summary** — executive summary, key decisions, action items, and open questions

Everything runs locally by default. Audio never leaves your Mac. Choose between a local LLM via LM Studio or a cloud provider (OpenAI) — audio always stays on-device regardless.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI Mac App (RoninApp)                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐ │
│  │ MeetingPrep  │→ │ LiveCopilot  │→ │ PostMeeting    │ │
│  │ View         │  │ View         │  │ View           │ │
│  └──────────────┘  └──────┬───────┘  └────────────────┘ │
│                           │                              │
│  AudioCaptureService      │ WebSocket                    │
│  (AVCaptureSession)       │                              │
│  SettingsView (⌘,)        │                              │
│  TutorialOverlay          │                              │
└───────────────────────────┼──────────────────────────────┘
                            │
┌───────────────────────────┼──────────────────────────────┐
│  Python Backend (FastAPI) │                              │
│                           ▼                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐ │
│  │ Transcription│  │ LLM Client   │  │ Meeting State  │ │
│  │ (MLX Whisper)│  │ (pluggable)  │  │ Manager        │ │
│  └──────────────┘  └──────┬───────┘  └────────────────┘ │
│                           │                              │
│              ┌────────────┼────────────┐                 │
│              ▼            ▼            ▼                 │
│          LM Studio    OpenAI      Anthropic              │
│          (local)      (cloud)     (cloud)                │
└──────────────────────────────────────────────────────────┘
```

The Swift app captures mic audio via `AVCaptureSession` (no aggregate device — works alongside Teams, Zoom, WhatsApp without conflicts), streams PCM chunks over WebSocket to the Python backend. The backend runs MLX Whisper for transcription and calls the configured LLM provider for copilot suggestions and summaries.

## Prerequisites

| Requirement | Version | Purpose |
|---|---|---|
| **macOS** | 15.0+ | SwiftUI features, AVCaptureSession APIs |
| **Xcode** | 16+ | Build the Swift app |
| **Python** | 3.13+ | Backend runtime |
| **LM Studio** | Latest | Local LLM inference (or use OpenAI/Anthropic instead) |
| **Apple Silicon** | M1+ | MLX Whisper requires Metal |

## Setup

### 1. Clone and set up the backend

```bash
git clone https://github.com/nicodemis222/RONIN.git
cd RONIN/backend

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Download the Whisper model

The first run will download `mlx-community/whisper-small-mlx` (~150 MB). Make sure you have an internet connection for the initial launch.

### 3. Set up an LLM provider

**Option A: Local (LM Studio) — fully private, no data leaves your Mac**

1. Download and install [LM Studio](https://lmstudio.ai)
2. Download a model — recommended: **Qwen 3.5 7B** or **Qwen 3.5 14B** (larger = better suggestions, but slower)
3. Start the local server in LM Studio (default: `http://localhost:1234`)

> **Tip**: Qwen 3.x models have a "thinking" mode that outputs `<think>...</think>` blocks. RONIN suppresses this automatically via prompt engineering, reducing response time from ~30s to ~4s.

**Option B: OpenAI — faster responses, requires API key**

1. Get an API key from [platform.openai.com](https://platform.openai.com)
2. In RONIN, open Settings (⌘,) → LLM tab → select OpenAI
3. Enter your API key and click "Save & Restart Backend"

> **Note**: With cloud providers, transcript text is sent to the provider's API for analysis. Audio always stays on your Mac — only the text transcription is transmitted.

**Option C: Transcription only — no LLM**

If no LLM is configured, RONIN still captures and saves the full transcript. You'll get a saved transcript file but no AI-generated suggestions or summaries.

### 4. Build and run the Swift app

```bash
cd RONIN/RoninApp
xcodebuild -scheme RoninApp -configuration Debug build
```

Or open `RoninApp.xcodeproj` in Xcode and hit Run (⌘R).

The app automatically launches the Python backend on startup. A dependency checklist verifies Python, the backend process, Whisper model, LLM provider, and microphone access — each showing pass/fail status. Once all checks pass, the checklist collapses to a compact status badge.

First-time users see an onboarding tutorial walkthrough. You can re-launch it anytime from Settings (⌘,) → General → Show Tutorial.

## Usage

### Meeting Prep

1. **Title** — Name your meeting
2. **Goal** — What you want to achieve (e.g., "Negotiate contract terms under $50k")
3. **Notes Pack** — Drag and drop `.md` or `.txt` files with prep material, background info, or reference data
4. **Constraints** — Rules the copilot should follow (e.g., "Do not agree to timeline shorter than 6 months")
5. Click **Start Listening**

### During the Meeting

RONIN opens a resizable floating overlay window with three panels. Drag the dividers between panels to adjust proportions. The window can be resized freely on both axes and stays on top of other apps.

| Panel | Content |
|---|---|
| **Transcript** | Real-time speech-to-text with timestamps |
| **Responses** | 2-3 tone-varied suggested replies you can copy with one click. All responses are preserved as scrollable history — newest at the bottom with auto-scroll, older responses above with timestamp separators. |
| **Guidance** | Follow-up questions, risk alerts, and relevant facts from your notes. Full history preserved with the same auto-scroll behavior as Responses. |

Controls:
- **⌘⇧M** — Mute/unmute microphone
- **⌘⇧P** — Pause/resume copilot
- **⌘⇧O** — Show/hide overlay
- **⌘⇧C** — Toggle compact/full mode
- **⌘⇧E** — End meeting
- **⌘D** — Toggle debug console

The overlay stays on top of other windows. Use the menu bar icon for quick access to all controls.

### After the Meeting

Click **End Meeting** to generate a structured summary. A progress bar shows the generation status through four phases (saving transcript → analyzing → extracting decisions → building summary).

- **Executive Summary** — 3-5 sentence overview
- **Key Decisions** — What was decided, with context
- **Action Items** — Tasks with assignees and deadlines (when mentioned)
- **Open Questions** — Unresolved topics needing follow-up

Export to Markdown or copy to clipboard. The exported Markdown includes the full transcript with speaker labels grouped under speaker headers.

> **Safety**: The full transcript is saved to `~/Library/Logs/Ronin/transcripts/` before the LLM is called. Even if summary generation fails, your transcript is preserved. Quitting the app during an active meeting also triggers a graceful save.

## Configuration

Most settings can be changed in the app via **Settings** (⌘,):
- **General** — Re-launch the onboarding tutorial
- **LLM** — Switch between Local (LM Studio) and OpenAI, configure API keys
- **Overlay** — Default compact mode, panel layout orientation, overlay opacity

Backend settings in `backend/app/config.py`:

| Setting | Default | Description |
|---|---|---|
| `llm_provider` | `"local"` | LLM backend: `"local"`, `"openai"`, `"anthropic"`, or `"none"` |
| `lm_studio_url` | `http://localhost:1234/v1` | LM Studio API endpoint (local mode) |
| `openai_api_key` | `""` | OpenAI API key (openai mode) |
| `anthropic_api_key` | `""` | Anthropic API key (anthropic mode) |
| `llm_model` | `""` | Override default model for the chosen provider |
| `whisper_model` | `mlx-community/whisper-small-mlx` | Whisper model for transcription |
| `llm_debounce_seconds` | `10.0` | Minimum seconds between copilot LLM calls |
| `transcript_window_minutes` | `1.5` | How much recent transcript to send to the LLM |
| `max_buffer_seconds` | `30.0` | Max audio buffer before forced transcription |
| `notes_max_context_chars` | `3000` | Max characters of notes context sent to LLM |
| `whisper_no_speech_threshold` | `0.6` | Filter non-speech segments (music, noise) |
| `whisper_logprob_threshold` | `-1.0` | Filter low-confidence Whisper output |
| `whisper_compression_threshold` | `2.4` | Filter repetitive hallucinations |

## Project Structure

```
RONIN/
├── RoninApp/                         # SwiftUI macOS app
│   └── RoninApp/
│       ├── RoninApp.swift            # App entry point, ContentView, menu bar
│       ├── Models/
│       │   ├── CopilotSuggestion.swift   # Suggestion, Risk, NoteFact models
│       │   ├── DependencyStatus.swift     # Startup dependency check states
│       │   ├── MeetingConfig.swift        # Meeting setup request/response
│       │   ├── MeetingSummary.swift       # Post-meeting summary model
│       │   ├── TranscriptSegment.swift    # Individual transcript line
│       │   └── WebSocketMessage.swift     # WebSocket message types
│       ├── Views/
│       │   ├── MatrixTheme.swift          # Colors, fonts, modifiers, styles
│       │   ├── MeetingPrepView.swift      # Pre-meeting setup screen
│       │   ├── LiveCopilotView.swift      # Floating overlay with 3 panels
│       │   ├── PostMeetingView.swift      # Summary display + progress bar
│       │   ├── ControlBarView.swift       # Mute/pause/end controls
│       │   ├── TranscriptPanelView.swift  # Live transcript panel
│       │   ├── SuggestionsPanelView.swift # Suggested responses panel
│       │   ├── GuidancePanelView.swift    # Questions/risks/facts panel
│       │   ├── DependencyChecklistView.swift # Startup system check UI
│       │   ├── SettingsView.swift         # Settings window (⌘,)
│       │   └── TutorialOverlayView.swift  # First-run onboarding cards
│       ├── ViewModels/
│       │   ├── LiveCopilotViewModel.swift # WebSocket + audio orchestration
│       │   ├── MeetingPrepViewModel.swift # Meeting setup logic
│       │   ├── PostMeetingViewModel.swift # Summary fetching + progress + export
│       │   ├── LLMSettingsViewModel.swift # LLM provider configuration
│       │   └── TutorialViewModel.swift    # Onboarding tutorial state
│       └── Services/
│           ├── AudioCaptureService.swift  # Mic capture via AVCaptureSession
│           ├── BackendProcessService.swift# Python process lifecycle + deps
│           ├── BackendAPIService.swift    # HTTP client for REST endpoints
│           ├── WebSocketService.swift     # WebSocket client
│           └── KeychainHelper.swift       # Secure API key storage
│
├── backend/                          # Python FastAPI backend
│   ├── run.py                        # Entry point with logging setup
│   ├── requirements.txt              # Python dependencies
│   ├── tests/                        # pytest test suite (128 unit tests)
│   │   ├── test_api.py              # REST API + input validation (25 tests)
│   │   ├── test_context_window.py   # Context window management (8 tests)
│   │   ├── test_llm_client.py       # LLM client + normalization (20 tests)
│   │   ├── test_meeting_state.py    # Session management (9 tests)
│   │   ├── test_notes_manager.py    # Notes engine (18 tests)
│   │   ├── test_transcription.py    # Whisper + hallucination filter (18 tests)
│   │   └── test_websocket.py        # WebSocket protocol (15 tests)
│   └── app/
│       ├── main.py                   # FastAPI app with lifespan
│       ├── config.py                 # Settings (ports, models, timing)
│       ├── routers/
│       │   ├── meeting.py            # /meeting/setup, /end, /health, /shutdown
│       │   └── ws.py                 # WebSocket /ws/audio
│       ├── services/
│       │   ├── transcription.py      # MLX Whisper + hallucination filtering
│       │   ├── llm_client.py         # LLM orchestration + JSON normalization
│       │   ├── provider_factory.py   # Creates LLM provider from config
│       │   ├── providers/            # Pluggable LLM backends
│       │   │   ├── base.py           # Abstract provider interface
│       │   │   ├── local.py          # LM Studio (OpenAI-compatible)
│       │   │   ├── openai_provider.py# OpenAI API
│       │   │   └── anthropic_provider.py # Anthropic API
│       │   ├── prompt_builder.py     # System prompts + response schemas
│       │   ├── meeting_state.py      # Session management
│       │   ├── notes_manager.py      # Keyword-based note retrieval
│       │   └── speaker_tracker.py    # Speaker diarization
│       └── schemas/
│           ├── meeting.py            # Setup request/response schemas
│           ├── copilot.py            # Copilot response schema
│           ├── summary.py            # Meeting summary schema
│           └── transcript.py         # Transcript segment schema
│
├── scripts/
│   ├── build-dmg.sh                 # Build macOS DMG installer
│   ├── setup.sh                     # First-time environment setup
│   ├── start.sh                     # Start backend server
│   └── test_pipeline.py             # Integration test pipeline
│
├── CONTEXT_WINDOW_GUIDE.md           # LLM context window tuning guide
├── TEST_PLAN.md                      # Full v1.0 test report (128 unit + 7 E2E + 12 UX tests)
└── README.md
```

## Testing

### Run backend unit tests

```bash
cd RONIN/backend
source .venv/bin/activate
python -m pytest tests/ -v
```

128 tests covering: REST API, WebSocket protocol, transcription pipeline, LLM client normalization, context window management, notes engine, and session state.

### Run Swift build verification

```bash
cd RONIN/RoninApp
xcodebuild build -scheme RoninApp -configuration Debug
```

See [TEST_PLAN.md](TEST_PLAN.md) for the full v1.0 test report including end-to-end integration tests and UX acceptance test results.

## How Audio Capture Works

RONIN uses `AVCaptureSession` instead of `AVAudioEngine` to capture microphone audio. This is critical for compatibility with video call apps:

- **AVAudioEngine** creates a hidden aggregate audio device that conflicts with Teams, Zoom, and WhatsApp (which create their own aggregate devices)
- **AVCaptureSession** opens the mic directly through Core Audio's multiclient HAL — no aggregate device, no conflicts

The audio pipeline:
1. Mic audio arrives as `CMSampleBuffer` at the device's native format (often 48kHz, sometimes 3+ channels)
2. `AudioCaptureService` converts to 16kHz mono PCM using `AVAudioConverter` with a 3-tier format fallback for unusual channel counts
3. PCM chunks (2 seconds each) are sent over WebSocket to the backend
4. The backend accumulates audio and runs Whisper when it detects speech boundaries

## Troubleshooting

### Backend won't start
- Check `~/Library/Logs/Ronin/backend.log` for errors
- Make sure Python 3.13+ is installed and the venv is set up
- Ensure port 8000 is free (`lsof -i :8000`)

### No transcription
- Check that microphone permission is granted (System Settings > Privacy > Microphone)
- Look at the debug console (⌘D) for audio callback counts
- Whisper needs ~3 seconds of audio before the first transcription
- If music or noise produces garbage text, RONIN's hallucination filter should catch it — check `whisper_no_speech_threshold` in config if needed

### Copilot suggestions not appearing
- Make sure your LLM provider is configured (Settings ⌘, → LLM tab)
- For local mode: LM Studio must be running with a loaded model
- For OpenAI mode: verify your API key is valid
- Check the debug console for "Copilot generation failed" errors
- The LLM needs ~4-10 seconds per response depending on model/provider

### Audio conflicts with call apps
- RONIN should work alongside Teams, Zoom, and WhatsApp without issues
- If you hear audio artifacts, the mic may be switching to an unexpected format — check debug console for "Converter:" log lines

## License

MIT
