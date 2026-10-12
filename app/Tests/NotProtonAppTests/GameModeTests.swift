import Foundation
import Testing

@testable import NotProtonApp

// The sentences gamepolicyctl prints, with and without the color escapes it
// wraps its words in. The parser must answer the same for both.
@Suite("Game policy status parsing")
struct GamePolicyStatusTests {

    @Test("Automatic and off is the resting state")
    func automaticOff() {
        let text = "Game mode is off.\n"
            + "Game mode enablement policy is currently automatic. The system "
            + "must meet all specified requirements to enable game mode.\n"

        let (onState, policy) = GamePolicyCtl.parse(status: text)

        #expect(onState == .off)
        #expect(policy == .automatic)
    }

    @Test("A forced policy with Game Mode on is the state a game leaves behind")
    func manualOn() {
        let text = "Game mode is on.\n"
            + "Game mode enablement policy is currently disabled. Game mode is forced always on.\n"

        let (onState, policy) = GamePolicyCtl.parse(status: text)

        #expect(onState == .on)
        #expect(policy == .manual)
    }

    // The words carry SGR color, so the sentences to match against are hidden
    // inside the escape sequences.
    @Test("Color escapes are stripped before the words are matched")
    func colorized() {
        let text = "Game mode is \u{1B}[0;32mon\u{1B}[0;0m.\u{1B}[0;33m\u{1B}[0;0m\n"
            + "Game mode enablement policy is currently disabled. Game mode is forced always on.\n"

        let (onState, policy) = GamePolicyCtl.parse(status: text)

        #expect(onState == .on)
        #expect(policy == .manual)
    }

    // A game that was backgrounded: on, but expiring. A feature that pins it
    // has to tell that apart from a stable on.
    @Test("A soon-to-expire on is a distinct state")
    func temporarilyOn() {
        let text = "Game mode is on.\nGame mode will soon turn off.\n"

        let (onState, _) = GamePolicyCtl.parse(status: text)

        #expect(onState == .temporarilyOn)
    }

    @Test("Unrecognized output is unknown rather than a guess")
    func unrecognized() {
        let (onState, policy) = GamePolicyCtl.parse(status: "something else entirely\n")

        #expect(onState == .unknown)
        #expect(policy == .unknown)
    }
}

// The setting is a contract with the run script, which reads the same file to
// decide whether a launch touches the policy. An absent file means enabled.
@Suite("Game mode feature setting")
struct GameModeFeatureTests {

    // Creates the support directory a setting file would live in. The caller
    // defers removing it, because a defer in here would run before the test does.
    private func scratchDirectory() throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: "np-gamemode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("An absent setting file means the feature is on")
    func absentMeansOn() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gamemode")

        #expect(GameModeFeature.isEnabled(file: file))
    }

    @Test("The written values read back the way they were set")
    func roundTrip() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gamemode")

        try GameModeFeature.setEnabled(false, file: file)
        #expect(!GameModeFeature.isEnabled(file: file))

        try GameModeFeature.setEnabled(true, file: file)
        #expect(GameModeFeature.isEnabled(file: file))
    }

    // The shell only special-cases the one word, so anything else the file
    // holds must read as off, not as a mystery that defaults back on.
    @Test("Unrecognized content reads as off")
    func unrecognizedIsOff() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gamemode")
        try Data("garbage\n".utf8).write(to: file)

        #expect(!GameModeFeature.isEnabled(file: file))
    }

    @Test("Whitespace around the word is ignored")
    func whitespaceTolerated() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "gamemode")
        try Data(" enabled \n".utf8).write(to: file)

        #expect(GameModeFeature.isEnabled(file: file))
    }

    @Test("The file lives where the support paths say the contract puts it")
    func fileLocation() {
        #expect(
            SupportPaths.gameMode.path(percentEncoded: false)
                == SupportPaths.support.path(percentEncoded: false) + "/gamemode"
        )
    }
}

// The search is by name prefix and the Developer directory, so a fixture tree
// answers without depending on whether the developer machine happens to have
// Xcode installed.
@Suite("Xcode discovery")
struct XcodeSourceTests {

    // The machine's real xcode-select stays out of the suite: every discovery
    // test says what xcode-select would answer.
    private static let noSelection: CommandRunner = { executable, arguments in
        guard executable == "/usr/bin/xcode-select", arguments == ["-p"] else {
            throw StepFailure(step: "test", detail: "unexpected command \(executable) \(arguments)")
        }
        return CommandResult(status: 1, stdout: "", stderr: "")
    }

    // A suite of its own, so the developer machine's list of manually added
    // copies never leaks into the results.
    private func defaults() -> UserDefaults {
        let name = "np-xcode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // As with the setting file, the caller defers the removal.
    private func fixtureRoot() throws -> URL {
        let root = URL.temporaryDirectory
            .appending(path: "np-xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // A bundle in the fixture tree: the Developer directory is what discovery
    // requires beyond the name.
    private func makeBundle(named name: String, in parent: URL) throws -> URL {
        let bundle = parent.appending(path: name)
        try FileManager.default.createDirectory(
            at: bundle.appending(path: "Contents/Developer"), withIntermediateDirectories: true
        )
        return bundle
    }

    // The tool the app and the run script both look for, executable.
    private func makeTool(in bundle: URL) throws {
        let tool = bundle.appending(path: "Contents/Developer/usr/bin/gamepolicyctl")
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false)
        )
    }

    @Test("Bundles named Xcode*.app with a Developer directory are found")
    func findsXcodeBundles() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Xcode.app", "Xcode Preview.app", "XcodeBeta.app"] {
            _ = try makeBundle(named: name, in: root)
        }
        // Same neighborhood, not the same tool: the name passes, but without
        // the Developer directory it is not an Xcode.
        try FileManager.default.createDirectory(
            at: root.appending(path: "XcodeBroken.app"), withIntermediateDirectories: true
        )
        for name in ["CrossOver.app", "Xcode.txt", "Xcode"] {
            try Data().write(to: root.appending(path: name))
        }

        let found = XcodeSource.discover(
            roots: [root], runner: Self.noSelection, defaults: defaults()
        ).map(\.name)

        #expect(found == ["Xcode", "Xcode Preview", "XcodeBeta"])
    }

    @Test("The xcode-select target outside the searched folders is listed first")
    func selectedOutsideRoots() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try makeBundle(named: "Xcode.app", in: root)
        let selected = try makeBundle(named: "Xcode.app", in: root.appending(path: "elsewhere"))
        try makeTool(in: found)
        try makeTool(in: selected)

        let runner: CommandRunner = { executable, arguments in
            guard executable == "/usr/bin/xcode-select", arguments == ["-p"] else {
                throw StepFailure(step: "test", detail: "unexpected command \(executable) \(arguments)")
            }
            return CommandResult(
                status: 0,
                stdout: selected.path(percentEncoded: false) + "/Contents/Developer\n",
                stderr: ""
            )
        }

        let installs = XcodeSource.discover(
            roots: [root], runner: runner, defaults: defaults()
        )

        #expect(installs.count == 2)
        #expect(XcodeSource.same(installs[0].bundle, selected))
        #expect(installs[0].origin == .selected)
        #expect(XcodeSource.same(installs[1].bundle, found))
        #expect(installs[1].origin == .found)
    }

    @Test("The xcode-select target inside the searched folders is not listed twice")
    func selectedInsideRoots() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(named: "Xcode.app", in: root)

        let runner: CommandRunner = { executable, arguments in
            guard executable == "/usr/bin/xcode-select", arguments == ["-p"] else {
                throw StepFailure(step: "test", detail: "unexpected command \(executable) \(arguments)")
            }
            return CommandResult(
                status: 0,
                stdout: bundle.path(percentEncoded: false) + "/Contents/Developer\n",
                stderr: ""
            )
        }

        let installs = XcodeSource.discover(
            roots: [root], runner: runner, defaults: defaults()
        )

        #expect(installs.count == 1)
        #expect(installs[0].origin == .found)
    }

    // The directory xcode-select names may be anywhere, so the answer comes from
    // the tool, and a Command Line Tools directory is not an Xcode.
    @Test("A command line tools directory is not reported as Xcode")
    func rejectsCommandLineTools() {
        let runner: CommandRunner = { executable, arguments in
            guard executable == "/usr/bin/xcode-select", arguments == ["-p"] else {
                throw StepFailure(step: "test", detail: "unexpected command \(executable) \(arguments)")
            }
            return CommandResult(
                status: 0,
                stdout: "/Library/Developer/CommandLineTools\n",
                stderr: ""
            )
        }

        #expect(XcodeSource.selectedBundle(runner: runner) == nil)
    }

    @Test("Copies the user added are listed after the found ones")
    func manualCopiesAreListed() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeBundle(named: "Xcode.app", in: root)
        let manual = try makeBundle(named: "Xcode.app", in: root.appending(path: "elsewhere"))
        try makeTool(in: manual)

        let defaults = defaults()
        XcodeSource.addManualBundle(manual, defaults)

        var installs = XcodeSource.discover(
            roots: [root], runner: Self.noSelection, defaults: defaults
        )
        #expect(installs.map(\.origin) == [.found, .manual])

        XcodeSource.removeManualBundle(manual, defaults)
        installs = XcodeSource.discover(
            roots: [root], runner: Self.noSelection, defaults: defaults
        )
        #expect(installs.map(\.origin) == [.found])
    }
}

// The Xcode the app and the run script settle on: a recorded choice when it
// still carries the tool, then the xcode-select target, then the Applications
// copies. A manual copy only comes in through an explicit choice.
@Suite("Active Xcode selection")
struct XcodeActiveTests {

    private static func install(
        _ path: String,
        hasTool: Bool = false,
        origin: XcodeInstall.Origin
    ) -> XcodeInstall {
        XcodeInstall(
            bundle: URL(filePath: path, directoryHint: .isDirectory),
            version: nil,
            hasTool: hasTool,
            origin: origin
        )
    }

    // A scratch file in place of the support directory's; the caller defers
    // the removal.
    private func choiceFile() -> URL {
        URL.temporaryDirectory.appending(path: "np-xcode-choice-\(UUID().uuidString)")
    }

    @Test("The recorded choice reads back the bundle it named")
    func choiceRoundTrip() throws {
        let file = choiceFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let bundle = URL(filePath: "/Applications/Xcode Preview.app", directoryHint: .isDirectory)

        try XcodeSource.setChoice(bundle, file: file)
        #expect(XcodeSource.readChoice(file: file) == bundle)

        try XcodeSource.clearChoice(file: file)
        #expect(XcodeSource.readChoice(file: file) == nil)
    }

    @Test("The choice file lives where the support paths say the contract puts it")
    func choiceFileLocation() {
        #expect(
            SupportPaths.xcodeActive.path(percentEncoded: false)
                == SupportPaths.support.path(percentEncoded: false) + "/xcode-active"
        )
    }

    @Test("A recorded choice wins over the system's Xcode")
    func choiceWins() throws {
        let file = choiceFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let chosen = Self.install("/Volumes/Other/Xcode.app", hasTool: true, origin: .manual)
        let system = Self.install("/Applications/Xcode.app", hasTool: true, origin: .found)
        try XcodeSource.setChoice(chosen.bundle, file: file)

        #expect(XcodeSource.activeBundle(installs: [system, chosen], file: file) == chosen)
    }

    @Test("A choice that lost its tool falls through to the system's Xcode")
    func toollessChoiceFallsThrough() throws {
        let file = choiceFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let chosen = Self.install("/Volumes/Other/Xcode.app", hasTool: false, origin: .manual)
        let system = Self.install("/Applications/Xcode.app", hasTool: true, origin: .found)
        try XcodeSource.setChoice(chosen.bundle, file: file)

        #expect(XcodeSource.activeBundle(installs: [system, chosen], file: file) == system)
    }

    @Test("The xcode-select target outranks the Applications copies")
    func selectedOutranksFound() {
        let selected = Self.install("/Volumes/Other/Xcode.app", hasTool: true, origin: .selected)
        let found = Self.install("/Applications/Xcode.app", hasTool: true, origin: .found)

        #expect(
            XcodeSource.activeBundle(
                installs: [selected, found],
                file: choiceFile()
            ) == selected
        )
    }

    @Test("A copy that carries the tool is preferred")
    func toolPreferred() {
        let toolless = Self.install("/Applications/Xcode.app", hasTool: false, origin: .selected)
        let usable = Self.install("/Applications/Xcode Preview.app", hasTool: true, origin: .found)

        #expect(
            XcodeSource.activeBundle(installs: [toolless, usable], file: choiceFile()) == usable
        )
    }

    // Nothing carries the tool, so the answer is only for display: the first
    // system copy, in the list order discovery gives.
    @Test("With no tool anywhere the first system copy is the display")
    func displayFallback() {
        let first = Self.install("/Applications/Xcode.app", hasTool: false, origin: .found)
        let second = Self.install("/Applications/Xcode Preview.app", hasTool: false, origin: .found)

        #expect(
            XcodeSource.activeBundle(installs: [first, second], file: choiceFile()) == first
        )
    }

    @Test("A manual copy never becomes active on its own")
    func manualNeverAutoActivates() {
        let manual = Self.install("/Volumes/Other/Xcode.app", hasTool: true, origin: .manual)

        #expect(XcodeSource.activeBundle(installs: [manual], file: choiceFile()) == nil)
    }

    @Test("A choice may name a manual copy")
    func choiceMayNameManual() throws {
        let file = choiceFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let manual = Self.install("/Volumes/Other/Xcode.app", hasTool: true, origin: .manual)
        let system = Self.install("/Applications/Xcode.app", hasTool: true, origin: .found)
        try XcodeSource.setChoice(manual.bundle, file: file)

        #expect(XcodeSource.activeBundle(installs: [system, manual], file: file) == manual)
    }

    // The snapshot's default is what every action that skips the capture sees,
    // so it must be the one state that claims nothing is ready.
    @Test("The neutral state is not ready")
    func neutralIsNotReady() {
        let neutral = GameModeState.neutral
        #expect(!neutral.ready)
        #expect(neutral.xcodes.isEmpty)
        #expect(neutral.xcode == nil)
        #expect(neutral.onState == .unknown)
        #expect(neutral.policy == .unknown)
        #expect(neutral.featureEnabled)
    }
}

// gamepolicyctl runs from its bundle rather than through xcrun, so the call is
// on the tool path with the subcommand after it.
@Suite("Game policy tool invocation")
struct GamePolicyInvocationTests {

    @Test("The status call goes to the tool in the chosen bundle")
    func directStatusInvocation() throws {
        let tool = URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl")
        let runner: CommandRunner = { executable, arguments in
            #expect(executable == tool.path(percentEncoded: false))
            #expect(arguments == ["game-mode", "status"])
            return CommandResult(
                status: 0,
                stdout: "Game mode is off.\n"
                    + "Game mode enablement policy is currently automatic.\n",
                stderr: ""
            )
        }

        let (onState, policy) = try GamePolicyCtl.status(tool: tool, runner: runner)

        #expect(onState == .off)
        #expect(policy == .automatic)
    }
}
