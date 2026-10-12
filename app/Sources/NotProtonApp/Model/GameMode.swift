// Manages Game Mode state and user preferences

import Foundation

enum GameModeOnState: Sendable, Equatable {
    case unknown
    case off
    case on
    case temporarilyOn
}

enum GameModePolicy: Sendable, Equatable {
    case unknown
    case automatic
    // A manual policy: the user (or a tool) forced Game Mode on or off.
    case manual
}

struct GameModeState: Sendable, Equatable {
    var xcodes: [XcodeInstall] = []
    var xcode: XcodeInstall?
    var onState: GameModeOnState = .unknown
    var policy: GameModePolicy = .unknown
    var featureEnabled: Bool = true

    var ready: Bool { xcode?.hasTool == true }

    static let neutral = GameModeState()
}

// Allows tests to run without touching the real system
typealias CommandRunner = @Sendable (String, [String]) throws -> CommandResult

// Runs gamepolicyctl from a chosen Xcode bundle
enum GamePolicyCtl {

    static let run: CommandRunner = { executable, arguments in
        try Shell.run(executable, arguments)
    }

    static func status(tool: URL, runner: CommandRunner = run) throws
        -> (onState: GameModeOnState, policy: GameModePolicy)
    {
        let result = try runner(tool.path(percentEncoded: false), ["game-mode", "status"])
        guard result.succeeded else {
            throw CommandFailure(
                command: "gamepolicyctl",
                status: result.status,
                stderr: result.stderr
            )
        }
        return parse(status: result.stdout)
    }

    static func set(_ policy: String, tool: URL, runner: CommandRunner = run) throws {
        let result = try runner(tool.path(percentEncoded: false), ["game-mode", "set", policy])
        guard result.succeeded else {
            throw CommandFailure(
                command: "gamepolicyctl",
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    // Removes color formatting to ensure clean text parsing
    static func parse(status text: String) -> (GameModeOnState, GameModePolicy) {
        let plain = ANSIEscapes.stripped(text)

        var onState: GameModeOnState = .unknown
        if plain.contains("will soon turn off") {
            onState = .temporarilyOn
        } else if plain.contains("Game mode is on") {
            onState = .on
        } else if plain.contains("Game mode is off") {
            onState = .off
        }

        var policy: GameModePolicy = .unknown
        if plain.contains("enablement policy is currently automatic") {
            policy = .automatic
        } else if plain.contains("enablement policy is currently disabled") {
            policy = .manual
        }
        return (onState, policy)
    }
}

enum ANSIEscapes {
    private static let regex = {
        // Matches ANSI escape sequences using a literal escape character 
        // for regex compatibility
        try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*m")
    }()

    static func stripped(_ text: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
    }
}

// Shared Game Mode toggle state, stored in a shell-friendly format. 
// Defaults to enabled if absent
enum GameModeFeature {

    static let step = "Game Mode"

    static let enabledValue = "enabled"
    static let disabledValue = "disabled"

    static var file: URL { SupportPaths.gameMode }

    static func isEnabled(file: URL = GameModeFeature.file) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return true }
        let first = text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return first == enabledValue
    }

    static func setEnabled(_ enabled: Bool, file: URL = GameModeFeature.file) throws {
        let value = enabled ? enabledValue : disabledValue
        let data = Data("\(value)\n".utf8)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try WriteRefused.catching(file) {
            try data.write(to: file, options: .atomic)
        }
    }
}

// Gathers the state the page presents
enum GameModeSource {

    static func capture(
        roots: [URL] = XcodeSource.searchRoots,
        runner: CommandRunner = GamePolicyCtl.run,
        choiceFile: URL = SupportPaths.xcodeActive,
        featureFile: URL = GameModeFeature.file
    ) -> GameModeState {
        let xcodes = XcodeSource.discover(roots: roots, runner: runner)
        let active = XcodeSource.activeBundle(installs: xcodes, file: choiceFile)

        var state = GameModeState(
            xcodes: xcodes,
            xcode: active,
            featureEnabled: GameModeFeature.isEnabled(file: featureFile)
        )

        if let tool = active?.toolURL {
            if let (onState, policy) = try? GamePolicyCtl.status(tool: tool, runner: runner) {
                state.onState = onState
                state.policy = policy
            }
        }
        return state
    }
}
