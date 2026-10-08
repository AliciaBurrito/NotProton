// macOS Game Mode: the Xcode tool that controls it, its live state, and the
// setting that decides whether games launched from Steam force it on.
//
// gamepolicyctl is the only tool that can talk to gamepolicyd, which is what
// controls Game Mode, and it ships with Xcode rather than with the system, so
// using it means the user has to have Xcode installed. It runs without admin
// credentials, which keeps the trigger on game launch transparent.

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
    var xcode: URL?
    var xcodeVersion: String?
    var toolAvailable: Bool
    var onState: GameModeOnState = .unknown
    var policy: GameModePolicy = .unknown
    var featureEnabled: Bool = true

    // The one condition the section's readiness messaging turns on.
    var ready: Bool { toolAvailable }

    static let neutral = GameModeState(
        xcode: nil,
        xcodeVersion: nil,
        toolAvailable: false
    )
}

// Runs xcrun and hands its result on. Injectable so tests never touch the
// machine's real developer directory.
typealias XcrunRunner = @Sendable ([String]) throws -> CommandResult

enum GamePolicyCtl {

    static let xcrunPath = "/usr/bin/xcrun"

    static let run: XcrunRunner = { arguments in
        try Shell.run(xcrunPath, arguments)
    }

    // The full path of gamepolicyctl, or nil when Xcode is not installed.
    // xcrun is the resolver the rest of the ecosystem agrees on, and -f only
    // resolves, so this is a cheap readiness probe.
    static func locate(runner: XcrunRunner = run) -> String? {
        guard let result = try? runner(["-f", "gamepolicyctl"]), result.succeeded
        else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func status(runner: XcrunRunner = run) throws
        -> (onState: GameModeOnState, policy: GameModePolicy)
    {
        let result = try runner(["gamepolicyctl", "game-mode", "status"])
        guard result.succeeded else {
            throw CommandFailure(
                command: "gamepolicyctl",
                status: result.status,
                stderr: result.stderr
            )
        }
        return parse(status: result.stdout)
    }

    static func set(_ policy: String, runner: XcrunRunner = run) throws {
        let result = try runner(["gamepolicyctl", "game-mode", "set", policy])
        guard result.succeeded else {
            throw CommandFailure(
                command: "gamepolicyctl",
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    // gamepolicyctl colorizes its words, so the escape sequences go first.
    // Parsing then matches the plain sentences the color hides.
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
        // \e[...m: the escape sequences gamepolicyctl wraps its words in.
        // A literal escape character in the pattern: the braced \u{001B} form
        // is not regular expression syntax, so it would never compile.
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

// The user's setting. The run script reads this same file to decide whether a
// game launch touches the policy, so the format is a word on a line that a
// shell can test: an absent file means enabled.
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

// Finds Xcode and gathers the state the status page presents.
enum GameModeSource {

    static let xcodePrefix = "Xcode"

    // The page this leads to when Xcode is missing.
    static let appStoreURL = URL(
        string: "https://apps.apple.com/us/app/xcode/id497799835?mt=12"
    )!

    static let searchRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    // Like the CrossOver search: standard locations, matched on the name prefix.
    static func discover(roots: [URL] = searchRoots) -> [URL] {
        let files = FileManager.default
        var found: [URL] = []
        var seen: Set<String> = []

        for root in roots {
            let entries = (try? files.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )) ?? []
            for entry in entries {
                guard entry.pathExtension == "app",
                      entry.deletingPathExtension().lastPathComponent.hasPrefix(xcodePrefix)
                else { continue }
                let key = entry.standardizedFileURL.path(percentEncoded: false)
                guard seen.insert(key).inserted else { continue }
                found.append(entry)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // xcode-select names the active developer directory, which is how an
    // Xcode installed somewhere other than the Applications folder is still
    // found. A Command Line Tools directory has no gamepolicyctl, so it is
    // not an answer here.
    static func activeXcode(runner: XcrunRunner = GamePolicyCtl.run) -> URL? {
        guard let result = try? runner(["-p"]), result.succeeded else { return nil }
        let directory = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasSuffix("/Contents/Developer") else { return nil }
        // Deleting path components would leave a trailing slash in the URL,
        // so the suffix just checked for comes off the string instead.
        let bundle = URL(filePath: String(directory.dropLast("/Contents/Developer".count)))
        guard FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)),
              bundle.pathExtension == "app"
        else { return nil }
        return bundle
    }

    static func version(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func capture(
        roots: [URL] = searchRoots,
        runner: XcrunRunner = GamePolicyCtl.run,
        featureFile: URL = GameModeFeature.file
    ) -> GameModeState {
        let xcode = activeXcode(runner: runner) ?? discover(roots: roots).first

        var state = GameModeState(
            xcode: xcode,
            xcodeVersion: xcode.flatMap(version(of:)),
            toolAvailable: GamePolicyCtl.locate(runner: runner) != nil,
            featureEnabled: GameModeFeature.isEnabled(file: featureFile)
        )

        if state.ready {
            if let (onState, policy) = try? GamePolicyCtl.status(runner: runner) {
                state.onState = onState
                state.policy = policy
            }
        }
        return state
    }
}
