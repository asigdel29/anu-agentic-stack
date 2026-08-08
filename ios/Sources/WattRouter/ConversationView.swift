// ConversationView.swift — the transcript, on a screen.
//
// History
//   2026-08-07  A. Sigdel  Created.
//
// Contents
//   ConversationView  The rows, and a field to add to them.
//
// It renders rows and makes no decisions: which text belongs to which answer, and
// what a half-finished turn looks like, were both settled by `Transcript` where
// they could be tested. What is left here is colour, spacing and a scroll
// position.
//
// The palette is `Theme`, dark only. Signal carries what the person and the model
// said, cyan marks a tool — the app talking about itself rather than to anyone —
// and error is the row that says why a turn stopped.

import SwiftUI

/// The transcript, and a field to add to it.
public struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var driver: TurnDriver
    @State private var draft = ""

    /// - Parameter driver: the turn runner, already holding an agent.
    public init(driver: TurnDriver) {
        _driver = State(initialValue: driver)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Above the transcript rather than below it: it describes the round
            // being answered, and a person watching text arrive is looking at the
            // top of the newest answer, not the bottom of the screen.
            if let routing = driver.routing {
                RoutingPanel(decision: routing.decision, chain: routing.chain)
                Rectangle()
                    .fill(Theme.cyan.color.opacity(0.25))
                    .frame(height: 1)
            }
            rows
            // Only for the tiers that run for minutes. On a cheap turn this would
            // be a warning about nothing, and a warning about nothing is one
            // people learn to scroll past.
            if driver.isRunning, driver.isLong {
                Text("this tier takes minutes — leaving the app stops it")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.cyan.color.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .background(Theme.ground.color)
        // Dark only, so the system's own controls match rather than fight it.
        .preferredColorScheme(.dark)
        // A turn outlives the foreground by seconds and takes minutes, so leaving
        // is the end of it. Stopping deliberately and saying so beats being
        // suspended partway and coming back to an answer that stopped mid-word
        // with nothing to say it had.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { driver.interrupt() }
        }
    }

    private var rows: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(driver.transcript.rows) { row in
                        view(of: row).id(row.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follow the newest row as text arrives. Keyed on the last row's
            // identity and its length, so a row that grows scrolls too — an id
            // alone would stop following once the final row had appeared.
            .onChange(of: driver.transcript.rows.count) { _, _ in scroll.scrollTo(lastID) }
            .onChange(of: lastLength) { _, _ in scroll.scrollTo(lastID) }
        }
    }

    private var lastID: Int? { driver.transcript.rows.last?.id }

    private var lastLength: Int {
        switch driver.transcript.rows.last {
        case .answered(_, _, let text): text.count
        default: 0
        }
    }

    @ViewBuilder
    private func view(of row: TranscriptRow) -> some View {
        switch row {
        case .said(_, let text):
            label("you", Theme.cyan)
            Text(text).foregroundStyle(Theme.signal.color)

        case .answered(_, let model, let text):
            label(model ?? "answering", Theme.cyan)
            Text(text).foregroundStyle(Theme.signal.color)

        case .used(_, let tool, let result):
            HStack(spacing: 8) {
                // A tool that has not finished says so, because the gap between
                // asking and answering is the part a person is waiting through.
                if result == nil { ProgressView().tint(Theme.cyan.color) }
                Text(result == nil ? "\(tool)…" : tool)
                    .foregroundStyle(Theme.cyan.color)
            }
            .font(.footnote.monospaced())
            if let result {
                Text(result)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.cyan.color.opacity(0.7))
            }

        case .failed(_, let reason):
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Theme.error.color)

        case .interrupted:
            // Cyan and not error: a turn that stopped because the app went away
            // is waiting rather than broken, and colouring it like a failure
            // would tell somebody their work is gone when it is not.
            Button {
                Task { await driver.resume() }
            } label: {
                Text("stopped when the app went away — continue")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.cyan.color)
            }
            .disabled(driver.isRunning)
        }
    }

    private func label(_ text: String, _ ink: Theme.Ink) -> some View {
        Text(text.uppercased())
            .font(.caption2.monospaced())
            .foregroundStyle(ink.color.opacity(0.7))
    }

    private var composer: some View {
        VStack(spacing: 0) {
            // The transcript and the field are both text on the same ground, so
            // without a line between them the field reads as another row.
            Rectangle()
                .fill(Theme.cyan.color.opacity(0.25))
                .frame(height: 1)

            HStack(spacing: 12) {
                // A prompt, because an empty plain field on near-black is
                // invisible — the first build of this screen looked like a
                // transcript with a stray button under it.
                TextField(
                    "",
                    text: $draft,
                    prompt: Text("say something").foregroundStyle(Theme.signal.color.opacity(0.4)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .foregroundStyle(Theme.signal.color)
                .tint(Theme.signal.color)
                .disabled(driver.isRunning)

                Button("send") { send() }
                    .font(.callout.monospaced())
                    .foregroundStyle(canSend ? Theme.signal.color : Theme.signal.color.opacity(0.3))
                    .disabled(!canSend)
            }
            .padding(16)
        }
        .background(Theme.ground.color)
    }

    private var canSend: Bool {
        !driver.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await driver.send(text) }
    }
}
