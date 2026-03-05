# RONIN

A local-first meeting copilot for macOS. Real-time transcription, AI-powered suggestions, and post-meeting summaries — all running on your machine with zero cloud dependencies.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=00FF41)
![Swift](https://img.shields.io/badge/Swift-5.10-00FF41?logo=swift&logoColor=00FF41)
![Python](https://img.shields.io/badge/Python-3.14-00FF41?logo=python&logoColor=00FF41)
![License](https://img.shields.io/badge/license-MIT-00FF41)

## What It Does

RONIN listens to your microphone during meetings and provides:

- **Live transcription** — MLX Whisper running natively on Apple Silicon
- **Suggested responses** — 2-3 tone-varied replies (direct, diplomatic, curious) generated in real-time
- **Follow-up questions** — keeps the conversation on track toward your meeting goal
- **Risk flags** — alerts when discussion conflicts with your constraints or goals
- **Relevant facts** — surfaces info from your prep notes when the conversation touches on those topics
- **Post-meeting summary** — executive summary, key decisions, action items, and open questions

Everything runs locally. Audio never leaves your Mac. The LLM runs through LM Studio on your own hardware.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI Mac App (RoninApp)                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │ MeetingPrep  │→ │ LiveCopilot  │→ │ PostMeeting   │ │
│  │ View         │  │ View         │  │ View          │ │
│  └──────────────┘  └──────┬───────┘  └───────────────┘ │
│                           │                             │
│  AudioCaptureService      │ WebSocket                   │
│  (AVCaptureSession)       │                             │
└───────────────────────────┼─────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────┐
│  Python Backend (FastAPI) │                             │
│                           ▼                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │ Transcription│  │ LLM Client   │  │ Meeting State │ │
│  │ (MLX Whisper)│  │ (LM Studio)  │  │ Manager       │ │
│  └──────────────┘  └──────────────┘  └───────────────┘ │
└─────────────────────────────────────────────────────────┘
```

The Swift app captures mic audio via `AVCaptureSession` (no aggregate device — works alongside Teams, Zoom, WhatsApp without conflicts), streams PCM chunks over WebSocket to the Python backend. The backend runs MLX Whisper for transcription and calls LM Studio for copilot suggestions and summaries.

## Prerequisites

| Requirement | Version | Purpose |
|---|---|---|
| **macOS** | 15.0+ | SwiftUI features, AVCaptureSession APIs |
| **Xcode** | 16+ | Build the Swift app |
| **Python** | 3.13+ | Backend runtime |
| **LM Studio** | Latest | Local LLM inference |
| **Apple Silicon** | M1+ | MLX Whisper requires Metal |

## Setup

### 1. Clone and set up the backend

```bash
git clone https://github.com/yourusername/RONIN.git
cd RONIN/backend

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Download the Whisper model

The first run will download `mlx-community/whisper-small-mlx` (~150 MB). Make sure you have an internet connection for the initial launch.

### 3. Set up LM Studio

1. Download and install [LM Studio](https://lmstudio.ai)
2. Download a model — recommended: **Qwen 3.5 7B** or **Qwen 3.5 14B** (larger = better suggestions, but slower)
3. Start the local server in LM Studio (default: `http://localhost:1234`)

> **Tip**: Qwen 3.x models have a "thinking" mode that outputs `<think>...</think>` blocks. RONIN suppresses this automatically via prompt engineering, reducing response time from ~30s to ~4s.

### 4. Build and run the Swift app

```bash
cd RONIN/RoninApp
xcodebuild -scheme RoninApp -configuration Debug build
```

Or open `RoninApp.xcodeproj` in Xcode and hit Run (⌘R).

The app automatically launches the Python backend on startup. You'll see a green "Backend online" indicator in the Meeting Prep screen when it's ready.

## Usage

### Meeting Prep

1. **Title** — Name your meeting
2. **Goal** — What you want to achieve (e.g., "Negotiate contract terms under $50k")
3. **Notes Pack** — Drag and drop `.md` or `.txt` files with prep material, background info, or reference data
4. **Constraints** — Rules the copilot should follow (e.g., "Do not agree to timeline shorter than 6 months")
5. Click **Start Listening**

### During the Meeting

RONIN opens a floating overlay window with three panels:

| Panel | Content |
|---|---|
| **Transcript** | Real-time speech-to-text with timestamps |
| **Responses** | 2-3 tone-varied suggested replies you can copy with one click |
| **Guidance** | Follow-up questions, risk alerts, and relevant facts from your notes |

Controls:
- **⌘⇧M** — Mute/unmute microphone
- **⌘⇧P** — Pause/resume copilot
- **⌘⇧O** — Show/hide overlay
- **⌘⇧C** — Toggle compact/full mode
- **⌘⇧E** — End meeting
- **⌘D** — Toggle debug console

The overlay stays on top of other windows. Use the menu bar icon for quick access to all controls.

### After the Meeting

Click **End Meeting** to generate a structured summary:

- **Executive Summary** — 3-5 sentence overview
- **Key Decisions** — What was decided, with context
- **Action Items** — Tasks with assignees and deadlines (when mentioned)
- **Open Questions** — Unresolved topics needing follow-up

Export to Markdown or copy to clipboard.

## Configuration

Backend settings in `backend/app/config.py`:

| Setting | Default | Description |
|---|---|---|
| `lm_studio_url` | `http://localhost:1234/v1` | LM Studio API endpoint |
| `whisper_model` | `mlx-community/whisper-small-mlx` | Whisper model for transcription |
| `llm_debounce_seconds` | `10.0` | Minimum seconds between copilot LLM calls |
| `transcript_window_minutes` | `1.5` | How much recent transcript to send to the LLM |
| `max_buffer_seconds` | `30.0` | Max audio buffer before forced transcription |
| `notes_max_context_chars` | `3000` | Max characters of notes context sent to LLM |

## Project Structure

```
RONIN/
├── RoninApp/                         # SwiftUI macOS app
│   └── RoninApp/
│       ├── RoninApp.swift            # App entry point, ContentView, menu bar
│       ├── Models/
│       │   ├── CopilotSuggestion.swift   # Suggestion, Risk, NoteFact models
│       │   ├── MeetingConfig.swift        # Meeting setup request/response
│       │   ├── MeetingSummary.swift       # Post-meeting summary model
│       │   ├── TranscriptSegment.swift    # Individual transcript line
│       │   └── WebSocketMessage.swift     # WebSocket message types
│       ├── Views/
│       │   ├── MatrixTheme.swift          # Colors, fonts, modifiers, styles
│       │   ├── MeetingPrepView.swift      # Pre-meeting setup screen
│       │   ├── LiveCopilotView.swift      # Floating overlay with 3 panels
│       │   ├── PostMeetingView.swift      # Summary display screen
│       │   ├── ControlBarView.swift       # Mute/pause/end controls
│       │   ├── TranscriptPanelView.swift  # Live transcript panel
│       │   ├── SuggestionsPanelView.swift # Suggested responses panel
│       │   └── GuidancePanelView.swift    # Questions/risks/facts panel
│       ├── ViewModels/
│       │   ├── LiveCopilotViewModel.swift # WebSocket + audio orchestration
│       │   ├── MeetingPrepViewModel.swift # Meeting setup logic
│       │   └── PostMeetingViewModel.swift # Summary fetching + export
│       └── Services/
│           ├── AudioCaptureService.swift  # Mic capture via AVCaptureSession
│           ├── BackendProcessService.swift# Python process lifecycle
│           ├── BackendAPIService.swift    # HTTP client for REST endpoints
│           └── WebSocketService.swift     # WebSocket client
│
├── backend/                          # Python FastAPI backend
│   ├── run.py                        # Entry point with logging setup
│   ├── requirements.txt              # Python dependencies
│   └── app/
│       ├── main.py                   # FastAPI app with lifespan
│       ├── config.py                 # Settings (ports, models, timing)
│       ├── routers/
│       │   ├── meeting.py            # POST /meeting/setup, /meeting/end
│       │   └── ws.py                 # WebSocket /ws/audio
│       ├── services/
│       │   ├── transcription.py      # MLX Whisper integration
│       │   ├── llm_client.py         # LM Studio API + JSON normalization
│       │   ├── prompt_builder.py     # System prompts + response schemas
│       │   ├── meeting_state.py      # Session management
│       │   └── notes_manager.py      # Keyword-based note retrieval
│       └── schemas/
│           ├── meeting.py            # Setup request/response schemas
│           ├── copilot.py            # Copilot response schema
│           ├── summary.py            # Meeting summary schema
│           └── transcript.py         # Transcript segment schema
│
└── README.md
```

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

### Copilot suggestions not appearing
- Make sure LM Studio is running with a loaded model
- Check the debug console for "Copilot generation failed" errors
- The LLM needs ~4-10 seconds per response depending on model size

### Audio conflicts with call apps
- RONIN should work alongside Teams, Zoom, and WhatsApp without issues
- If you hear audio artifacts, the mic may be switching to an unexpected format — check debug console for "Converter:" log lines

## License

MIT
