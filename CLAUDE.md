# MeetingHUD — Real-Time Meeting Intelligence for macOS

## What This Is
A native macOS 26 SwiftUI app that acts as a floating HUD overlay during video meetings (Teams, Google Meet, Zoom). Captures meeting audio, transcribes in real-time with speaker identification, tracks interlocutor profiles across meetings, provides live recommendations, and lets you ask questions about the current meeting — all running 100% locally on Apple Silicon with zero cloud costs.

## Current State (as of 2026-03-17)

### What's Built and Working
- **Floating NSPanel overlay** — borderless, non-activating, transparent, joins all spaces. Three-column layout (Speakers | Live Feed | Insights) with bottom chat drawer. Vibrancy material. Positioned at bottom-center.
- **Copy transcript** — "Copy All" button in Live Feed header, per-conversation-group copy buttons, right-click "Copy" on individual segments. Format: `[Speaker A] (0:42): text`.
- **Silence gap segmentation** — Transcript auto-groups by 2+ min silence gaps with visual dividers showing gap duration.
- **Chat as bottom drawer** — Single-line input always visible at bottom. Typing or tapping expands to show conversation history (~130px). Column 3 always shows Recommendations (no toggle).
- **Menu bar extra** — capture state controls (Record, Listen Always-On, Stop), toggle overlay, auto-detect toggle, paste/clear meeting agenda. Icon: ear (listening) / waveform (conversation) / waveform.fill (meeting) / mic (off).
- **Capture state machine** (`CaptureState`) — `.off` → `.listening` → `.conversation` → `.meeting`. Always-on mode with VAD transitions. Meeting elevation/de-elevation when meeting apps detected.
- **Always-on capture** (`AlwaysOnCaptureManager`) — Energy-based VAD (RMS threshold + 500ms onset). Transitions to conversation on speech, back to idle after 2 min silence.
- **Meeting elevation** — When meeting app detected during `.conversation`, elevates to `.meeting` with full analysis pipeline. De-elevates on meeting end with post-meeting processing.
- **Auto meeting detection** (`MeetingAutoDetector`) — polls every 3s using Accessibility API to read window titles. Detects native apps and browser meetings. Calendar enrichment. Now triggers elevation instead of start/stop.
- **Audio capture** (`AudioCaptureManager`) — Full Core Audio Tap implementation using CATapDescription + AudioHardwareCreateProcessTap. Non-destructive stereo mixdown, aggregate device wrapping, AVAudioEngine resampling to 16kHz mono Float32, RMS audio level metering.
- **SwiftData models** — 7 models defined and ModelContainer initialized:
  - Interlocutor (with voice embeddings array)
  - Meeting (with compressed transcript)
  - MeetingParticipation (talk time, sentiment, vocabulary, question ratio, key statements)
  - Topic (time-ranged within meeting)
  - ActionItem (with status enum, owner, due date)
  - ConversationSession (ambient/meeting/call, optional Meeting link)
  - TranscriptSegment (in-memory struct, not persisted)
- **AppState** — @Observable @MainActor central state with CaptureState enum coordinating all subsystems
- **Theme + Constants** — color palette, typography scale, timing intervals, token budgets, VAD constants
- **Live analytics** (`MeetingEngine`) — orchestrates sentiment analysis, topic extraction, signal detection, communication metrics on a 30s timer. Speaker dominance shift detection. Reduced cooldown (25s). Incremental per-speaker stats (O(1) per segment).
- **Proactive insights** (`RecommendationAgent`) — LLM-powered categorized insights (Observation / Suggestion / Risk / Summary). Triggered on topic shifts, periodic checks, speaker dominance shifts. JSON parsing with fallback. Reduced cooldown (25s). Auto-dismiss after 60s, cap at 5 visible.
- **Speaker identification** (`SpeakerIdentifier`) — Loads known profiles from SwiftData at session start. Cosine similarity matching with Accelerate. Auto-labels recognized speakers from voice embeddings.
- **Voice embedding persistence** — On speaker naming, voice embeddings are stored in `Interlocutor.voiceEmbeddings` for cross-meeting recognition. Max 5 embeddings per person.
- **Self-signed code signing** — `bundle.sh` creates/uses a "MeetingHUD Dev" certificate for stable identity. macOS remembers permissions across rebuilds.
- **Post-meeting summary** — LLM generates a meeting summary at stop time if model is loaded. Includes agenda context if provided.
- **Meeting agenda** — user can paste a meeting agenda from clipboard (Cmd+Shift+V in menu bar). Agenda is fed to topic extraction and post-meeting summary prompts for context-aware analysis.
- **Persistence** — `MeetingPersistenceManager` saves meetings with NLP analytics and voice embeddings.

### What's Not Started Yet
- Screen context OCR
- Profile management UI (CRUD, dashboards)
- Tethered panel mode (dock to meeting window)
- File/web/meeting/calendar search tools
- Cross-meeting analytics
- Global hotkey (KeyboardShortcuts wired but not configured)

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI HUD (NSPanel, tethered to meeting window)        │
├──────────────────────────────────────────────────────────┤
│  MeetingEngine (@Observable, Swift Concurrency)           │
│  ├── RecommendationAgent (LLM agent with tool use)        │
│  ├── Three-Tier Memory (HOT → WARM → COLD)                │
│  └── ProfileManager (voice embeddings + SwiftData)        │
├────────┬────────┬────────┬────────┬────────┬─────────────┤
│ Audio  │Whisper │Speaker │ Screen │ MLX    │ Search      │
│ Tap    │ Kit    │ Kit    │Context │ LLM    │ Tools       │
│CoreAud.│CoreML/ │Pyannote│AX+OCR │Llama   │mdfind, web, │
│ Taps   │ ANE    │ ANE    │Vision  │3.2 3B  │SwiftData,Cal│
└────────┴────────┴────────┴────────┴────────┴─────────────┘
```

### Pipeline Flow
```
Meeting app audio (Core Audio Tap)
  → PCM buffers (16kHz mono Float32)
    → WhisperKit (streaming, on ANE)
      → Transcript segments with timestamps
        → SpeakerKit (diarization, on ANE)
          → Speaker-labeled segments
            → MLX LLM (analysis, on GPU — no ANE contention)
              → Sentiment, topics, signals, recommendations
                → SwiftUI HUD (live update via @Observable)
```

### Three-Tier Memory System
- **Tier 1 (HOT)**: Rolling 5-min verbatim transcript (~3K tokens). Always in LLM context.
- **Tier 2 (WARM)**: Structured meeting summary, updated every ~2 min by compressing oldest HOT content. Topics, decisions, action items, sentiment shifts. Never exceeds ~4K tokens.
- **Tier 3 (COLD)**: SwiftData persistent store. Full meeting summaries, interlocutor profiles, action items. Only pulled into context when explicitly queried.
- **Q&A context budget**: Tier 1 + Tier 2 + targeted Tier 3 snippets = ~6-8K tokens max.

### Auto Meeting Detection Flow
```
MeetingAutoDetector (polls every 3s)
  ├── Strategy 1: AX API → read native app window titles
  │   Match against known patterns ("Meeting with...", "Zoom Meeting", etc.)
  ├── Strategy 2: AX API → read browser tab titles
  │   Match against "Google Meet", "Microsoft Teams", meeting URLs
  └── Strategy 3: EventKit → enrich with calendar data
      Add meeting title + scheduled attendee names

State machine: .idle ←→ .inMeeting(app, pid)
  idle → inMeeting: auto-start recording, show in menu bar
  inMeeting → idle: auto-stop recording, persist meeting data
```

## Tech Stack

| Component | Library/Framework | Source |
|-----------|------------------|--------|
| UI | SwiftUI + NSPanel (floating, tethered) | System |
| State | @Observable (Swift 5.9+) | System |
| Concurrency | Swift 6 strict concurrency | System |
| Audio capture | Core Audio Taps (CATapDescription) | System (macOS 14.4+) |
| Transcription | WhisperKit | SPM: argmaxinc/WhisperKit |
| Speaker diarization | SpeakerKit (WhisperKit) | SPM: argmaxinc/WhisperKit |
| LLM inference | mlx-swift-lm (MLXLLM + MLXLMCommon) | SPM: ml-explore/mlx-swift-lm |
| Screen OCR | ScreenCaptureKit + Vision | System |
| Persistence | SwiftData | System |
| Global hotkeys | KeyboardShortcuts | SPM: sindresorhus/KeyboardShortcuts |
| Meeting detection | Accessibility API + EventKit | System |
| File search | mdfind (Spotlight CLI) | System |
| Calendar | EventKit | System |
| Web search | DuckDuckGo API (optional) | REST |

## Data Models (SwiftData)

### Core Models
- **Interlocutor** — name, role, company, email, notes, firstSeen, voiceEmbeddings ([Data])
- **Meeting** — date, title, sourceApp, duration, summary, compressedTranscript (Data)
- **MeetingParticipation** — junction model linking Interlocutor ↔ Meeting with per-meeting stats: talkTime, talkPercent, interventionCount, avgSentiment, vocabularyComplexity, questionRatio, topicsRaised, keyStatements
- **Topic** — name, startTime, endTime, summary. Belongs to Meeting.
- **ActionItem** — description, dueDate, status (pending/done/overdue), extractedFrom quote. Belongs to Meeting + Interlocutor (owner).
- **TranscriptSegment** — in-memory Codable struct (not SwiftData). id, text, speakerLabel, speakerID, startTime, endTime, sentiment.

### Interlocutor Analytics (computed across MeetingParticipation records)
- Talk time % (avg and per-meeting trend)
- Attendance rate (% of shared meetings)
- Sentiment average and variance
- Vocabulary complexity (type-token ratio + avg word length)
- Question ratio (% of turns that are questions)
- Specificity score (vague vs concrete statements)
- Follow-through rate (action items completed vs assigned)
- Topic initiation frequency

## Project Structure (actual files)

```
MeetingHUD/
├── Package.swift                          ✅ SPM config, swift-tools-version 6.0
├── .gitignore                             ✅
├── CLAUDE.md                              ✅ This file
├── Resources/
│   ├── Info.plist                          ✅ LSUIElement, audio permissions
│   └── MeetingHUD.entitlements            ✅ Audio capture entitlements
└── Sources/MeetingHUD/
    ├── App/
    │   ├── MeetingHUDApp.swift             ✅ @main, MenuBarExtra, overlay panel
    │   └── AppState.swift                  ✅ @Observable @MainActor central state
    ├── Features/
    │   ├── Audio/
    │   │   ├── AlwaysOnCaptureManager.swift ✅ Energy-based VAD state machine for always-on mode
    │   │   ├── AudioCaptureManager.swift   ✅ Core Audio Tap + aggregate device + AVAudioEngine + level metering
    │   │   ├── MeetingAppDetector.swift    ✅ PID detection for meeting apps
    │   │   └── MeetingAutoDetector.swift   ✅ Auto-detect via AX + EventKit, triggers elevation
    │   ├── Overlay/
    │   │   ├── OverlayPanel.swift          ✅ NSPanel (borderless, floating)
    │   │   └── OverlayView.swift           ✅ Three-column HUD layout
    │   ├── Transcription/
    │   │   ├── TranscriptionEngine.swift   ✅ WhisperKit streaming + audio accumulation
    │   │   ├── SpeakerIdentifier.swift     ✅ Cosine similarity matching + SwiftData profile loading + auto-label
    │   │   ├── SpeakerDiarizer.swift       ✅ Post-meeting SpeakerKit diarization
    │   │   └── LiveSpeakerDiarizer.swift   ✅ Periodic live diarization during recording
    │   ├── Analysis/
    │   │   ├── AnalysisQueue.swift          ✅ Serial actor for GPU-bound LLM work
    │   │   ├── CommunicationMetrics.swift   ✅ Incremental vocabulary/question metrics
    │   │   ├── ContentTypeClassifier.swift  ✅ Detects content type (meeting/standup/news/podcast/etc.)
    │   │   ├── MeetingEngine.swift          ✅ Orchestrator: timer, watermarks, recommendations, summary
    │   │   ├── SentimentAnalyzer.swift      ✅ Batched LLM sentiment scoring
    │   │   ├── SignalDetector.swift          ✅ Action items + key statement extraction
    │   │   └── TopicExtractor.swift         ✅ Rolling-window topic detection with agenda
    │   ├── Persistence/
    │   │   └── MeetingPersistenceManager.swift ✅ SwiftData save, transcript compression, analytics
    │   ├── Profiles/
    │   │   └── SpeakerNamingSheet.swift    ✅ Post-meeting speaker naming UI
    │   └── LLM/
    │       ├── ChatMessage.swift           ✅ Multi-turn message model
    │       ├── LLMProvider.swift           ✅ Protocol for LLM backends
    │       ├── MLXModelInfo.swift          ✅ Model metadata + recommended list
    │       ├── MLXModelManager.swift       ✅ Discovery, download, load/unload, memory pressure
    │       ├── MLXProvider.swift           ✅ Streaming inference via MLXLLM
    │       └── PromptTemplates.swift       ✅ Sentiment, topic, compression prompts
    ├── Models/
    │   ├── ConversationSession.swift       ✅ SwiftData model (ambient/meeting/call sessions)
    │   ├── Interlocutor.swift              ✅ SwiftData model (with voice embeddings)
    │   ├── Meeting.swift                   ✅ SwiftData model
    │   ├── MeetingParticipation.swift      ✅ SwiftData model
    │   ├── Topic.swift                     ✅ SwiftData model
    │   ├── ActionItem.swift                ✅ SwiftData model
    │   └── TranscriptSegment.swift         ✅ In-memory struct
    └── Shared/
        ├── Theme.swift                     ✅ Colors, typography, materials
        ├── Constants.swift                 ✅ Timing, token budgets, audio format
        └── LLMJSONParser.swift             ✅ Robust JSON extraction from LLM output
```

Legend: ✅ implemented | 🟡 scaffolded with TODOs | ⬜ not started

### Planned files (not yet created)
```
    ├── Features/
    │   ├── Audio/
    │   │   └── AudioBufferProcessor.swift      ⬜ PCM buffer chunking
    │   ├── Overlay/
    │   │   ├── TetheredPanelManager.swift       ⬜ Dock to meeting window
    │   │   └── HUDWidgets/                      ⬜ Dedicated widget views
    │   ├── Analysis/
    │   │   ├── MeetingEngine.swift              ⬜ Orchestrates all pipelines
    │   │   ├── SentimentAnalyzer.swift          ⬜ Per-speaker mood
    │   │   ├── TopicExtractor.swift             ⬜ Topic detection
    │   │   ├── SignalDetector.swift             ⬜ Action items, risks
    │   │   └── CommunicationMetrics.swift       ⬜ Vocabulary, questions
    │   ├── Recommendations/
    │   │   ├── RecommendationAgent.swift        ⬜ LLM agent with tools
    │   │   └── AgentTools/                      ⬜ File, web, meeting, calendar
    │   ├── Chat/
    │   │   ├── ChatView.swift                   ⬜ Q&A panel
    │   │   └── VoiceInputManager.swift          ⬜ Voice commands
    │   ├── Profiles/
    │   │   ├── ProfileManager.swift             ⬜ CRUD + embedding match
    │   │   └── ProfileDetailView.swift          ⬜ Interlocutor dashboard
    │   ├── Memory/
    │   │   ├── MemoryManager.swift              ⬜ Three-tier orchestration
    │   │   ├── TranscriptCompressor.swift       ⬜ LLM summarization
    │   │   └── ContextBuilder.swift             ⬜ Assemble LLM context
    │   ├── ScreenContext/
    │   │   ├── ScreenCaptureManager.swift       ⬜ SCKit + Vision OCR
    │   │   └── AccessibilityReader.swift        ⬜ AX text extraction
    └── App/
        └── HotkeyManager.swift                 ⬜ KeyboardShortcuts config
```

## Build Phases

| Phase | Milestone | Key Deliverables | Status |
|-------|-----------|-----------------|--------|
| MVP | Audio → Transcript → HUD | Core Audio Tap, WhisperKit streaming, speaker labels, NSPanel | ✅ Done |
| v0.2 | Auto-detect + Profiles | Meeting auto-detection, speaker naming, SwiftData persistence | ✅ Done |
| v0.3 | Analytics | Sentiment, topics, talk-time, communication metrics, agenda, summary | ✅ Done |
| v0.4 | Always-On + UX | CaptureState machine, always-on VAD, chat drawer, copy transcript, silence gaps, proactive insights, voice embeddings, self-signed cert | ✅ Done |
| v0.5 | Voice Q&A | Voice commands, screen OCR | ⬜ |
| v0.6 | Search | File/web/meeting/calendar search tools | ⬜ |
| v0.7 | Cross-meeting | Profile dashboards, analytics trends | ⬜ |
| v0.8 | Polish | Tethered mode, themes, export, settings | ⬜ |

## What's Next (Priority Order)

### Immediate: Complete MVP Pipeline
1. **Core Audio Tap implementation** — Bridge the C API (CATapDescription, AudioHardwareCreateProcessTap). This is the hardest single piece. Reference: [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo, [AudioTee](https://github.com/makeusabrew/audiotee).
2. **WhisperKit integration** — Load model, feed PCM buffers, get streaming transcription with word timestamps. WhisperKit has good Swift API for this.
3. **Wire the pipeline** — AudioCaptureManager.audioStream → TranscriptionEngine → AppState.activeTranscriptSegments → OverlayView live update.
4. **Basic speaker labels** — Even before SpeakerKit, use channel separation or simple energy-based detection for "Speaker 1" / "Speaker 2".

### Then: Profiles + Persistence
5. **SpeakerKit integration** — Voice embeddings from SpeakerKit, cosine similarity matching in SpeakerIdentifier.
6. **Speaker naming UI** — When unknown speaker detected, show sheet/popover to name them.
7. **Profile persistence** — Save Interlocutor + MeetingParticipation to SwiftData at meeting end.

### Then: Intelligence Layer (MLX LLM ported, ready to use)
8. ~~**Port MLXProvider from Teleprompter**~~ — ✅ Done. MLXProvider, MLXModelManager, MLXModelInfo, PromptTemplates all ported.
9. **Sentiment analysis** — Run small LLM on transcript chunks per speaker. PromptTemplates.sentimentAnalysis ready.
10. **Topic extraction** — Detect topic shifts from transcript flow. PromptTemplates.topicExtraction ready.
11. **Three-tier memory** — HOT/WARM/COLD context management. PromptTemplates.transcriptCompression ready.

## Key Technical Decisions

- **Swift 6 strict concurrency** — Package uses swift-tools-version 6.0. All @Observable classes need @MainActor or explicit Sendable conformance.
- **SPM-only (no .xcodeproj yet)** — Open Package.swift directly in Xcode. Info.plist and entitlements are in Resources/ but NOT bundled as SPM resources (SPM forbids Info.plist as a resource). They'll be referenced when/if we create an .xcodeproj.
- **LSUIElement = true** — App runs as agent (menu bar only, no dock icon).
- **ANE + GPU split** — WhisperKit/SpeakerKit on Neural Engine, MLX LLM on GPU. No contention on Apple Silicon.
- **Accessibility permission required** — Meeting auto-detection reads window titles via AX API. One-time grant in System Settings → Privacy → Accessibility.

## Patterns Reused

### From Teleprompter (~/Developer/Teleprompter)
- **MLXProvider + MLXModelManager**: Model discovery (HF cache, LM Studio), download with progress, memory pressure monitoring, load/unload lifecycle.
- **LLMProvider protocol**: `stream(messages:) -> AsyncStream<String>`.
- **NSPanel overlay**: TeleprompterWindowController pattern.
- **GlobalShortcutManager**: NSEvent global monitor.
- **Context trimming**: Token counting + auto-trim at threshold.

### From Onit (github.com/synth-inc/onit)
- **Tethered panel mode**: Panel docks to target window, moves/resizes/hides with it via AX observer.
- **Accessibility text extraction**: Recursive AX element tree walk.
- **OCR via ScreenCaptureKit + Vision**: Capture window screenshot, VNRecognizeTextRequest.
- **Non-activating NSPanel**: `.nonactivatingPanel` style mask.

## Ideas & Future Possibilities

### Near-term
- **Meeting templates** — detect recurring meetings (same title/participants) and pre-load context from previous instances. "This is your 4th Sprint Planning with Maria and Carlos. Last time, Maria raised concerns about the migration timeline."
- **Action item tracking dashboard** — separate view showing all pending action items across meetings, filterable by person/due date/status.
- **Meeting export** — generate markdown/PDF summary with transcript, topics, action items, participant stats. Share-friendly format.
- **Notification on overdue items** — when a participant joins a meeting and has overdue action items, surface them immediately.

### Mid-term
- **Multi-language support** — WhisperKit supports translation to English. Detect language per speaker and translate in real-time for multilingual meetings.
- **Wispr Flow-style voice dictation** — not just Q&A, but voice-to-text anywhere on the system. Use WhisperKit + MLX LLM for cleanup pass (remove fillers, add punctuation). Hold hotkey → speak → polished text at cursor.
- **Screen share OCR intelligence** — when someone shares slides, OCR the content and feed it to the LLM. "What was on the slide about Q3 projections?" works even after they stopped sharing.
- **Meeting scoring** — rate meeting effectiveness: was there an agenda? Were decisions made? Did everyone participate? Score and trend over time.
- **Calendar integration (write)** — auto-create follow-up calendar events for action items with due dates.

### Long-term
- **Speaker emotional arc** — track sentiment over the full meeting as a timeline graph. Identify inflection points ("Maria's mood shifted negative when budget was discussed").
- **Cross-meeting relationship graph** — visualize who meets with whom, how often, about what topics. Social network analysis of your meeting life.
- **Automated follow-up emails** — draft a follow-up email summarizing decisions and action items, addressed to the right people, ready to send.
- **Fine-tuned sentiment model** — instead of using general LLM, fine-tune a small model on meeting transcript sentiment specifically. Faster, more accurate.
- **Meeting prep briefing** — before a scheduled meeting, auto-generate a briefing: who's attending, their profiles, recent topics with them, pending action items, relevant files you've been working on.
- **Integration with project management** — create Jira/Linear/GitHub issues directly from detected action items.

### Experimental
- **Tone coaching** — real-time feedback on your own communication style. "You've been interrupting more than usual" or "Your pace is faster than normal, consider slowing down."
- **Argument detection** — detect when a discussion becomes heated and suggest de-escalation.
- **Decision confidence scoring** — when a decision is made in a meeting, assess how confident/committed the group seems based on language analysis.

## Development Notes
- Target: macOS 15+ (Core Audio Taps require 14.4+, SwiftData requires 14+)
- Min hardware: Apple Silicon M1 (8GB uses Llama 3.2 1B; 16GB+ uses 3B)
- WhisperKit runs on ANE, MLX LLM runs on GPU — no contention
- All data stays local. No telemetry. No cloud APIs required (web search is optional and toggleable).
- Recommendation agent triggers on events (topic shift, speaker change, idle), not fixed timer
- Accessibility permission needed for meeting detection (window titles) and tethered mode
- Audio capture permission needed for Core Audio Taps (one-time grant)
- Calendar permission needed for EventKit meeting enrichment
