import Foundation
import Testing
@testable import HiveCore

/// Every case of agent-dashboard's tests/test_open_questions.py.
@Suite struct OpenQuestionsTests {
    static let screenshot = """
    Billing now works end to end.

    **Left for you to decide:** whether the free plan lock should switch off while billing is off, and whether the server should enforce it. The jobs won't change either.

    Still open from before:

    - App Store 3.9.20 is waiting on the privacy label.
    - The icon count: all companies, or only the last one opened?
    - Android smart pushes: open the PR, or will you merge it?

    """

    static func tail(_ text: String, promptTs: Int = 100, turnEnded: Bool = true, ask: String? = nil) -> TranscriptTail {
        var t = TranscriptTail()
        t.turnEnded = turnEnded
        t.ask = ask
        t.lastText = text
        t.lastTextTs = 200
        t.promptTs = promptTs
        return t
    }

    static func raw(_ status: String) -> SessionFile {
        var raw = SessionFile()
        raw.status = status
        return raw
    }

    @Test func screenshot() {
        #expect(OpenQuestions.find(Self.screenshot) == [
            "Whether the free plan lock should switch off while billing is off, and whether the server should enforce it.",
            "App Store 3.9.20 is waiting on the privacy label.",
            "The icon count: all companies, or only the last one opened?",
            "Android smart pushes: open the PR, or will you merge it?",
        ])
    }

    @Test func plainReportHasNone() {
        #expect(OpenQuestions.find("Pushed to main. All 40 tests pass.\n\n- Build is green.") == [])
    }

    @Test func questionInsideAParagraph() {
        #expect(OpenQuestions.find("Done. Should I push it? It's ready.") == ["Should I push it?"])
    }

    @Test func closingOfferCounts() {
        #expect(OpenQuestions.find("All set.\n\nWant me to also tidy the README?") == ["Want me to also tidy the README?"])
    }

    @Test func codeAndQuotesAreIgnored() {
        let text = "Here it is:\n\n```js\nconst ok = a ? b : c; // why?\n```\n\n> Should we?\n\nShipped."
        #expect(OpenQuestions.find(text) == [])
    }

    @Test func quotedNamesAreNotQuestions() {
        let text = "One Studio tab may still be open behind a \"Leave site?\" dialog. I closed the \u{201c}Save?\u{201d} prompt."
        #expect(OpenQuestions.find(text) == [])
        #expect(OpenQuestions.find("It shows \"Leave site?\". Close it for me?") == ["Close it for me?"])
        #expect(OpenQuestions.find("Should I close the \"Leave site?\" dialog?") == ["Should I close the \"Leave site?\" dialog?"])
    }

    @Test func markdownIsRemoved() {
        #expect(OpenQuestions.find("**Should I merge it?**") == ["Should I merge it?"])
    }

    @Test func duplicatesAndLimit() {
        let text = (0..<8).map { "- Question \($0)?" }.joined(separator: "\n") + "\n- Question 1?"
        #expect(OpenQuestions.find(text).count == 5)
    }

    @Test func finishedTurnWithQuestionsNeedsYouEvenWithACommandRunning() {
        let command = SessionCommand(json: JSONObject(["pid": 1, "cmd": "sleep 999", "cpu": 0, "uptime": 5]))
        let got = Describer.describe(raw: Self.raw("busy"), tail: Self.tail(Self.screenshot), subsRunning: 0, commands: [command])
        #expect(got.group == "needs")
        #expect(got.reason == "questions")
        #expect(got.headline.hasPrefix("4 open questions: Whether the free plan lock"))
    }

    @Test func oneQuestionHeadline() {
        let got = Describer.describe(raw: Self.raw("idle"), tail: Self.tail("Want me to push?"), subsRunning: 0, commands: [])
        #expect(got.headline == "1 open question: Want me to push?")
    }

    @Test func replyClearsIt() {
        let got = Describer.describe(raw: Self.raw("idle"), tail: Self.tail(Self.screenshot, promptTs: 300), subsRunning: 0, commands: [])
        #expect(got.group == "idle")
    }

    @Test func turnStillRunningIsWorking() {
        let got = Describer.describe(raw: Self.raw("busy"), tail: Self.tail(Self.screenshot, turnEnded: false), subsRunning: 0, commands: [])
        #expect(got.group == "working")
    }

    @Test func formalQuestionStillWins() {
        let got = Describer.describe(raw: Self.raw("idle"), tail: Self.tail(Self.screenshot, ask: "Commit it?"), subsRunning: 0, commands: [])
        #expect(got.group == "needs")
        #expect(got.reason == "question")
        #expect(got.headline == "Asked: Commit it?")
    }

    @Test func questionsOfTail() {
        #expect(OpenQuestions.of(Self.tail("Should I push it?")) == ["Should I push it?"])
        #expect(OpenQuestions.of(Self.tail("Should I push it?", promptTs: 999)) == [])
        #expect(OpenQuestions.of(nil) == [])
    }

    // Beyond the Python tests: details of the rules that are easy to get wrong in a port.

    @Test func headingsAndTheirRest() {
        #expect(OpenQuestions.find("Your call — ship it now. Or wait.") == ["Ship it now."])
        #expect(OpenQuestions.find("Open questions\n1. First thing\n2) Second thing\nNot a list line.") == [
            "First thing", "Second thing"])
        #expect(OpenQuestions.find("Decisions needed:\n\u{2022} pick a name") == ["Pick a name"])
        // A plain line ends the heading's list.
        #expect(OpenQuestions.find("Still open:\nSomething else.\n- not under it") == [])
    }

    @Test func linksDontEndQuestions() {
        #expect(OpenQuestions.find("See https://example.com/a?b=1 for details.") == [])
        #expect(OpenQuestions.find("Is https://example.com/a?b=1 right?") == ["Is https://example.com/a?b=1 right?"])
    }

    @Test func recapAndLastTextBothCount() {
        var t = Self.tail("Ready to merge?")
        t.recap = "Tests pass. Push it now?"
        #expect(OpenQuestions.of(t) == ["Push it now?", "Ready to merge?"])
        t.promptTs = 999
        #expect(OpenQuestions.of(t) == ["Push it now?"], "the recap stays until the next prompt clears it")
    }
}
