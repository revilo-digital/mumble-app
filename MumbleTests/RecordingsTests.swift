import Foundation
import Testing
@testable import Mumble

@MainActor
struct RecordingsTests {
    let system = FakeSystem()
    let clipboard = FakeClipboard()
    let microphone = FakeMicrophone()
    let clock = TestClock()
    let folder = FileManager.default.temporaryDirectory.appending(path: "Mumble Recordings Tests-\(UUID().uuidString)")

    func makeController(says text: String = "Hello there.") -> (DictationController, () -> RecordingWriter?) {
        system.clipboard = clipboard
        let controller = DictationController(
            transcriber: FakeTranscriber(text: text),
            microphone: microphone,
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            now: { [clock] in clock.now },
            noticeDuration: .seconds(60)
        )
        var last: RecordingWriter?
        controller.startRecording = { [folder] in
            last = RecordingWriter(folder: folder, keep: 2)
            return last
        }
        return (controller, { last })
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func aDictationIsSavedWithWhatWasHeardAndItsContext() async throws {
        system.windowTitles[100] = "Shopify store"
        system.textBefore[1] = "We need to fix the login."
        let (controller, writer) = makeController()
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        let recording = try #require(writer())
        recording.flush()
        #expect(files().count == 2)
        let info = try JSONDecoder.recordings.decode(RecordingInfo.self, from: Data(contentsOf: recording.infoURL))
        #expect(info.heard == "Hello there.")
        #expect(info.inserted == "Hello there.")
        #expect(info.context.windowTitle == "Shopify store")
        #expect(info.context.textBefore == "We need to fix the login.")
        #expect(info.meant == nil)
    }

    @Test func aCancelledDictationIsntKept() async {
        let (controller, writer) = makeController()
        controller.shortcutDown()
        controller.cancel()
        writer()?.flush()
        #expect(files().isEmpty)
    }

    @Test func aPasswordBoxsTextIsNeverRead() {
        system.focused[100] = FakeField(1, secure: true)
        system.textBefore[1] = "hunter2"
        let (controller, _) = makeController()
        controller.shortcutDown()
        #expect(controller.dictationContext.textBefore == nil)
        controller.cancel()
    }

    @Test func onlyTheNewestAreKept() async {
        let (controller, writer) = makeController()
        for _ in 0..<3 {
            controller.shortcutDown()
            clock.advance(2)
            controller.shortcutUp()
            await controller.pendingFinish?.value
            writer()?.flush()
            try? await Task.sleep(for: .milliseconds(2))  // Names are stamped to the millisecond.
        }
        #expect(files().filter { $0.hasSuffix(".wav") }.count == 2)
    }
}

extension JSONDecoder {
    static var recordings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
struct RecordingListTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Mumble Recording List-\(UUID().uuidString)")

    func saveOne(heard: String, inserted: String) throws -> RecordingList {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = RecordingInfo(date: .now, context: DictationContext(app: "Notes"), seconds: 2, heard: heard, inserted: inserted)
        try RecordingInfo.encoder.encode(info).write(to: folder.appending(path: "a.json"))
        try Data().write(to: folder.appending(path: "a.wav"))
        let list = RecordingList(folder: folder)
        list.reload()
        return list
    }

    @Test func markingWrongSavesWhatWasMeant() throws {
        let list = try saveOne(heard: "Comma already exists.", inserted: "Comma already exists.")
        let item = try #require(list.items.first)
        list.markWrong(item, meant: "  Tama already exists. ")
        list.reload()
        #expect(list.items.first?.info.rating == .wrong)
        #expect(list.items.first?.info.meant == "Tama already exists.")
    }

    @Test func markingRightMeansWhatWentIn() throws {
        let list = try saveOne(heard: "hello there", inserted: "Hello there.")
        list.markGood(try #require(list.items.first))
        list.reload()
        #expect(list.items.first?.info.rating == .good)
        #expect(list.items.first?.info.meant == "Hello there.")
    }

    @Test func deletingRemovesBothFiles() throws {
        let list = try saveOne(heard: "a", inserted: "a")
        list.delete(try #require(list.items.first))
        #expect(list.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "a.wav").path(percentEncoded: false)))
    }

    @Test(arguments: [
        ("Tama already exists.", "Comma already exists.", ["Tama"]),
        ("I'm logged into the store.", "I'm locked into the store.", []),
        ("Check the Shopify auth flow.", "Check the Shopify with flow.", ["auth"]),
        ("Open BrightCRM on the M3.", "Open bright CRM on the M three.", ["BrightCRM", "M3"]),
        ("Ask Kōwhai.", "Ask visible.", []),
    ])
    func suggestsNamesItMissed(meant: String, heard: String, expected: [String]) {
        let everyday: Set = ["already", "exists", "logged", "into", "the", "store", "check", "flow", "open", "on", "ask", "i'm"]
        let suggested = RecordingList.suggestedWords(meant: meant, heard: heard, existing: ["Kōwhai"]) { everyday.contains($0) }
        #expect(suggested == expected)
    }
}
