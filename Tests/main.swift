import Foundation

// Minimal check harness: every `check` records a failure instead of aborting, so one run shows all problems.
var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func expect<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String = "", line: Int = #line) {
    checks += 1
    let a = actual()
    if a != expected {
        failures += 1
        print("FAIL (line \(line)): \(message) expected \(expected), got \(a)")
    }
}

func tempDirectory() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("murmur-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Log

func testLogRotation() {
    let dir = tempDirectory()
    let url = dir.appendingPathComponent("Murmur.log")
    let old = dir.appendingPathComponent("Murmur.log.1")

    try? Data(repeating: 65, count: 100).write(to: url)
    Log.rotateIfNeeded(url: url, maxBytes: 100)
    check(FileManager.default.fileExists(atPath: url.path), "file at the limit is kept")
    check(!FileManager.default.fileExists(atPath: old.path), "no rotation at the limit")

    try? Data(repeating: 65, count: 101).write(to: url)
    Log.rotateIfNeeded(url: url, maxBytes: 100)
    check(!FileManager.default.fileExists(atPath: url.path), "oversized file is moved away")
    expect((try? Data(contentsOf: old))?.count ?? 0, 101, "rotated file keeps its content")

    try? Data(repeating: 66, count: 150).write(to: url)
    Log.rotateIfNeeded(url: url, maxBytes: 100)
    expect((try? Data(contentsOf: old))?.first ?? 0, 66, "second rotation replaces the old rotated file")
}

// MARK: SilenceDetector

func testSilenceDetector() {
    let t0 = Date(timeIntervalSince1970: 1000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    var d = SilenceDetector(now: t0)
    expect(d.update(level: 0.5, now: at(1), latched: false), .keepGoing, "push-to-talk never auto-stops")
    expect(d.update(level: 0.0, now: at(60), latched: false), .keepGoing, "push-to-talk ignores silence")

    d = SilenceDetector(now: t0)
    expect(d.update(level: 0.5, now: at(1), latched: true), .keepGoing, "speech keeps going")
    expect(d.update(level: 0.0, now: at(3.4), latched: true), .keepGoing, "2.4 s of silence is not enough")
    expect(d.update(level: 0.0, now: at(3.6), latched: true), .stop, "2.6 s of silence after speech stops")

    d = SilenceDetector(now: t0)
    expect(d.update(level: 0.0, now: at(11.9), latched: true), .keepGoing, "11.9 s with no speech keeps waiting")
    expect(d.update(level: 0.0, now: at(12.1), latched: true), .cancel, "12.1 s with no speech cancels")

    d = SilenceDetector(now: t0)
    _ = d.update(level: 0.5, now: at(1), latched: true)
    _ = d.update(level: 0.13, now: at(3), latched: true)
    expect(d.update(level: 0.0, now: at(5), latched: true), .keepGoing, "voice at 0.13 resets the silence clock")

    d = SilenceDetector(now: t0)
    expect(d.update(level: 0.12, now: at(1), latched: true), .keepGoing, "level exactly at threshold")
    expect(d.update(level: 0.0, now: at(5), latched: true), .keepGoing, "threshold level is not voice, so still waiting for speech")
    expect(d.update(level: 0.0, now: at(12.5), latched: true), .cancel, "never heard speech")

    d = SilenceDetector(now: t0)
    _ = d.update(level: 0.5, now: at(1), latched: true)
    d.reset(now: at(100))
    expect(d.update(level: 0.0, now: at(101), latched: true), .keepGoing, "reset forgets earlier speech")
}

// MARK: WakePhrase

func testWakePhrase() {
    for heard in ["hey murmur", "Hey Murmur!", "hey murmer", "k murmur", "okay, murmur", "murmur", "a murmur please"] {
        check(WakePhrase.matches(heard), "should wake on “\(heard)”")
    }
    for heard in ["more", "hey more", "remember", "hey remember", "I will remember that", "good morning everyone", ""] {
        check(!WakePhrase.matches(heard), "should not wake on “\(heard)”")
    }
    expect(WakePhrase.distance("kitten", "sitting"), 3)
    expect(WakePhrase.distance("", "abc"), 3)
    expect(WakePhrase.distance("same", "same"), 0)
}

// MARK: Rules

func testRulesParsing() {
    let text = """
    # a comment
    Keep it short.

    "open ai" -> "OpenAI"
    “git hub” -> “GitHub”
    "" -> "nothing"
    "no arrow here"
    "my email" => "me@example.com"
    "sign off" => "Best,\\nMe"
    vocabulary: Murmur, Kubernetes ,, Sriram
    """
    let rules = Rules.parse(text)
    expect(rules.instructions, ["Keep it short.", "\"no arrow here\""], "free-form lines become instructions; malformed rules are skipped")
    expect(rules.replacements.count, 2, "two valid replacements (empty `from` is skipped)")
    expect(rules.replacements.first?.from ?? "", "open ai")
    expect(rules.replacements.last?.to ?? "", "GitHub", "curly quotes are stripped")
    expect(rules.snippets.count, 2)
    expect(rules.snippets.last?.text ?? "", "Best,\nMe", "\\n in a snippet becomes a newline")
    expect(rules.vocabularyTerms, ["Murmur", "Kubernetes", "Sriram"], "empty vocabulary items are dropped")
    expect(rules.vocabulary, ["Murmur", "Kubernetes", "Sriram", "OpenAI", "GitHub"], "targets are merged and deduped")

    let hostile = Rules.parse(String(repeating: "\"unterminated\n=>\n->\n[\n[]\n", count: 500))
    check(hostile.replacements.isEmpty, "malformed lines never produce replacements")
    check(Rules.parse("").instructions.isEmpty, "empty file parses to nothing")
    check(Rules.parse(String(repeating: "x", count: 500_000)).instructions.first?.count ?? 0 <= Rules.maxCharacters,
          "huge input is capped")
}

func testRulesAppSections() {
    let text = """
    Everywhere rule.
    [Mail]
    Formal tone.
    [com.tinyspeck.slackmacgap]
    Casual tone.
    [default]
    Back to everything.
    """
    expect(Rules.parse(text).instructions, ["Everywhere rule.", "Back to everything."], "no app: only global lines")
    expect(Rules.parse(text, appNames: ["Mail", "com.apple.mail"]).instructions,
           ["Everywhere rule.", "Formal tone.", "Back to everything."], "matched by display name")
    expect(Rules.parse(text, appNames: ["Slack", "COM.TINYSPECK.SLACKMACGAP"]).instructions,
           ["Everywhere rule.", "Casual tone.", "Back to everything."], "matched by bundle id, case-insensitive")
}

func testReplacementsAndSnippets() {
    let rules = Rules.parse("""
    "open ai" -> "OpenAI"
    "git hub" -> "GitHub"
    "my email" => "me@example.com"
    "sign off" => "Best,\\nMe"
    """)
    expect(rules.applyReplacements(to: "I like open ai and OPEN   AI."), "I like OpenAI and OpenAI.", "case-insensitive, spaces flexible")
    expect(rules.applyReplacements(to: "opened air"), "opened air", "whole words only")
    expect(rules.applySnippets(to: "Send it to my email."), "Send it to me@example.com", "trailing full stop is swallowed")
    expect(rules.applySnippets(to: "My email is below"), "me@example.com is below", "case-insensitive in the middle")
    expect(rules.applySnippets(to: "Thanks. Sign off"), "Thanks. Best,\nMe")
    expect(rules.applySnippets(to: "nothing to expand"), "nothing to expand")
    let tricky = Rules.parse("\"cost\" => \"$5 \\1 (total)\"")
    expect(tricky.applySnippets(to: "the cost"), "the $5 \\1 (total)", "replacement text is literal, not a regex template")
}

// MARK: Cleaner

func testBasicCleanup() {
    expect(Cleaner.basicCleanup("um so I I want uh to go"), "So I want to go")
    expect(Cleaner.basicCleanup("hmm, well well well"), "Well")
    expect(Cleaner.basicCleanup("already clean."), "Already clean.")
    expect(Cleaner.basicCleanup("mid sentence continues", capitalizeFirst: false), "mid sentence continues")
    expect(Cleaner.basicCleanup(""), "")
}

func testChunks() {
    expect(Cleaner.chunks(""), [], "empty text has no chunks")
    expect(Cleaner.chunks("  short text.  "), ["short text."])

    let sentence = "This is a perfectly ordinary sentence about nothing in particular."
    let long = Array(repeating: sentence, count: 60).joined(separator: " ")
    let pieces = Cleaner.chunks(long, maxChars: 700)
    check(pieces.count > 1, "long text is split")
    check(pieces.allSatisfy { $0.count <= 700 && !$0.isEmpty }, "every chunk fits and none is empty")
    expect(pieces.joined(separator: " "), long, "joining reproduces the text")

    let noPunctuation = Array(repeating: "word", count: 1000).joined(separator: " ")
    let byWords = Cleaner.chunks(noPunctuation, maxChars: 100)
    check(byWords.allSatisfy { $0.count <= 100 }, "unpunctuated text splits on spaces")
    expect(byWords.joined(separator: " "), noPunctuation)

    let giant = String(repeating: "x", count: 900)
    expect(Cleaner.chunks("a " + giant + " b", maxChars: 700), ["a", giant, "b"], "an over-long single word stays whole")
    let emoji = Array(repeating: "Héllo wörld 🌍 done.", count: 80).joined(separator: " ")
    check(Cleaner.chunks(emoji, maxChars: 200).allSatisfy { $0.count <= 200 }, "unicode is measured in characters")
}

// MARK: SpokenFormatting

func testSpokenFormatting() {
    expect(SpokenFormatting.apply("hello new line world"), "hello\nworld")
    expect(SpokenFormatting.apply("Done. New paragraph. Next"), "Done.\n\nNext")
    expect(SpokenFormatting.apply("Hello, new line, world"), "Hello\nworld", "dangling comma is removed")
    expect(SpokenFormatting.apply("one NEW PARAGRAPH two"), "one\n\ntwo")
    expect(SpokenFormatting.apply("end new line"), "end\n")
    expect(SpokenFormatting.apply("a newline b"), "a\nb")
    expect(SpokenFormatting.apply("nothing special here"), "nothing special here")
    expect(SpokenFormatting.apply("renewline is a word"), "renewline is a word", "only whole words")
}

// MARK: Updater, Diagnostics, History, edit guard

func testUpdaterVersions() {
    check(Updater.isNewer("v1.2.0", than: "1.1.9"), "leading v is ignored")
    check(Updater.isNewer("1.10.0", than: "1.9.0"), "components compare as numbers")
    check(Updater.isNewer("2", than: "1.9.9"), "missing components count as zero")
    check(Updater.isNewer("1.0.1", than: "1.0.0"), "patch bump is newer")
    check(!Updater.isNewer("1.0", than: "1.0.0"), "1.0 equals 1.0.0")
    check(!Updater.isNewer("1.0.0", than: "1.0.1"), "older is not newer")
    check(!Updater.isNewer("1.0.0-beta", than: "1.0.0"), "suffixes are ignored")
    check(!Updater.isNewer("garbage", than: "1.0.0"), "garbage is never newer")
    check(!Updater.isNewer("", than: "1.0.0"), "empty is never newer")
    check(!Updater.isNewer("1.0.0", than: "garbage"), "garbage local version is never beaten")
    check(!Updater.isNewer("1..0", than: "1.0.0"), "empty component is rejected")
}

func testDiagnostics() {
    let home = NSHomeDirectory()
    let report = Diagnostics.report(state: "idle", settings: ["cleanup": "true", "locale": "en_US"],
                                    logTail: "error at \(home)/Library/x", permissions: ["Microphone": "Allowed"])
    check(!report.contains(home), "home folder path is scrubbed")
    check(report.contains("~/Library/x"), "scrubbed path keeps the rest")
    check(report.contains("cleanup: true") && report.contains("Microphone: Allowed") && report.contains("State: idle"),
          "report lists state, settings and permissions")
}

func testHistory() {
    let url = tempDirectory().appendingPathComponent("history.jsonl")
    let history = History(fileURL: url, limit: 3)
    expect(history.recent(5), [], "no file means no history")
    for i in 1...5 {
        history.append(HistoryEntry(date: Date(timeIntervalSince1970: Double(i)), app: "Notes", text: "entry \(i)"))
    }
    expect(history.recent(10).map(\.text), ["entry 5", "entry 4", "entry 3"], "limit keeps the newest, newest first")
    expect(history.recent(2).map(\.text), ["entry 5", "entry 4"])
    let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    expect(perms ?? 0, 0o600, "history file is private to the user")

    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data("this is not json\n".utf8))
        try? handle.close()
    }
    expect(history.recent(10).count, 3, "corrupt lines are skipped")
    history.append(HistoryEntry(date: Date(), app: "Mail", text: "after corruption \"quoted\"\nnew line"))
    expect(history.recent(1).first?.text ?? "", "after corruption \"quoted\"\nnew line", "quotes and newlines round-trip")
    history.clear()
    check(!FileManager.default.fileExists(atPath: url.path), "clear removes the file")
}

func testEditGuard() {
    check(!Cleaner.editLengthOK("", original: "abc"), "empty output is rejected")
    check(Cleaner.editLengthOK(String(repeating: "x", count: 212), original: "abc"), "boundary: 3*4+200 is allowed")
    check(!Cleaner.editLengthOK(String(repeating: "x", count: 213), original: "abc"), "one over the boundary is rejected")
}

testLogRotation()
testSilenceDetector()
testUpdaterVersions()
testDiagnostics()
testHistory()
testEditGuard()
testWakePhrase()
testRulesParsing()
testRulesAppSections()
testReplacementsAndSnippets()
testBasicCleanup()
testChunks()
testSpokenFormatting()

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
