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
  then; the controller also gives up 10 s after letting go.
- **Muting:** `SystemSoundMuter` mutes the default output (or sets its volume to 0) on start and restores it
  in `stopListening`, only if it changed it. It saves what it changed (`mutedOutput`) and restores at launch.
- **Idle cost:** the widget's view renders nothing while idle, or its animated dots redraw off screen.
- **Speech:** `Transcriber` protocol. `AppleTranscriber` uses `SpeechTranscriber`/`SpeechAnalyzer` (macOS 26)
  with the `.transcription` preset, locale from `supportedLocale(equivalentTo: .current)` (en_GB here). Audio
  streams in while the user talks. The SDK is macOS 27; the deployment target is 26.0, so don't use APIs
  marked `anyAppleOS 27`. Check the SDK's `Speech.swiftinterface` rather than memory.
- **Cleanup:** always runs, for every dictation. No skip rule and no "raw only" apps. `AppleCleaner` uses
  Foundation Models (Apple Intelligence) with `permissiveContentTransformations` guardrails, greedy sampling
  and a capped reply length, a fresh session per dictation, prewarmed on start. The prompt is
  `App: X / Transcript: … / Edited:` with worked examples in the instructions; that beat rules by a long way
  (rules alone and it answers questions, writes poems and code). Don't tell it "this is a code editor": it
  then writes code. The controller races it against a 4 s timeout; failures, timeouts and `DriftCheck`
  rejections (any new content word, much longer or shorter) insert the raw text, and fillers alone insert
  nothing. `AppleCleanerTests` run the real model on examples (skipped while Apple Intelligence is off) and
  print each result and its time: rerun them after any prompt change.
- **Inserting:** capture the focused AX element on shortcut down. Insert with `kAXSelectedTextAttribute` and
  verify via `kAXValueAttribute`. Otherwise paste with ⌘V only if that same element is still focused, and
  restore the clipboard. Otherwise copy and say "Copied, press ⌘V". Never insert into a different box or a
  secure field.
- **Widget:** non-activating `NSPanel` that can't become key, so clicking ✕/✓ never steals focus.
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
