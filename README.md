# Mumble

Free, private push-to-talk dictation for the Mac. A home-made alternative to Wispr Flow.

Hold a shortcut or a mouse button, speak, let go, and the text goes into the box you were typing in. Speech is
recognised on your Mac by Apple's on-device engine, then tidied by Apple Intelligence's on-device model:
fillers go, spoken corrections ("no wait, Friday") are applied, spoken punctuation ("new paragraph", "full
stop") becomes the real thing, and capitals and punctuation are fixed. It takes about a quarter of a second.

- **Nothing leaves your Mac.** No account, no server, no subscription, no API keys.
- **Works in any app** that has a text box.
- **Free.** MIT licence.

It opens at login and runs in the background. The menu bar icon is there for Settings and Quit, and the Dock
icon opens Settings (turn it off with **Show in Dock** in Settings).

## What you need

- A Mac with Apple silicon on **macOS 26 (Tahoe)** or later.
- **Apple Intelligence** turned on (System Settings › Apple Intelligence & Siri) for the cleanup. Without it,
  the text goes in as you said it.
- **Xcode** 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and install

```bash
git clone https://github.com/revilo-digital/mumble-app.git
cd mumble-app
./scripts/install.sh
```

This builds a Release copy, installs it to `/Applications` and opens it. On first launch it asks for the
microphone, speech recognition and Accessibility (to put the text in).

If you're signed in to Xcode with an Apple ID (Xcode › Settings › Accounts), the app is signed with your Apple
Development certificate, so macOS remembers those permissions when you rebuild. Without one it's signed to run
locally, and you'll be asked again after each install. If macOS says Accessibility is already on but it still
doesn't work, remove Mumble from the list in System Settings › Privacy & Security › Accessibility and add it
again.

## Tests

```bash
xcodegen generate && xcodebuild test -project Mumble.xcodeproj -scheme Mumble -destination 'platform=macOS,arch=arm64'
```

`AppleTranscriberTests` runs Apple's real speech engine on a clip made with `say`. `AppleCleanerTests` runs
the real cleanup model on spoken-style examples and prints each result and its time (skipped while Apple
Intelligence is off). The rest use fakes, so no microphone is needed.

## Using it

- **Push to talk:** hold a shortcut (⌃⌥M to start with), a mouse button or fn while you speak, then let go.
- **Hands-free:** double tap any of those, speak, then press it again (or click ✓) to insert. Tap, then hold,
  and it's push to talk again. You can also add one-press hands-free shortcuts.
- **A modifier key on its own:** in Settings, **Add Modifier Key** offers fn, ⌃, ⌥, ⌘ and ⇧ (either side, or
  only the right-hand one). Shortcuts and capitals still work: pressing anything else with it cancels.
  - fn starts listening straight away. In System Settings › Keyboard, set "Press 🌐 key to" to **Do
    Nothing**, or macOS opens emoji or switches language when you let go.
  - ⌃ ⌥ ⌘ ⇧ start once held for a quarter of a second, so ⌘C or a capital letter never starts listening.
    Double tap one for hands-free.
- **Custom words** (Settings): names and terms spelled your way. They're fixed even when said in pieces
  ("bright CRM" becomes BrightCRM). If Mumble hears one as something else ("Tooey group" for Tui Group),
  add that under **Also heard as**; **Last heard** shows what the last dictation came out as.
- **✕ or Esc** cancels. Nothing is inserted.
- Music, videos and calls are muted while you talk, and come back when you finish. Turn this off in
  Settings › General.
- In Settings, each of these can have as many shortcuts and mouse buttons as you like: **Add Shortcut** or
  **Add Mouse Button**, then press it. Middle, back, forward and extra mouse buttons work. In Logi Options+,
  leave that button on its normal action (Middle click, Back or Forward), or Mumble won't see it. Its clicks
  no longer reach other apps, so Back won't also go back a page.

While it's listening, a small black widget sits at the bottom of the screen. Its dots move with your voice.

## How the text gets in

1. When you press the shortcut, Mumble remembers the focused text box (through Accessibility).
2. When the text is ready, it's put straight into that box, even if you've clicked somewhere else since.
3. If the box doesn't accept that (some Electron apps and browser fields), Mumble pastes with ⌘V and puts your
   clipboard back half a second later. It only pastes if that box is still the one in front.
4. If neither is safe, the text is copied and the widget says "Copied, press ⌘V".

## Logs

```bash
/usr/bin/log stream --predicate 'subsystem == "nz.olly.Mumble"' --info --style compact
```

Each dictation logs how long it took from letting go to the text going in, and how it was inserted.

## How it's built

SwiftUI menu bar app, Swift 6. Speech uses `SpeechAnalyzer`/`SpeechTranscriber`, cleanup uses the Foundation
Models framework, and shortcuts use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
`CLAUDE.md` has the design decisions and why.

## Licence

MIT. See [LICENSE](LICENSE).
