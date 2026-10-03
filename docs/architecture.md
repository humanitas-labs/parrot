# Architecture

Last updated: `2026.09.28`

> This document is the target structure. Contributors and agents working on an issue read it first: it says where each kind of change belongs, so parallel work composes instead of colliding.

Parrot is a macOS menu-bar dictation app. Hold a key, speak, release, and the transcript appears at the cursor. Everything runs on the Mac: audio and text never leave it.

## Contents

1. [Goals and non-goals](#1-goals-and-non-goals)
   - [1.1 — Goals](#11--goals)
   - [1.2 — Non-goals](#12--non-goals)
2. [Targets](#2-targets)
3. [Layout](#3-layout)
4. [The dictation loop](#4-the-dictation-loop)
   - [4.1 — Flow](#41--flow)
   - [4.2 — Extension points](#42--extension-points)
5. [Settings](#5-settings)
6. [Files on disk](#6-files-on-disk)
7. [Startup and failure](#7-startup-and-failure)
8. [Rules](#8-rules)
9. [Permissions](#9-permissions)
10. [Decision log](#10-decision-log)

## 1. Goals and non-goals

### 1.1 — Goals

1. **Push-to-talk dictation into any app.** Hold a hotkey, speak, release, and the text lands in the focused field.
2. **On-device.** No network calls for transcription. Audio never leaves the machine.
3. **Minimal surface.** A menu-bar item, a small recording pill, and one settings window. No dock icon, no main window.
4. **Your words.** A custom dictionary biases the model toward the names and terms you use, and fixes what it still gets wrong.
5. **Trustworthy by construction.** Transcript text is never written to logs or disk. The app is signed and notarized, so permissions survive updates.
6. **Pluggable engines.** Whisper (WhisperKit) today, Parakeet and Apple SpeechAnalyzer behind the same protocol.

### 1.2 — Non-goals

- Cross-platform. Parrot depends on CoreML and the Apple Neural Engine.
- Cloud transcription providers.
- Transcript history or search. Stats keep counts only.
- Meeting recording and diarization. They may come later as a separate mode.

## 2. Targets

```
Package.swift
  ParrotCore      library     all behaviour: capture, hotkey, transcription, pipeline, settings, UI
  parrot          executable  thin entry point: ArgumentParser commands that call into ParrotCore
  ParrotTests     tests       unit tests against ParrotCore
```

`Parrot.app` wraps the `parrot` executable in a signed bundle. The same binary runs as the app (launched by `SMAppService` or from Finder) and as the CLI (through a symlink). Launching with no subcommand runs the dictation loop.

The executable holds no logic beyond parsing flags and calling ParrotCore. Anything worth testing lives in ParrotCore.

## 3. Layout

```
Sources/ParrotCore/
  App/
    DictationController.swift   the dictation loop: gesture → capture → transcribe → process → deliver
    DictationObserver.swift     observer protocol and DictationResult (counts and timings, never text)
    LatencyLog.swift            one log line per dictation: press-to-first-sample, release-to-text and each stage, as a DictationObserver
    Startup.swift               startup checks and StartupFailure (permanent vs transient)
    Permissions.swift           Accessibility and Microphone state, and what each Allow button asks for (pure, tested)
    Onboarding.swift            when the onboarding window shows, its menus, and what Get Started saves (pure, tested)
    Daemon.swift                the `run` command: startup, wiring, run loop
    ModelSwitcher.swift         a model change while running: loads the new model behind the menu bar, swaps it in between dictations
    Updater.swift               Sparkle auto-update, started only in the app role
    AppLaunch.swift             the app role: bundle detection, single instance, migration off the old LaunchAgent
    LoginItem.swift, CommandLineLink.swift
                                launch at login (SMAppService) and the `parrot` symlink into the bundle
    Setup.swift, Doctor.swift, ModelCommands.swift
                                bodies of the other commands
  Support/
    Paths.swift                 every on-disk location Parrot uses
    Log.swift                   stderr logging; never logs transcript text
    SilentExit.swift            "message printed, exit with this code", so ParrotCore needs no ArgumentParser
  Settings/
    Settings.swift              Codable settings value with defaults
    SettingsStore.swift         load, atomic save, file watching, change publishing
  Input/
    HotkeyMonitor.swift         CGEventTap for modifier changes only
    Gesture.swift               press/release filtering: short-tap discard, chord cancel (pure, tested)
    FocusSnapshot.swift         what was focused, whether it is secure, its selection range, and the character before the cursor
    Delivery.swift              inject, copy or discard, from the focus at start and at delivery (pure decision, tested)
    Spacing.swift               the spaces around a transcript: always after, before when the text there needs it (pure, tested)
    TextInjector.swift          delivery into the focused field (paste or typed Unicode)
  Audio/
    AudioCapture.swift          capture: permission and device checks, format conversion, per-capture stats
    CaptureInput.swift          CaptureMode and the protocol each way of running the mic implements
    EngineInput.swift           the AVAudioEngine input, fresh per press (`--capture engine`, the default before #52)
    HALInput.swift              the Core Audio AUHAL input unit (default), per press or prepared between presses, and the device watcher
    HostClock.swift             host time in nanoseconds, to compare a press with Core Audio buffer timestamps
    SilenceTrimmer.swift        cuts leading and trailing silence before transcription (pure, tested)
  Transcription/
    Transcriber.swift           protocol and TranscriptionContext
    TranscriberTimings.swift    where a transcription spent its time, per stage
    WhisperKitTranscriber.swift
    WhisperTuning.swift         compute units and decoding options, each measured with `parrot-bench transcription`
    SpokenLanguage.swift        the language each dictation decodes in: the setting, or detection among the user's languages (pure, tested)
    LanguageDetector.swift      Whisper's language detection with only the user's languages competing
    ModelRegistry.swift, TranscriptionModel.swift, ModelStore.swift
  Pipeline/
    Transcript.swift            the value that flows through processing
    TranscriptProcessor.swift   protocol for post-transcription steps
  Dictionary/
    Dictionary.swift            the user's terms, replacements, and example sentences; the plain-text table's parser and writer
    DictionaryStore.swift       loads the `dictionary` file, reloads on change, accepts dotfiles symlinks
    DictionaryMigration.swift   converts the old dictionary.json once at startup; its examples move to settings.json
    LegacyDictionary.swift      the old JSON parser, used only by the migration
    DictionarySettings.swift    the example sentences, one per language, in settings.json
    DictionaryProcessor.swift   the replacement pass
    DictionaryContext.swift     the example sentence for the active language, as the prompt
  Stats/
    StatsRecorder.swift         counts only, as a DictationObserver
  UI/
    MenuBarController.swift
    RecordingOverlay.swift
    OnboardingWindow.swift      hotkey, languages and both permissions on one page; follows the grants live
    SettingsWindow.swift        the Settings window: header, General and Transcription on one page, laid out by hand
    Pill.swift                  the pill buttons and menus, bird and language checklist shared with the onboarding window
    Sections/                   one view per settings section

Sources/parrot/
  main.swift                    ArgumentParser commands: run, setup, doctor, models, install

Sources/parrot-bench/           developer benchmarks, never shipped in Parrot.app (`swift run -c release parrot-bench …`)
  main.swift                    ArgumentParser commands: transcription, capture
  TranscriptionBench.swift      the model over a folder of recordings: median and p90 per stage, word error rate
  CaptureBench.swift            press-to-first-sample, cold and warm, per capture mode
  InputActivity.swift           whether this process, or any, is running the input (checks the mic is off between presses)

Tests/ParrotTests/
Tests/ParrotBenchTests/
```

ParrotCore types the benchmarks need are marked `package`, visible to the package's own targets but not public API; nothing is made `public` for a benchmark.

Files that do not exist yet are created by the issue that needs them. The layout says where they go.

## 4. The dictation loop

### 4.1 — Flow

```
HotkeyMonitor ──flags──▶ Gesture ──start/stop──▶ DictationController
                                                     │
                                  start: FocusSnapshot + AudioCapture.start
                                  stop:  AudioCapture.stop → [Float]
                                                     │
                                                     ▼
                              Transcriber.transcribe(audio, context)
                                  context = language + prompt (from Dictionary)
                                                     │ Transcript
                                                     ▼
                              [TranscriptProcessor] in order
                                  DictionaryProcessor, later others
                                                     │ Transcript
                                                     ▼
                              delivery: paste at the cursor if focus is unchanged,
                                        with a trailing space, and a leading one if needed;
                                        clipboard if focus moved; discard in a password field
                                                     │
                                                     ▼
                              DictationObservers: overlay, menu bar, stats, latency log
```

`DictationController` owns the state machine (`idle`, `recording`, `transcribing`) and nothing else. It is `@MainActor`. Transcription runs off the main actor; the controller awaits it.

Delivery also treats a changed cursor position or selection within the same
focused element as focus drift when both snapshots expose the selected range.
It uses the existing clipboard fallback rather than inserting at the changed
destination. Snapshot capture reads range metadata, never field text, and skips
the range for secure fields. Missing ranges retain the existing delivery policy;
this does not detect edits that leave the same selection range.

### 4.2 — Extension points

Features plug in at one of these points. They do not add branches to `DictationController`.

| Point | Shape | Used by |
|---|---|---|
| `TranscriptionContext` | value passed to `transcribe`: language, prompt text | dictionary prompting, language |
| `TranscriptProcessor` | `func process(_ transcript: Transcript) -> Transcript`, synchronous, pure where possible | dictionary replacements; future cleanup passes |
| Delivery decision | chooses injector or fallback from the `FocusSnapshot` and the result | secure fields and focus drift |
| Delivery spacing | `Spacing.spaced`: a trailing space always, a leading one when the text before the cursor needs it | a space between dictations |
| `DictationObserver` | `dictationStarted`, `dictationTranscribing`, `dictationFinished(DictationResult)`, `dictationFailed`; each has an empty default | overlay, menu bar, stats, latency |
| `Settings` sections | a field in `Settings` plus a view in `UI/Sections/` | hotkey, model, language, dictionary editor, input device, stats |

## 5. Settings

One file: `~/.config/parrot/settings.json` (or `$XDG_CONFIG_HOME/parrot/`), a `Codable` `Settings` value. A missing key takes its default. Writes are atomic. `SettingsStore` watches the directory, so hand edits apply live, and a file that fails to parse keeps the last good settings and logs one line.

Subsystems observe the settings they care about and reconfigure themselves. Launch at login carries no settings. CLI flags override a single foreground run and are never persisted.

## 6. Files on disk

Every location comes from `Paths`. No other code builds a path.

| Location | Contents |
|---|---|
| `~/.config/parrot/` | `settings.json`, `dictionary` (a plain-text table; see [dictionary.md](dictionary.md)): what the user edits and may keep in dotfiles. `$XDG_CONFIG_HOME/parrot/` when that is set |
| `~/Library/Application Support/parrot/` | `models/`, `stats.json`: downloaded data and machine state |
| `~/Library/Logs/parrot/` | daemon logs, owner-only; timings and lengths, never transcript text |
| `~/Library/Caches/parrot/` | `--dump-wav` debug captures, owner-only |

Uninstall removes logs and caches. It leaves config and models, so a reinstall keeps the dictionary and does not download the models again.

## 7. Startup and failure

`Startup` runs its checks before loading a model: microphone authorization and the selected model id. Each failure is a `StartupFailure` with `isPermanent`: denied microphone, an unknown model, and no registered models are permanent; failed checks and an unavailable hotkey are not. A permanent failure prints one actionable message (a dialog when running as the app) and exits 0. Anything else exits nonzero. This rule lives in one place, `Run` in `main.swift`.

Everything after the checks happens behind the menu-bar icon, so the app is never invisible: the model loads (downloading on first run) with "loading model…" in the menu, a failed load retries with backoff instead of exiting, and the hotkey starts once the model is ready and Accessibility is granted. Launch at login is an `SMAppService` login item, which does not relaunch a crashed app, so the app avoids exiting over anything it can wait out.

## 8. Rules

1. Never write transcript text to logs, disk, or stats. The dictionary is the only user-authored text Parrot stores.
2. Every on-disk location comes from `Paths`.
3. Every persistent preference lives in `Settings` and changes through `SettingsStore`. No `UserDefaults`, no plist flags. The one exception is state Sparkle owns (last check time, the user's auto-install choice), which Sparkle keeps in the `com.humanitas.parrot` defaults domain.
4. New behaviour after transcription is a `TranscriptProcessor` or a `DictationObserver`, not an edit to `DictationController`.
5. Pure logic (gesture recognition, replacement pass, settings decoding, stats aggregation) has unit tests in `ParrotTests`.
6. The event tap listens to `flagsChanged` only.
7. Shared types are extended, not reshaped. A feature adds its settings to its own `…Settings` struct in its own folder, fills existing fields of `TranscriptionContext`, and uses existing `StartupFailure` cases. Adding a field or case to a shared type is fine; renaming or restructuring one needs its own change.

## 9. Permissions

Parrot needs Microphone and Accessibility. macOS keys both grants to the app's code identity. With a Developer ID signature and a stable bundle identifier, grants survive updates. With an ad-hoc signature, each new build is a new identity, and the grant silently stops applying. That is why the signed bundle matters, and why `scripts/dev-install.sh` signs local builds with the Developer ID certificate.

A grant belongs to the process that asked: `parrot setup` grants the terminal, which covers foreground runs, but the launch-at-login daemon needs its own. So the daemon asks for itself. Without Accessibility it keeps running with "grant Accessibility to start" in the menu bar and starts the hotkey as soon as the grant appears; it never exits over it, because an exit would either leave the user with nothing running or, under a relaunching supervisor, re-fire the prompt.

Parrot.app never shows a system prompt unannounced. At launch it opens the onboarding window (`UI/OnboardingWindow.swift`) until the user has been through it once, and afterwards while either grant is missing. One page sets the hotkey and the languages the user speaks, and lists both permissions, each with its own Allow button: the microphone prompt (or the Microphone pane once denied), and the Accessibility prompt with its pane, so the two system prompts never stack. Get Started saves the hotkey and languages, moves an English-only model to multilingual Small when another language is ticked, and sets `onboarding.completed`; closing the window sets the flag without saving. The rules are in `App/Onboarding.swift`, pure and tested. "Grant Permissions…" in the menu bar reopens the window while a grant is missing. A foreground `parrot run` has no window: it shows the Accessibility prompt once when it starts the hotkey and requests an undecided microphone at startup.

## 10. Decision log

Architecture decisions are recorded in [`decisions/`](decisions/). Each says what was decided, what was rejected and why, and when to revisit it.

| ADR | Decision |
|---|---|
| [001](decisions/001-core-library-and-extension-points.md) | Core library and extension points |
| [002](decisions/002-settings-file.md) | Config in `~/.config/parrot`, data in Application Support |
| [003](decisions/003-push-to-talk-on-a-modifier.md) | Push-to-talk on a single modifier key |
| [004](decisions/004-local-data-and-privacy.md) | Local data and privacy |
| [005](decisions/005-signed-app-identity.md) | Signed app identity |
