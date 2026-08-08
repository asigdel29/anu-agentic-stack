// Transcript.swift — turning a stream of events into something a person reads.
//
// History
//   2026-08-07  A. Sigdel  Created.
//
// Contents
//   TranscriptRow  One thing on screen.
//   Transcript     The rows so far, and the fold that produces them.
//
// A `TurnEvent` stream is not a transcript. Text arrives in fragments and belongs
// to whichever assistant turn is open; a call and its result are two events about
// one thing; a turn can fail after some of it has been shown. Folding that into
// rows is a state machine, and a state machine inside a `View` is one that can
// only be checked by looking at a screen.
//
// So this holds no SwiftUI and knows nothing about drawing. It is tested against
// event sequences, including the ones that are awkward rather than typical: text
// before any model has announced itself, a call whose result never arrives, two
// rounds of tools in one turn, and a failure partway that must leave what was
// already shown intact.

import Foundation

/// One thing on screen.
public enum TranscriptRow: Equatable, Sendable, Identifiable {
    /// What the person said.
    case said(id: Int, text: String)
    /// What a model answered. Open while text is still arriving.
    case answered(id: Int, model: String?, text: String)
    /// A tool the model asked for, and what it produced once it has.
    case used(id: Int, tool: String, result: String?)
    /// Why the turn stopped. Terminal for that turn, and never removed: a person
    /// who saw half an answer is owed the reason the rest never came.
    case failed(id: Int, reason: String)
    /// The turn stopped because the app went away, and can be picked up again.
    /// Distinct from `failed` because the two ask different things of a reader:
    /// one is over, and this one is waiting.
    case interrupted(id: Int)

    public var id: Int {
        switch self {
        case .said(let id, _), .answered(let id, _, _), .used(let id, _, _),
            .failed(let id, _), .interrupted(let id):
            id
        }
    }
}

/// The rows so far.
///
/// # Atomic
/// Not thread-safe and not meant to be. One turn writes to it, from whichever
/// context is consuming the stream, and an interface reads it from the main
/// actor after each change.
public struct Transcript: Equatable, Sendable {
    /// Every row, oldest first.
    public private(set) var rows: [TranscriptRow] = []

    /// Row ids are positions in a sequence rather than in `rows`, so a row that
    /// changes keeps its identity and a list does not animate it as a new one.
    private var nextID = 0

    public init() {}

    /// Record something the person said, which also closes any open answer.
    ///
    /// A turn that is still streaming when the next thing is said has ended as
    /// far as the transcript is concerned; leaving it open would append the next
    /// model's text to the last one's paragraph.
    public mutating func said(_ text: String) {
        openAnswer = nil
        rows.append(.said(id: take(), text: text))
    }

    /// Fold one event in.
    public mutating func apply(_ event: TurnEvent) {
        switch event {
        case .answering(let model, _):
            // A model announcing itself opens an answer, or names one that text
            // already opened. `ChainWalk` sends this before any text, but a
            // fragment arriving first is not worth losing.
            if let index = openAnswer, case .answered(let id, _, let text) = rows[index] {
                rows[index] = .answered(id: id, model: model, text: text)
            } else {
                openAnswer = rows.count
                rows.append(.answered(id: take(), model: model, text: ""))
            }

        case .text(let fragment):
            if let index = openAnswer, case .answered(let id, let model, let text) = rows[index] {
                rows[index] = .answered(id: id, model: model, text: text + fragment)
            } else {
                openAnswer = rows.count
                rows.append(.answered(id: take(), model: nil, text: fragment))
            }

        case .toolCall(let call):
            // Closes the answer: text after a call belongs to the next round, and
            // appending it to the paragraph before would read as one thought.
            openAnswer = nil
            rows.append(.used(id: take(), tool: call.name, result: nil))

        case .decided:
            // Not a row. How a turn was routed is the app describing itself, and
            // belongs beside the transcript rather than inside it — a person
            // reading back through what was said should not have to step over it.
            break

        case .toolResult(let result):
            // Fills in the earliest call still waiting. Tools run in order, so
            // the earliest unanswered call is the one this answers.
            if let index = rows.firstIndex(where: {
                if case .used(_, _, let filled) = $0 { return filled == nil }
                return false
            }), case .used(let id, let tool, _) = rows[index] {
                rows[index] = .used(id: id, tool: tool, result: result.content)
            }
        }
    }

    /// Record that the turn was cut short by the app leaving the foreground.
    ///
    /// Appends nothing if the last row already says so, because coming back and
    /// leaving again should not stack up notices about the same stopped turn.
    public mutating func interrupted() {
        openAnswer = nil
        if case .interrupted = rows.last { return }
        rows.append(.interrupted(id: take()))
    }

    /// Drop the interruption notice, for a turn that is being picked up again.
    ///
    /// - Returns: whether there was one to drop, which is also the answer to
    ///   whether there is a turn worth resuming.
    @discardableResult
    public mutating func resumed() -> Bool {
        guard case .interrupted = rows.last else { return false }
        rows.removeLast()
        // The answer it interrupted is open again, so text arriving next
        // continues the paragraph rather than starting a second one.
        if case .answered = rows.last { openAnswer = rows.count - 1 }
        return true
    }

    /// Record why the turn stopped, leaving everything already shown in place.
    public mutating func failed(_ reason: String) {
        openAnswer = nil
        rows.append(.failed(id: take(), reason: reason))
    }

    /// Index into `rows` of the answer still being written, if any.
    private var openAnswer: Int?

    private mutating func take() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
