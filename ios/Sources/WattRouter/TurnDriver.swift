// TurnDriver.swift — running a turn, and keeping what it produced.
//
// History
//   2026-08-07  A. Sigdel  Created.
//
// Contents
//   TurnDriver  Sends text, folds the events, and records why a turn stopped.
//
// Small, and worth being a type with a name because it is where the failure path
// lives. `Agent.send` yields a throwing stream: a turn can end by finishing or by
// throwing, and the difference has to reach the transcript rather than a log
// nobody reads. A view that consumed the stream itself would be a view with a
// catch block in it.
//
// On the main actor because the transcript it writes is read by a view on every
// change. Streaming text at a few fragments a second is not work worth moving off
// it, and moving it would buy a hop back for every fragment.

import Foundation

/// Runs turns and keeps the transcript they produce.
@MainActor
@Observable
public final class TurnDriver {
    /// Everything said so far, as rows.
    public private(set) var transcript = Transcript()

    /// Whether a turn is in flight. A second `send` while one is running is
    /// ignored rather than queued: two turns over one conversation interleave
    /// their rounds, and the model is sent a transcript that never happened.
    public private(set) var isRunning = false

    /// How the current round was routed, or `nil` before the first one. Kept
    /// rather than folded into the transcript: it is replaced each round, and a
    /// row that rewrote itself would be a strange thing to scroll back through.
    public private(set) var routing: (decision: Decision, chain: [Step])?

    /// Whether a turn stopped when the app left the foreground and is waiting to
    /// be picked up.
    public var isInterrupted: Bool {
        if case .interrupted = transcript.rows.last { return true }
        return false
    }

    /// Whether the tier now answering is one that runs for minutes rather than
    /// seconds, and so is worth saying something about before somebody walks away
    /// from it. The cheap tiers do not need a warning and would be noise.
    public var isLong: Bool {
        switch routing?.decision.tier {
        case .heavy, .long: true
        default: false
        }
    }

    private let agent: Agent
    private var running: Task<Void, Never>?
    /// Counts turns started. `Task` is a value type, so this rather than identity
    /// is how a finishing turn tells whether it is still the current one.
    private var generation = 0

    public init(agent: Agent) {
        self.agent = agent
    }

    /// Say something, and run the turn it starts.
    ///
    /// # Rely
    /// Called from the main actor. Returns when the turn has finished or failed;
    /// the transcript is updated as events arrive rather than at the end, so a
    /// caller that does not await it still sees the answer stream in.
    ///
    /// # Atomic
    /// Refuses to start a second turn while one is running, so the transcript
    /// only ever has one open answer.
    public func send(_ text: String) async {
        guard !isRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        transcript.said(text)
        await run { await self.agent.send(text) }
    }

    /// Pick up a turn the app interrupted.
    ///
    /// # Rely
    /// Called on the main actor, and only when `isInterrupted`. A round commits
    /// atomically, so an interrupted turn left the conversation ending at the
    /// person's own message — this asks it again rather than repairing anything,
    /// and asks it once, because `send` would append that message a second time.
    public func resume() async {
        guard !isRunning, transcript.resumed() else { return }
        await run { await self.agent.resume() }
    }

    /// Stop the turn in flight and say that it stopped, rather than leaving half
    /// an answer that looks finished.
    ///
    /// # Rely
    /// Called when the app leaves the foreground. Cancelling the task terminates
    /// the stream, which cancels the request behind it.
    public func interrupt() {
        guard isRunning else { return }
        running?.cancel()
        running = nil
        isRunning = false
        transcript.interrupted()
    }

    /// Consume one turn's stream, whichever way it was started.
    private func run(
        _ start: @escaping @Sendable () async -> AsyncThrowingStream<TurnEvent, any Error>
    ) async {
        isRunning = true
        generation += 1
        let mine = generation
        let task = Task { [weak self] in
            do {
                for try await event in await start() {
                    guard let self, !Task.isCancelled else { return }
                    if case .decided(let decision, let chain) = event {
                        self.routing = (decision, chain)
                    }
                    self.transcript.apply(event)
                }
            } catch {
                // The reason, not the type. A person reading this has no use for
                // a case name, and `AgentError` already writes itself out in
                // words. A cancelled turn is not a failure and says nothing here:
                // `interrupt` has already recorded what happened.
                guard let self, !Task.isCancelled else { return }
                self.transcript.failed(error.localizedDescription)
            }
        }
        running = task
        await task.value
        // An interrupted turn has already been replaced, or superseded by the one
        // that resumed it. Only a turn that ran to its own end is still current.
        if generation == mine {
            running = nil
            isRunning = false
        }
    }
}
