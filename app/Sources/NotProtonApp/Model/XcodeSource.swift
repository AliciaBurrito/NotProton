// Finds Xcode installs on disk and records which one NotProton uses for
// Game Mode. The choice lives in the support directory, which the run script
// reads at game launch, so picking an Xcode here changes nothing about the
// system itself.

import Foundation

struct XcodeInstall: Sendable, Identifiable, Equatable {

    enum Origin: Sendable, Equatable {
        // In an Applications folder the search covers.
        case found
        // The bundle xcode-select points at, installed somewhere else.
        case selected
        // Added to the list by the user.
        case manual
    }

    let bundle: URL
    let version: String?
    let hasTool: Bool
    let origin: Origin

    var id: String { bundle.path(percentEncoded: false) }
    var name: String { bundle.deletingPathExtension().lastPathComponent }

    // gamepolicyctl lives here in every Xcode that carries it.
    var toolURL: URL? { hasTool ? XcodeSource.toolURL(inBundle: bundle) : nil }
}

enum XcodeSource {

    static let xcodePrefix = "Xcode"

    // The page this leads to when Xcode is missing.
    static let appStoreURL = URL(
        string: "https://apps.apple.com/us/app/xcode/id497799835?mt=12"
    )!

    static let searchRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    private static let manualKey = "manualXcodePaths"

    static func manualBundles(_ defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: manualKey) ?? []
        return paths.filter { !$0.isEmpty }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func setManualBundles(_ bundles: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(bundles.map { $0.path(percentEncoded: false) }, forKey: manualKey)
    }

    static func addManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        let current = manualBundles(defaults)
        guard !current.contains(where: { same($0, bundle) }) else { return }
        setManualBundles(current + [bundle], defaults)
    }

    static func removeManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        setManualBundles(manualBundles(defaults).filter { !same($0, bundle) }, defaults)
    }

    // Directory listings report bundles with a trailing slash and recorded
    // paths without, so both forms compare equal; the standardized form keeps
    // the comparison independent of how the path was spelled.
    private static func key(_ bundle: URL) -> String {
        let path = bundle.standardizedFileURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func isSearched(_ bundle: URL, in roots: [URL] = searchRoots) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        return roots.contains { same($0, parent) }
    }

    static func same(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }

    // The tool runs without admin credentials, so its presence is the whole
    // readiness question. It ships in the Developer directory, which is also
    // what separates an Xcode bundle from anything else with a similar name.
    static func toolURL(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/Developer/usr/bin/gamepolicyctl")
    }

    static func looksLikeXcode(_ bundle: URL) -> Bool {
        let developer = bundle.appending(path: "Contents/Developer")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: developer.path(percentEncoded: false), isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    static func hasTool(inBundle bundle: URL) -> Bool {
        let path = toolURL(inBundle: bundle).path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path)
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // xcode-select names the active developer directory, which is how an Xcode
    // installed somewhere other than the Applications folders is still found.
    // A Command Line Tools directory has no bundle to run from, so it is not
    // an answer here.
    static func selectedBundle(runner: CommandRunner = GamePolicyCtl.run) -> URL? {
        guard let result = try? runner("/usr/bin/xcode-select", ["-p"]), result.succeeded
        else { return nil }
        let directory = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasSuffix("/Contents/Developer") else { return nil }
        // Deleting path components would leave a trailing slash in the URL,
        // so the suffix just checked for comes off the string instead.
        let bundle = URL(filePath: String(directory.dropLast("/Contents/Developer".count)))
        guard looksLikeXcode(bundle) else { return nil }
        return bundle
    }

    // Xcode puts the version number here, so this is the string its page shows.
    static func version(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func inspect(bundle: URL, origin: XcodeInstall.Origin) -> XcodeInstall {
        // Directory listings report bundles with a trailing slash; the model
        // keeps the clean form, which is what the choice file holds too.
        let path = bundle.path(percentEncoded: false)
        let clean = path.hasSuffix("/")
            ? URL(filePath: String(path.dropLast()), directoryHint: .isDirectory)
            : bundle
        return XcodeInstall(
            bundle: clean,
            version: version(of: bundle),
            hasTool: hasTool(inBundle: bundle),
            origin: origin
        )
    }

    // The xcode-active file records the Xcode the user chose with Set Up. The
    // run script reads the same file, so the choice is a contract between the
    // two: an absent file means the derivation below stands.
    static func readChoice(file: URL = SupportPaths.xcodeActive) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !line.isEmpty else { return nil }
        return URL(filePath: line, directoryHint: .isDirectory)
    }

    static func setChoice(_ bundle: URL, file: URL = SupportPaths.xcodeActive) throws {
        let data = Data("\(bundle.path(percentEncoded: false))\n".utf8)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try WriteRefused.catching(file) {
            try data.write(to: file, options: .atomic)
        }
    }

    static func clearChoice(file: URL = SupportPaths.xcodeActive) throws {
        try FileManager.default.removeItem(at: file)
    }

    // One row per Xcode the user may want to point Game Mode at: the
    // xcode-select target when it lives outside the searched folders, then the
    // Applications folders, then copies the user added.
    static func discover(
        roots: [URL] = searchRoots,
        runner: CommandRunner = GamePolicyCtl.run,
        defaults: UserDefaults = .standard
    ) -> [XcodeInstall] {
        var seen: Set<String> = []
        var selected: [XcodeInstall] = []
        var found: [XcodeInstall] = []
        var manual: [XcodeInstall] = []

        func consider(_ bundle: URL, origin: XcodeInstall.Origin, into bucket: inout [XcodeInstall]) {
            let pathKey = key(bundle)
            guard !seen.contains(pathKey), looksLikeXcode(bundle) else { return }
            seen.insert(pathKey)
            bucket.append(inspect(bundle: bundle, origin: origin))
        }

        // One that xcode-select points at, when it lives outside the searched
        // folders. Inside them it shows up as a found copy, like any other.
        if let pick = selectedBundle(runner: runner), !isSearched(pick, in: roots) {
            consider(pick, origin: .selected, into: &selected)
        }

        let files = FileManager.default
        for root in roots {
            let entries = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app"
                && entry.deletingPathExtension().lastPathComponent.hasPrefix(xcodePrefix) {
                consider(entry, origin: .found, into: &found)
            }
        }

        for candidate in manualBundles(defaults) {
            consider(candidate, origin: .manual, into: &manual)
        }

        let byName: (XcodeInstall, XcodeInstall) -> Bool = { $0.name < $1.name }
        return selected + found.sorted(by: byName) + manual.sorted(by: byName)
    }

    // The Xcode the app and the run script both settle on: the user's recorded
    // choice when it still carries the tool, then the xcode-select target,
    // then the first found copy, preferring one that can run the tool. A
    // manual copy only comes in through an explicit choice.
    static func activeBundle(
        installs: [XcodeInstall] = discover(),
        file: URL = SupportPaths.xcodeActive
    ) -> XcodeInstall? {
        if let choice = readChoice(file: file),
           let chosen = installs.first(where: { same($0.bundle, choice) }),
           chosen.hasTool {
            return chosen
        }
        let system = installs.filter { $0.origin != .manual }
        return system.first(where: \.hasTool) ?? system.first
    }
}
