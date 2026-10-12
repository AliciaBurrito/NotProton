// 'Enhancements' view, see SystemStatus for actual logic
//
// The same page chrome as Status, but it only presents the Game Mode options.

import AppKit
import SwiftUI

struct EnhancementsView: View {
    @Environment(SystemStatus.self) private var status

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                form(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Enhancements")
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .task { if status.snapshot == nil { await status.refresh() } }
        .confirmationDialog(
            status.pendingXcodeRemoval.map {
                "Remove \($0.deletingPathExtension().lastPathComponent) from the list?"
            } ?? "",
            isPresented: asking(.removeXcode),
            titleVisibility: .visible
        ) {
            Button("Remove Copy", role: .destructive) {
                Task { await status.removePendingXcode() }
            }
            Button("Cancel", role: .cancel) { status.cancelXcodeRemoval() }
        } message: {
            Text("Xcode itself is not removed.")
        }
    }

    // Only show feedback generated for this page (the Game Mode feedback), so
    // Status-page feedback (e.g. "Steam client updates are blocked") stays on Status.
    private var showsFeedback: Bool { status.feedbackPane == .enhancements }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            if showsFeedback {
                if let failure = status.failure {
                    StatusRow(
                        title: "Failed",
                        value: failure,
                        tone: .bad,
                        action: status.failureRemedy?.settingsPane.map { pane in
                            StatusAction(label: Remedy.settingsButton) {
                                Remedy.openSettings(pane)
                            }
                        }
                    )
                } else if let outcome = status.outcome {
                    StatusRow(title: "Done", value: outcome, tone: .ok)
                }
            }

            if showsFeedback, let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
            }

            gameModeSection(snapshot.gameMode)
        }
        .formStyle(.grouped)
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await status.refresh() }
        }
        .disabled(!status.isIdle)
    }

    @ViewBuilder
    private func gameModeSection(_ state: GameModeState) -> some View {
        Section {
            xcodeRows(state)
            gameModeToggleRow(state)
            currentGameModeRow(state)
        } header: {
            Text("Game Mode")
        } footer: {
            HStack {
                Spacer()
                Button("Add Xcode\u{2026}") { Task { await status.addXcode() } }
                    .disabled(!status.isIdle)
                    .help("Add a copy of Xcode from another folder.")
            }
        }
    }

    @ViewBuilder
    private func xcodeRows(_ state: GameModeState) -> some View {
        if state.xcodes.isEmpty {
            StatusRow(
                title: "Xcode",
                value: "Not found.",
                tone: .bad,
                detail: "Required to enable Game Mode for unsupported games.",
                action: StatusAction(
                    label: "Get Xcode",
                    isProminent: true,
                ) {
                    NSWorkspace.shared.open(XcodeSource.appStoreURL)
                }
            )
        } else {
            ForEach(state.xcodes) { install in
                xcodeRow(install, state)
            }
        }
    }

    private func xcodeRow(_ install: XcodeInstall, _ state: GameModeState) -> some View {
        StatusRow(
            title: install.name,
            value: xcodeRowValue(install, state),
            tone: xcodeRowTone(install, state),
            detail: install.bundle.path(percentEncoded: false),
            action: xcodeRowAction(install, state),
            menu: xcodeRowMenu(install)
        )
    }

    private func xcodeRowValue(_ install: XcodeInstall, _ state: GameModeState) -> String {
        var value = install.version.map { "Version \($0)" } ?? "Version unknown"
        if state.xcode == install {
            value += ", in use"
        }
        if !install.hasTool {
            value += ", no gamepolicyctl"
        }
        return value
    }

    private func xcodeRowTone(_ install: XcodeInstall, _ state: GameModeState) -> StatusTone {
        if !install.hasTool { return .warning }
        if state.xcode == install { return .ok }
        return .neutral
    }

    private func xcodeRowAction(_ install: XcodeInstall, _ state: GameModeState) -> StatusAction? {
        guard install.hasTool, state.xcode != install else { return nil }
        return StatusAction(
            label: "Set Up",
            isProminent: true,
            help: "Use \(install.name) for Game Mode.",
            isEnabled: status.isIdle
        ) { Task { await status.setUpXcode(install) } }
    }

    private func xcodeRowMenu(_ install: XcodeInstall) -> [StatusAction] {
        var items: [StatusAction] = [
            StatusAction(label: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([install.bundle])
            }
        ]
        if install.origin == .manual {
            items.append(StatusAction(
                label: "Remove Copy\u{2026}",
                role: .destructive,
                help: "Remove \(install.name) from the list.",
                isEnabled: status.isIdle,
                startsGroup: true
            ) { status.requestXcodeRemoval(install.bundle) })
        }
        return items
    }

    private func gameModeToggleRow(_ state: GameModeState) -> some View {
        Toggle(isOn: gameModeOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Game Mode for unsupported games")
                    .font(.headline)
                Text(gameModeToggleDetail(state))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, StatusMetrics.textInset)
        }
        .disabled(!status.isIdle || !state.ready)
        .help(
            state.ready
                ? "Enables Game Mode support for unsupported games."
                : "Xcode is required to enable Game Mode for unsupported games."
        )
    }

    private var gameModeOn: Binding<Bool> {
        Binding(
            get: { status.snapshot?.gameMode.featureEnabled ?? true },
            set: { wanted in
                Task { await status.setGameModeEnabled(wanted) }
            }
        )
    }

    private func gameModeToggleDetail(_ state: GameModeState) -> String {
        guard state.ready else { return "Requires Xcode to be installed." }
        return state.featureEnabled
            ? "Game Mode will trigger for all games, including Windows games."
            : "Game Mode will only trigger for native macOS games."
    }

    @ViewBuilder
    private func currentGameModeRow(_ state: GameModeState) -> some View {
        StatusRow(
            title: "Game Mode Status",
            value: currentGameModeDescription(state),
            tone: currentGameModeTone(state)
        )
    }

    private func currentGameModeTone(_ state: GameModeState) -> StatusTone {
        switch state.onState {
        case .on: return .ok
        case .temporarilyOn: return .warning
        case .off: return .bad
        case .unknown: return .neutral
        }
    }

    private func currentGameModeDescription(_ state: GameModeState) -> String {
        switch (state.onState, state.policy) {
        case (.on, .manual): return "Game Mode is manually enabled."
        case (.on, .automatic): return "Game Mode is on for a native game."
        case (.on, .unknown): return "Game Mode is on."
        case (.temporarilyOn, _): return "Game Mode is temporarily on."
        case (.off, .manual): return "Game Mode is manually disabled."
        case (.off, _): return "Game Mode is off."
        case (.unknown, _): return "Unable to read Game Mode status."
        }
    }
}
