import Foundation
import Observation

enum DictationPhase: Equatable {
    case idle
    case listening
    case working
    case notice(String)
}

/// Runs one dictation at a time: shortcut down → listen → shortcut up → text into the box.
@MainActor
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    /// Microphone loudness, 0…1, for the widget.
    private(set) var level: Float = 0
    /// Seconds from letting go to the text being inserted, for the last dictation.
    private(set) var lastTiming: TimeInterval?

    /// A press shorter than this is a tap: on its own it does nothing, and two in a row go hands-free.
    static let quickPress: TimeInterval = 0.35
    /// A hands-free shortcut pressed again this soon is a double tap, not "stop".
    static let earliestStop: TimeInterval = 0.5

    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let microphone: any AudioSource
    /// Mutes other sound while listening.
    @ObservationIgnored private let muter: (any SoundMuter)?
    /// Tidies every transcript before it goes in.
    @ObservationIgnored private let cleaner: (any Cleaner)?
    /// Raw text goes in if the cleanup takes longer than this.
    @ObservationIgnored private let cleanupTimeout: Duration
    @ObservationIgnored private var cleanupContext = CleanupContext()
    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let noticeDuration: Duration
    /// How long after a tap to wait for the second one.
    @ObservationIgnored private let doubleTapWindow: Duration
    /// Gives up if the text still isn't ready this long after letting go.
    @ObservationIgnored private let finishTimeout: Duration
    /// How long ⌃ ⌥ ⌘ ⇧ must be held on their own before listening starts.
    @ObservationIgnored private let modifierHold: Duration
    /// Starts listening once a modifier key has been held long enough, so tests can wait for it.
    @ObservationIgnored private(set) var pendingHold: Task<Void, Never>?
    /// When a modifier key was last tapped on its own, to spot a double tap.
    @ObservationIgnored private var lastModifierTap: Date?
    /// This dictation was started by a modifier key, so letting go of it finishes.
    @ObservationIgnored private var startedByModifier = false
    /// Asked before listening; shows setup if the microphone isn't allowed.
    @ObservationIgnored var canUseMicrophone: () -> Bool = { true }
    /// The user's custom words, read at the start of each dictation.
    @ObservationIgnored var customWords: () -> [CustomWord] = { [] }
    /// What the speech engine heard last time, before any fixing, so the user can add "heard as" spellings.
    private(set) var lastHeard: String?
    @ObservationIgnored private var dictationWords: [CustomWord] = []
    @ObservationIgnored var onMicrophoneBlocked: () -> Void = {}

    @ObservationIgnored private var target: TextTarget?
    @ObservationIgnored private var pressedAt: Date?
    /// Hands-free: keeps listening until the next press or ✓.
    @ObservationIgnored private var latched = false
    @ObservationIgnored private var waitingForSecondTap = false
    /// When the press that locked hands-free went down. Held past a tap, letting go finishes instead:
    /// tap to lock, hold to talk.
    @ObservationIgnored private var lockPressedAt: Date?
    /// Cancels a lone tap once the double-tap window has passed, so tests can wait for it.
    @ObservationIgnored private(set) var pendingTapTimeout: Task<Void, Never>?
    @ObservationIgnored private var audio: AsyncStream<AudioChunk>.Continuation?
    @ObservationIgnored private var transcription: Task<String, Error>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Bumped on every start and cancel, so a cancelled dictation never inserts.
    @ObservationIgnored private var generation = 0
    /// The finish in progress, so tests can wait for it.
    @ObservationIgnored private(set) var pendingFinish: Task<Void, Never>?

    init(
        transcriber: any Transcriber,
        microphone: any AudioSource,
        inserter: TextInserter,
        muter: (any SoundMuter)? = nil,
        cleaner: (any Cleaner)? = nil,
        cleanupTimeout: Duration = .seconds(4),
        now: @escaping () -> Date = Date.init,
        noticeDuration: Duration = .seconds(2.5),
        doubleTapWindow: Duration = .milliseconds(400),
        finishTimeout: Duration = .seconds(10),
        modifierHold: Duration = .milliseconds(250)
    ) {
        self.transcriber = transcriber
        self.microphone = microphone
        self.inserter = inserter
        self.muter = muter
        self.cleaner = cleaner
        self.cleanupTimeout = cleanupTimeout
        self.now = now
        self.noticeDuration = noticeDuration
        self.doubleTapWindow = doubleTapWindow
        self.finishTimeout = finishTimeout
        self.modifierHold = modifierHold
    }

    func shortcutDown() {
        switch phase {
        case .idle, .notice: start()
        case .listening:
            if waitingForSecondTap {
                // Double tap: keep listening, hands-free (unless this press is held).
                clearTapWait()
                latched = true
                lockPressedAt = now()
                Log.dictation.notice("Hands-free")
            } else if latched {
                finish()
            }
        case .working: break
        }
    }

    /// Hands-free: press to start, press again to stop and insert.
    func handsFreeDown() {
        switch phase {
        case .idle, .notice:
            start()
            if phase == .listening {
                latched = true
                lockPressedAt = now()
            }
        case .listening:
            if let pressedAt, now().timeIntervalSince(pressedAt) < Self.earliestStop { return }
            finish()
        case .working: break
        }
    }

    func shortcutUp() {
        if finishIfLockWasHeld() { return }
        guard phase == .listening, !latched, !waitingForSecondTap, let pressedAt else { return }
        guard now().timeIntervalSince(pressedAt) < Self.quickPress else {
            finish()
            return
        }
        // A tap. Keep listening briefly in case it's a double tap; otherwise drop it.
        waitingForSecondTap = true
        pendingTapTimeout = Task { [doubleTapWindow] in
            try? await Task.sleep(for: doubleTapWindow)
            guard !Task.isCancelled, waitingForSecondTap else { return }
            cancel()
        }
    }

    /// ⌃ ⌥ ⌘ ⇧ went down on their own. They're used all the time for shortcuts and capitals, so wait
    /// until it's been held a moment before listening. Anything else pressed meanwhile calls `interrupt()`.
    func modifierDown() {
        guard phase == .idle || isNotice else { return }
        pendingHold?.cancel()
        pendingHold = Task { [modifierHold] in
            try? await Task.sleep(for: modifierHold)
            guard !Task.isCancelled else { return }
            pendingHold = nil
            lastModifierTap = nil
            start()
            startedByModifier = phase == .listening
        }
    }

    /// The modifier key was let go with nothing else pressed.
    func modifierUp() {
        if let hold = pendingHold {
            // Too quick to start: a tap. Two in a row go hands-free.
            hold.cancel()
            pendingHold = nil
            let tappedAt = now()
            if let last = lastModifierTap, tappedAt.timeIntervalSince(last) < doubleTapWindow.seconds {
                lastModifierTap = nil
                start()
                if phase == .listening {
                    latched = true
                    startedByModifier = true
                    Log.dictation.notice("Hands-free")
                }
            } else {
                lastModifierTap = tappedAt
            }
            return
        }
        // Let go after holding, or a tap to stop hands-free.
        if phase == .listening, latched || startedByModifier { finish() }
    }

    private var isNotice: Bool {
        if case .notice = phase { true } else { false }
    }

    /// A hands-free shortcut let go of.
    func handsFreeUp() {
        _ = finishIfLockWasHeld()
    }

    /// The press that locked hands-free was held, not tapped: that's push to talk, so letting go finishes.
    private func finishIfLockWasHeld() -> Bool {
        guard let lockPressedAt else { return false }
        self.lockPressedAt = nil
        guard phase == .listening, latched, now().timeIntervalSince(lockPressedAt) >= Self.quickPress else {
            return false
        }
        Log.dictation.notice("Held, so finishing on release")
        finish()
        return true
    }

    private func clearTapWait() {
        waitingForSecondTap = false
        pendingTapTimeout?.cancel()
    }

    func start() {
        guard canUseMicrophone() else {
            onMicrophoneBlocked()
            showNotice("Allow the microphone first")
            return
        }
        noticeTask?.cancel()
        generation += 1
        target = inserter.captureTarget()
        dictationWords = customWords()
        let hints = dictationWords.map(\.word)
        cleanupContext = CleanupContext(pid: target?.pid)
        if let cleaner { Task { await cleaner.prepare() } }
        pressedAt = now()
        latched = false
        lockPressedAt = nil
        startedByModifier = false
        clearTapWait()

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        do {
            try microphone.start(
                onChunk: { continuation.yield($0) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.level = level }
                }
            )
        } catch {
            Log.dictation.error("Microphone didn't start: \(error.localizedDescription, privacy: .public)")
            continuation.finish()
            showNotice("Can't use the microphone")
            return
        }
        audio = continuation
        muter?.mute()
        transcription = Task { [transcriber] in try await transcriber.transcribe(stream, hints: hints) }
        phase = .listening
        Log.dictation.notice("Listening")
    }

    /// Stops listening and inserts the text (✓, or letting go).
    func finish() {
        guard phase == .listening else { return }
        let releasedAt = now()
        let generation = generation
        let target = target
        let context = cleanupContext
        let words = dictationWords
        clearTapWait()
        phase = .working
        level = 0
        stopListening()

        let timeout = Task { [finishTimeout] in
            try? await Task.sleep(for: finishTimeout)
            guard !Task.isCancelled, generation == self.generation, phase == .working else { return }
            Log.dictation.error("Transcription took too long")
            self.generation += 1
            transcription?.cancel()
            transcription = nil
            showNotice("Didn't catch that")
        }
        pendingFinish = Task {
            defer { timeout.cancel() }
            let text: String
            do {
                text = try await transcription?.value ?? ""
            } catch {
                guard generation == self.generation else { return }
                Log.dictation.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                showNotice("Didn't catch that")
                return
            }
            guard generation == self.generation else { return }
            transcription = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showNotice("Didn't catch that")
                return
            }
            lastHeard = trimmed
            let spelled = CustomSpelling.apply(words, to: trimmed)
            let cleaned = CustomSpelling.apply(words, to: await cleanUp(spelled, context: context))
            guard generation == self.generation else { return }
            guard !cleaned.isEmpty else {
                showNotice("Didn't catch that")
                return
            }
            let outcome = await inserter.insert(cleaned, into: target)
            guard generation == self.generation else { return }
            let timing = now().timeIntervalSince(releasedAt)
            lastTiming = timing
            Log.dictation.notice("Done in \(timing, format: .fixed(precision: 2), privacy: .public)s: \(String(describing: outcome), privacy: .public)")
            if outcome == .copied {
                showNotice("Copied, press ⌘V")
            } else {
                phase = .idle
            }
        }
    }

    /// Every dictation is cleaned up. If the cleaner fails, takes too long or strays from what was said,
    /// the raw text goes in instead.
    private func cleanUp(_ raw: String, context: CleanupContext) async -> String {
        guard let cleaner else { return raw }
        if DriftCheck.isOnlyFillers(raw) { return "" }
        let started = now()
        let work = Task { try await cleaner.clean(raw, context: context) }
        let result: Result<String, Error>? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await work.result) }
            Task { @MainActor [cleanupTimeout] in
                try? await Task.sleep(for: cleanupTimeout)
                work.cancel()
                once.resume(nil)
            }
        }
        let seconds = now().timeIntervalSince(started)
        switch result {
        case nil:
            Log.cleanup.error("Took too long, so used the raw text")
            return raw
        case let .failure(error):
            Log.cleanup.error("Used the raw text: \(String(describing: error), privacy: .public)")
            return raw
        case let .success(cleaned):
            switch DriftCheck.check(raw: raw, cleaned: cleaned) {
            case .accept:
                Log.cleanup.notice("Cleaned in \(seconds, format: .fixed(precision: 2), privacy: .public)s")
                Log.cleanup.debug("\(raw, privacy: .private) → \(cleaned, privacy: .private)")
                return cleaned
            case let .reject(reason):
                Log.cleanup.error("Used the raw text, as the cleanup was \(reason, privacy: .public)")
                return raw
            }
        }
    }

    /// The key that started this was part of a combination (fn+Delete), so drop it quietly.
    /// A hands-free dictation carries on.
    func interrupt() {
        pendingHold?.cancel()
        pendingHold = nil
        lastModifierTap = nil
        guard phase == .listening, !latched else { return }
        cancel()
    }

    /// Stops without inserting anything (✕ or Esc).
    func cancel() {
        guard phase == .listening || phase == .working else { return }
        generation += 1
        clearTapWait()
        stopListening()
        transcription?.cancel()
        transcription = nil
        target = nil
        level = 0
        phase = .idle
        Log.dictation.notice("Cancelled")
    }

    private func stopListening() {
        microphone.stop()
        muter?.restore()
        audio?.finish()
        audio = nil
    }

    private func showNotice(_ text: String) {
        phase = .notice(text)
        noticeTask?.cancel()
        noticeTask = Task { [noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, phase == .notice(text) else { return }
            phase = .idle
        }
    }
}

/// Resumes a continuation the first time only (the result or the timeout, whichever comes first).
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Result<String, Error>?, Never>?

    init(_ continuation: CheckedContinuation<Result<String, Error>?, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String, Error>?) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
