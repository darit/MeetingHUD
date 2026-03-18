# MeetingHUD

**Real-time audio intelligence for macOS.** A native SwiftUI app that listens, transcribes, identifies speakers, and provides live AI-powered insights — all running 100% locally on Apple Silicon.

Works with meetings, standups, news broadcasts, podcasts, lectures, streams, and any audio content.

![macOS](https://img.shields.io/badge/macOS-15%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-orange)
![Swift](https://img.shields.io/badge/Swift-6.0-red)
![License](https://img.shields.io/badge/License-BSL%201.1-green)

## What It Does

- **Floating HUD overlay** — transparent three-column layout (Speakers | Live Transcript | Insights) with vibrancy material, stays on top of all windows
- **Real-time transcription** — WhisperKit on Neural Engine, multilingual (99 languages), word-level timestamps
- **Speaker identification** — voice embedding matching across meetings, cosine similarity with Accelerate framework
- **Content type detection** — automatically classifies audio as meeting, standup, refinement, retrospective, news, podcast, stream, lecture, round table, interview, presentation, or conversation
- **Live AI insights** — LLM-powered recommendations, topic extraction, sentiment analysis, action item detection, next-topic suggestions — all context-aware based on detected content type
- **Always-on mode** — VAD-based state machine: listening -> conversation -> meeting. Auto-elevates when meeting apps are detected
- **Meeting history** — browse past meetings, review summaries/topics/action items, ask the LLM questions about any previous session
- **Chat** — ask questions about the current meeting or any past meeting with streaming LLM responses
- **100% local** — zero cloud costs, zero data leaves your machine. WhisperKit on ANE, MLX LLM on GPU.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI HUD (NSPanel, floating overlay)                  │
├──────────────────────────────────────────────────────────┤
│  MeetingEngine (@Observable, Swift Concurrency)           │
│  ├── RecommendationAgent (LLM + categorized insights)     │
│  ├── ContentTypeClassifier (auto-detect content type)     │
│  ├── Three-Tier Memory (HOT → WARM → COLD)                │
│  └── SpeakerIdentifier (voice embeddings + SwiftData)     │
├────────┬────────┬────────┬────────┬────────┬─────────────┤
│ Audio  │Whisper │Speaker │ Screen │ MLX    │ Persistence │
│ Tap    │ Kit    │ Kit    │Context │ LLM    │             │
│CoreAud.│CoreML/ │Pyannote│AX+OCR │Llama   │ SwiftData   │
│ Taps   │ ANE    │ ANE    │Vision  │3.2 3B  │             │
└────────┴────────┴────────┴────────┴────────┴─────────────┘
```

### Pipeline

```
Audio source (Core Audio Tap — non-destructive)
  → PCM buffers (16kHz mono Float32)
    → WhisperKit (streaming, on ANE)
      → Transcript segments with timestamps
        → Speaker diarization (SpeakerKit, on ANE)
          → Speaker-labeled segments
            → MLX LLM (analysis, on GPU — no ANE contention)
              → Sentiment, topics, signals, recommendations
                → SwiftUI HUD (live update via @Observable)
```

### Three-Tier Memory

| Tier | Content | Budget |
|------|---------|--------|
| **HOT** | Rolling 5-min verbatim transcript | ~3K tokens |
| **WARM** | LLM-compressed meeting summary, updated every ~2 min | ~4K tokens |
| **COLD** | SwiftData persistent store (full history) | Unlimited |

## Tech Stack

| Component | Technology |
|-----------|-----------|
| UI | SwiftUI + NSPanel (floating, non-activating) |
| State | @Observable (Swift 5.9+), Swift 6 strict concurrency |
| Audio | Core Audio Taps (CATapDescription, macOS 14.4+) |
| Transcription | WhisperKit (large-v3-turbo, CoreML/ANE) |
| Speaker ID | SpeakerKit (WhisperKit) + voice embeddings |
| LLM | mlx-swift-lm (Llama 3.2 3B on GPU) |
| Persistence | SwiftData |
| Meeting detection | Accessibility API + EventKit |

## Requirements

- **macOS 15+** (Sequoia)
- **Apple Silicon** (M1 or later)
- 8GB RAM minimum (uses Llama 3.2 1B), 16GB+ recommended (uses 3B)
- Accessibility permission (for meeting window detection)
- Audio capture permission (for Core Audio Taps)

## Build & Run

```bash
# Clone
git clone https://github.com/darit/MeetingHUD.git
cd MeetingHUD

# Build and run (handles code signing + entitlements)
./bundle.sh
```

Or open `Package.swift` in Xcode and build the `MeetingHUD` target.

### First Run

1. Grant **Accessibility** permission in System Settings > Privacy > Accessibility
2. Grant **Audio Capture** permission when prompted
3. The Whisper model (~800MB for large-v3-turbo) downloads automatically on first launch
4. The LLM model downloads from HuggingFace on first launch

## How It Works

1. **Click Record** or enable **Always-On Listening** from the menu bar
2. Audio is captured via Core Audio Taps (non-destructive, works with any app)
3. WhisperKit transcribes in real-time on the Neural Engine
4. The LLM analyzes transcript for topics, sentiment, action items, and recommendations
5. Everything appears live in the floating HUD overlay
6. When you stop, the meeting is persisted with full analytics

## Content-Aware Intelligence

The app automatically detects what kind of audio you're listening to and tailors its insights:

| Content Type | Insight Focus |
|-------------|--------------|
| **Meeting** | Action items, decisions, follow-ups |
| **Daily Standup** | Blockers, missing updates, follow-ups |
| **Refinement** | Unclear criteria, missing estimates, scope creep |
| **Retrospective** | Recurring themes, actionable improvements |
| **News** | Key claims, data points, bias detection |
| **Podcast** | Interesting claims, counterpoints, themes |
| **Presentation** | Audience engagement, unclear points, questions |
| **Stream** | Highlights, key moments |

## Privacy

- **100% local processing** — no data leaves your machine
- **No telemetry** — no analytics, no tracking, no phone-home
- **No cloud APIs required** — everything runs on your Apple Silicon
- **Your data stays yours** — all meetings stored in local SwiftData

## Status

This is an active personal project. See [CLAUDE.md](CLAUDE.md) for detailed development notes, architecture decisions, and roadmap.

## Author

**Daniel Rodriguez** ([@darit](https://github.com/darit))
