# Mumble

Push-to-talk dictation app for macOS (replaces Wispr Flow). See README.md for what it does and how to use it.

## Key decisions

- **Background app:** `LSUIElement`, opens at login (`SMAppService.mainApp`, on at first launch). No main
  window. "Show in Dock" (on by default, `DockIcon`) switches the activation policy to `.regular` at
  launch; clicking the Dock icon opens Settings. The menu bar icon stays either way. The app icon is drawn
  to match the widget (black rounded square, white waveform).
- **Triggers:** `ShortcutStore` keeps a list of `ShortcutBinding`s (saved as `shortcuts` JSON), each a key
  or mouse binding for `TalkAction.pushToTalk` or `.handsFree`. Key bindings are dynamic `KeyboardShortcuts`
  names (the first is `.talk`, default ⌃⌥M, so older settings carry over). Mouse bindings go to
  `InputListener`, a `CGEvent` tap (on its own thread, so typing never waits on the main thread) on
  other-mouse down/up, flagsChanged and keyDown. It swallows the chosen mouse buttons' clicks (macOS
  numbering: 2 middle, 3 back, 4 forward). Modifier keys on their own (`Kind.modifier`, `ModifierKey`:
  fn, ⌃ ⌥ ⌘ ⇧, either side or right only; old saved `"fn"` kinds still decode) are watched, never
  swallowed. Held keys come from the event's device-dependent flag bits each time. A key, another modifier
  or a click while one is held calls `interrupt()`. fn sends normal presses; ⌃ ⌥ ⌘ ⇧ go to
  `modifierDown/Up()`, which only starts after a 0.25 s hold (two clean taps go hands-free), so ⌘C and
  capitals never start the microphone. One key or button does one thing; recording it again moves it.
  Push to talk: hold to talk; a press under 0.35 s is a tap. A lone tap is dropped after 0.4 s; a double tap
  goes hands-free until the next press or ✓. Hands-free shortcuts: press to start, press again to finish
  (a press within 0.5 s of starting is ignored, so a double tap doesn't stop it). Tap to lock, hold to
  talk, like Wispr Flow's fn: if the press that locks hands-free (a double tap's second press, or a
  hands-free shortcut) is held past 0.35 s, letting go finishes instead.
- **Custom words:** `CustomWords` (saved as `customWords` JSON), each with optional "heard as" spellings.
  `CustomSpelling.apply` runs before and after cleanup: it matches the same letters split by spaces or
  hyphens ("bright C R M" → BrightCRM) or a heard-as spelling. Tested on macOS 26: `SpeechTranscriber`
  and `DictationTranscriber` both ignore `AnalysisContext.contextualStrings`, and listing the words in the
  cleanup prompt makes the model worse, so neither is relied on (hints are still passed to the engine).
  Settings shows "Last heard" (memory only) so the user can see what to add as heard-as.
- **Never stuck working:** Apple's analyser never finishes with no audio, so `AppleTranscriber` skips it
  then; the controller also gives up 10 s after letting go, plus 0.25 s for each second talked. Whisper gets 6 s plus 0.15 s a second (`SpeechRouter.whisperLimit`), then Apple's text is used: an 88 s dictation took it 10.08 s while another app used the GPU, and was lost.
- **Microphone:** chosen in Settings (`microphone` = device UID, "" for Automatic, which follows Sound
  settings). `MicrophoneChoice.pick` runs at every start. A MacBook's built-in mic records pure silence with
  the lid closed (it stays the default input), so then another non-virtual mic is used, even over a chosen
  built-in one. An unplugged choice falls back to Automatic.
- **Recording:** `Microphone` uses a Core Audio input unit (AUHAL, input only, mono float at the device's
  rate) bound to the device before it starts. Not `AVAudioEngine`: it starts on the default devices (an
  aggregate when input and output differ), switching it failed with 'nope' and once hung the main thread for
  good (2026-11-17). Each recording opens and closes on its own queue, so the main thread never waits on Core
  Audio and a stuck device can't block the next recording. Failures come back through `onFailure`, and the
  controller gives up with "Can't use the microphone" if no sound arrives within 3 s.
- **Muting:** `SystemSoundMuter` mutes the default output (or sets its volume to 0) on start and restores it
  in `stopListening`, only if it changed it. It saves what it changed (`mutedOutput`) and restores at launch.
  The Core Audio calls run in order on its own queue, never on the main thread.
- **Idle cost:** the widget's view renders nothing while idle, or its animated dots redraw off screen.
- **Speech:** `Transcriber` protocol (`transcribe(_:hints:session:)`; `TranscriptionSession` carries the context in
  and the engine used out). `AppleTranscriber` uses `SpeechTranscriber`/`SpeechAnalyzer` (macOS 26)
  with the `.transcription` preset, locale from `supportedLocale(equivalentTo: .current)` (en_NZ on the author's Mac). Audio
  streams in while the user talks. The SDK is macOS 27; the deployment target is 26.0, so don't use APIs
  marked `anyAppleOS 27`. Check the SDK's `Speech.swiftinterface` rather than memory.
- **Whisper:** Settings › Speech Engine chooses Whisper (the default: it downloads at first launch) or Apple (`speechEngine`). `WhisperEngine` runs WhisperKit
  (argmax-oss-swift) large-v3 turbo 632 MB from `~/Library/Application Support/Mumble/Whisper`, downloaded from
  Settings. `SpeechRouter` uses Whisper only when chosen and loaded, and runs Apple alongside: Apple's text is used
  if Whisper fails, and if Apple heard nothing nothing goes in (Whisper invents "Thank you." from silence).
  Whisper gets a prompt (`SpeechContext.prompt`): custom words, the cleaned window title, dictations from the last
  15 min in the same app or 2 min in another, and the text before the cursor. The first load on a Mac takes about 4 min
  (Neural Engine set-up, then cached: later launches take about 3 s); Apple is used until then. Mumble's memory
  footprint with it loaded is about 90 MB (the model is memory-mapped). Recordings save which engine ran and what Apple heard.
  Tested on real recordings (2026-11-19): only Whisper got an uncommon name right; Parakeet was fastest but least accurate.
- **Cleanup:** always runs, for every dictation. No skip rule and no "raw only" apps. `Fillers.remove` takes
  out um/uh/er first, in code: the transcriber already punctuates ("Um... key?"), and the model leaves
  punctuated text as it is. `AppleCleaner` uses
  Foundation Models (Apple Intelligence) with `permissiveContentTransformations` guardrails, greedy sampling
  and a capped reply length, a fresh session per dictation, prewarmed on start. The prompt is
  `App: X / Transcript: … / Edited:` with worked examples in the instructions; that beat rules by a long way
  (rules alone and it answers questions, writes poems and code). Don't tell it "this is a code editor": it
  then writes code. The controller races it against a 4 s timeout; failures, timeouts and `DriftCheck`
  rejections (any new content word, much longer or shorter, or the same words with at least half their full stops gone: it sometimes hands the unpunctuated input back) insert the raw text (fillers still removed),
  and fillers alone insert nothing. `AppleCleanerTests` run the real model on examples (skipped while Apple Intelligence is off) and
  print each result and its time: rerun them after any prompt change. The model gets the transcript without
  the engine's punctuation and sentence capitals (`AppleCleaner.unpunctuate`): punctuated, it treats the
  text as already edited and leaves "New paragraph." and "Actually, no" in. Tried on 2026-11-09, scored on
  the 32 examples: unpunctuated and lowercased 31, as heard 29, examples as earlier transcript turns 27,
  guided generation (`@Generable`) 25 (it copies the input). Adding or swapping prompt examples fixed one
  case and made it answer others ("tell me a joke"). Cases it still gets wrong are `gap:` known issues. A correction that refers back past a sentence ("use the tag. Is that right? Sorry, their app.") is beyond it: adding an example for it (2026-11-20) dropped the score from 32 to 29 of 35 (it answered "tell me a joke" and summarised).
  `PrivateCloudComputeLanguageModel` (Apple's bigger model) is macOS 27 only.
- **Inserting:** capture the focused AX element on shortcut down. Insert with `kAXSelectedTextAttribute` and
  verify via `kAXValueAttribute`. Otherwise paste with ⌘V only if that same element is still focused, and
  restore the clipboard. Otherwise copy and say "Copied, press ⌘V". Never insert into a different box or a
  secure field. AX calls time out after 1 s (macOS's default is 6), so a busy app can't freeze Mumble.
- **Carrying on:** `Continuation.fit` uses the text before the cursor (read after the microphone starts): after a
  word or comma the first word goes lower case unless it's "I", has capitals inside, is a custom word, isn't in the
  spell checker in lower case (names, days) or `NLTagger` calls it a name; after `.!?` or a new line it gets a
  capital; a space is added if needed. Chromium browsers only expose web pages after `AXEnhancedUserInterface` is set
  (they ignore Electron's `AXManualAccessibility`), so the first dictation after the browser opens misses.
- **Widget:** non-activating `NSPanel` that can't become key, so clicking ✕/✓ never steals focus.
- **Recordings:** Settings → "Keep recordings" (`keepRecordings`, off by default) saves the newest 50 dictations
  in `~/Library/Application Support/Mumble/Recordings` (16 kHz WAV plus JSON: app, window title, text before
  the cursor, what was heard and inserted; add `"meant"` by hand to score). `scripts/bench/setup.sh` sets up
  Whisper (WhisperKit) and Parakeet (FluidAudio) in `~/Library/Caches/MumbleBench`; `scripts/bench/compare.py`
  runs the recordings through each engine and writes `comparison.html`. Whisper's first model load on the
  Neural Engine takes about 3.5 minutes, every time from the command line.
- **Privacy:** nothing leaves the Mac by default.

## Conventions

- SwiftUI, XcodeGen `project.yml`, Swift 6, Swift Testing, `scripts/install.sh`.
- Interface text is plain and short, in NZ English.
- Signed to run locally in `project.yml`. `scripts/install.sh` signs with the Apple Development certificate
  when there is one, so TCC permissions survive rebuilds. Never commit a team ID.
- Tests use fakes (`FakeSystem`, `FakeClipboard`, `FakeMicrophone`, `FakeTranscriber`) so the whole path runs
  without hardware. Tests share the app's real UserDefaults (the test host is the app), so never set
  KeyboardShortcuts in tests; use a suite `UserDefaults` for `ShortcutStore`.

## Commands

- Install: `./scripts/install.sh`
- Test: `xcodegen generate && xcodebuild test -project Mumble.xcodeproj -scheme Mumble -destination 'platform=macOS,arch=arm64'`
