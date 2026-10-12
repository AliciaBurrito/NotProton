// Simple logic

import Darwin
import Foundation

func atomicReplace(_ destination: URL, from source: URL, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: source, to: staging)

    // A non-empty directory destination cannot be renamed over: rename(2) fails
    // with ENOTEMPTY. When the source is also a directory (a bundle such as
    // notify.app), remove the old copy first so the new one can take its place.
    // A file source onto a directory destination is left to rename(2), which
    // rejects it and preserves the destination.
    var existing = stat()
    var sourceInfo = stat()
    if lstat(destination.path(percentEncoded: false), &existing) == 0,
        existing.st_mode & S_IFMT == S_IFDIR,
        lstat(source.path(percentEncoded: false), &sourceInfo) == 0,
        sourceInfo.st_mode & S_IFMT == S_IFDIR {
        try fm.removeItem(at: destination)
    }

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let code = errno
        if code == EACCES || code == EPERM {
            throw WriteRefused(path: destination.path(percentEncoded: false))
        }
        let reason = String(cString: strerror(code))
        throw StepFailure(
            step: step,
            detail: "Replacing \(destination.path(percentEncoded: false)) failed. \(reason)"
        )
    }
}

func atomicReplace(_ destination: URL, with data: Data, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).new")
    try? fm.removeItem(at: staging)

    do {
        try data.write(to: staging)
    } catch {
        throw StepFailure(
            step: step,
            detail: "\(staging.path(percentEncoded: false)) could not be written. "
                + error.localizedDescription
        )
    }

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let reason = String(cString: strerror(errno))
        try? fm.removeItem(at: staging)
        throw StepFailure(
            step: step,
            detail: "Replacing \(destination.path(percentEncoded: false)) failed. \(reason)"
        )
    }
}
