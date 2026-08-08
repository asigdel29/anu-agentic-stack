// InterruptionTests.swift — a turn cut short, and picked up again.
//
// History
//   2026-08-07  A. Sigdel  Created.
//
// Background time is not the same on a simulator as on a device, and neither is
// the moment the system decides to suspend, so none of that is tested here. What
// is ours is the part these cover: that an interrupted turn says so rather than
// looking finished, that the conversation is left re-askable, and that resuming
// asks the question once.

import Foundation
import XCTest

@testable import WattRouter

@MainActor
final class InterruptionTests: XCTestCase {
    /// Slow enough that a turn is reliably still running when it is interrupted.
    private func slowInference() -> ScriptedInference {
        ScriptedInference(chunks: ["one ", "two ", "three"], perChunk: .milliseconds(300))
    }

    private func makeAgent(_ inference: any Inference) throws -> Agent {
        Agent(router: try makeRouter(), inference: inference, tools: ToolBox([]))
    }

    func testAnInterruptedTurnSaysSoRatherThanLookingFinished() async throws {
        let driver = TurnDriver(agent: try makeAgent(slowInference()))

        let running = Task { await driver.send("hello") }
        try await Task.sleep(for: .milliseconds(400))
        driver.interrupt()
        await running.value

        XCTAssertTrue(driver.isInterrupted, "the turn stopped and said nothing")
        XCTAssertFalse(driver.isRunning, "an interrupted turn left the driver looking busy")
    }

    func testWhatArrivedBeforeTheInterruptionIsKept() async throws {
        let driver = TurnDriver(agent: try makeAgent(slowInference()))

        let running = Task { await driver.send("hello") }
        try await Task.sleep(for: .milliseconds(400))
        driver.interrupt()
        await running.value

        // The first fragment is on screen. Throwing it away would lose text
        // somebody was already reading.
        let answered = driver.transcript.rows.contains {
            if case .answered(_, _, let text) = $0 { return !text.isEmpty }
            return false
        }
        XCTAssertTrue(answered, "the partial answer vanished: \(driver.transcript.rows)")
    }

    func testTheConversationIsLeftAskableAgain() async throws {
        // A round commits atomically, so an interrupted turn leaves the
        // conversation ending at the person's own message. That is the property
        // resumption rests on, and it is worth pinning rather than assuming.
        let agent = try makeAgent(slowInference())
        let driver = TurnDriver(agent: agent)

        let running = Task { await driver.send("hello") }
        try await Task.sleep(for: .milliseconds(400))
        driver.interrupt()
        await running.value

        let messages = await agent.conversation.messages
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "hello")
        XCTAssertEqual(
            messages.filter { $0.role == .user }.count, 1,
            "the question was recorded more than once")
    }

    func testResumingAsksTheQuestionOnceRatherThanTwice() async throws {
        let agent = try makeAgent(slowInference())
        let driver = TurnDriver(agent: agent)

        let running = Task { await driver.send("hello") }
        try await Task.sleep(for: .milliseconds(400))
        driver.interrupt()
        await running.value

        await driver.resume()

        let messages = await agent.conversation.messages
        XCTAssertEqual(
            messages.filter { $0.role == .user }.count, 1,
            "resuming appended the question a second time")
        XCTAssertFalse(driver.isInterrupted, "still interrupted after resuming")
        XCTAssertFalse(driver.isRunning)
    }

    func testResumingWithNothingToResumeDoesNothing() async throws {
        let driver = TurnDriver(agent: try makeAgent(ScriptedInference(chunks: ["a"])))
        await driver.resume()
        XCTAssertTrue(driver.transcript.rows.isEmpty)
    }

    func testLeavingTwiceDoesNotStackUpNotices() async throws {
        let driver = TurnDriver(agent: try makeAgent(slowInference()))

        let running = Task { await driver.send("hello") }
        try await Task.sleep(for: .milliseconds(400))
        driver.interrupt()
        await running.value
        driver.interrupt()

        let notices = driver.transcript.rows.filter {
            if case .interrupted = $0 { return true }
            return false
        }
        XCTAssertEqual(notices.count, 1, "coming back and leaving again stacked notices")
    }
}
