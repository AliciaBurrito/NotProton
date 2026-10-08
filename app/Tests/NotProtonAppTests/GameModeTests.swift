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

// The search is by name prefix, so a fixture tree answers without depending on
// whether the developer machine happens to have Xcode installed.
@Suite("Xcode discovery")
struct GameModeSourceTests {

    // As with the setting file, the caller defers the removal.
    private func fixtureRoot() throws -> URL {
        let root = URL.temporaryDirectory
            .appending(path: "np-xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Bundles whose name starts with Xcode are found")
    func findsXcodeBundles() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Xcode.app", "Xcode Preview.app", "XcodeBeta.app"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name), withIntermediateDirectories: true
            )
        }
        // Same neighborhood, not the same tool.
        for name in ["CrossOver.app", "Xcode.txt", "Xcode"] {
            try Data().write(to: root.appending(path: name))
        }

        let found = GameModeSource.discover(roots: [root]).map(\.lastPathComponent)

        #expect(found == ["Xcode Preview.app", "Xcode.app", "XcodeBeta.app"])
    }

    // The directory xcode-select names may be anywhere, so the answer comes from
    // the tool, and a Command Line Tools directory is not an Xcode.
    @Test("The active developer directory is resolved to its bundle")
    func resolvesToTheBundle() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "Xcode.app")
        try FileManager.default.createDirectory(
            at: bundle.appending(path: "Contents/Developer"), withIntermediateDirectories: true
        )

        let runner: XcrunRunner = { arguments in
            guard arguments == ["-p"] else {
                throw StepFailure(step: "test", detail: "unexpected arguments \(arguments)")
            }
            return CommandResult(
                status: 0,
                stdout: bundle.path(percentEncoded: false) + "/Contents/Developer\n",
                stderr: ""
            )
        }

        #expect(GameModeSource.activeXcode(runner: runner) == bundle)
    }

    @Test("A command line tools directory is not reported as Xcode")
    func rejectsCommandLineTools() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appending(path: "CommandLineTools")
        try FileManager.default.createDirectory(
            at: tools.appending(path: "usr/bin"), withIntermediateDirectories: true
        )

        let runner: XcrunRunner = { _ in
            CommandResult(
                status: 0,
                stdout: tools.path(percentEncoded: false) + "\n",
                stderr: ""
            )
        }

        #expect(GameModeSource.activeXcode(runner: runner) == nil)
    }

    // locate is the readiness probe the whole section turns on, so a failed
    // xcrun (no Xcode) must be a clean nil and not an error out of the capture.
    @Test("A failed resolution reports the tool missing")
    func failedResolutionIsNil() {
        let runner: XcrunRunner = { arguments in
            guard arguments == ["-f", "gamepolicyctl"] else {
                throw StepFailure(step: "test", detail: "unexpected arguments \(arguments)")
            }
            return CommandResult(
                status: 1,
                stdout: "",
                stderr: "xcrun: error: unable to find utility gamepolicyctl, not a valid tool\n"
            )
        }

        #expect(GamePolicyCtl.locate(runner: runner) == nil)
    }

    @Test("A successful resolution reports the tool present")
    func successfulResolutionReportsThePath() {
        let runner: XcrunRunner = { _ in
            CommandResult(
                status: 0,
                stdout: "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl\n",
                stderr: ""
            )
        }

        #expect(
            GamePolicyCtl.locate(runner: runner)
                == "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl"
        )
    }

    // The snapshot's default is what every action that skips the capture sees,
    // so it must be the one state that claims nothing is ready.
    @Test("The neutral state is not ready")
    func neutralIsNotReady() {
        #expect(!GameModeState.neutral.ready)
        #expect(GameModeState.neutral.onState == .unknown)
        #expect(GameModeState.neutral.policy == .unknown)
        #expect(GameModeState.neutral.featureEnabled)
    }
}
