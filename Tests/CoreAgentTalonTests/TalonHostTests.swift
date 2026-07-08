import CoreAgent
import CoreAgentTalon
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Generable
private struct TalonBlockingArguments: Sendable {
  let value: String
}

private struct TalonBlockingTool: Tool {
  let gate: TalonBlockingToolGate
  let name = "talon_block"
  let description = "Blocks a run until the test releases it."

  @concurrent
  func call(arguments: TalonBlockingArguments) async throws -> String {
    await gate.markStarted(arguments.value)
    await gate.waitForRelease()
    return arguments.value
  }
}

private actor TalonBlockingToolGate {
  private var startedValues: [String] = []
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var availableReleases = 0

  var starts: [String] {
    startedValues
  }

  func markStarted(_ value: String) {
    startedValues.append(value)
    let ready = startWaiters.filter { startedValues.count >= $0.0 }
    startWaiters.removeAll { startedValues.count >= $0.0 }
    for waiter in ready {
      waiter.1.resume()
    }
  }

  func waitForStarts(_ count: Int) async {
    guard startedValues.count < count else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func waitForRelease() async {
    if availableReleases > 0 {
      availableReleases -= 1
      return
    }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func releaseOne() {
    if releaseWaiters.isEmpty {
      availableReleases += 1
      return
    }
    releaseWaiters.removeFirst().resume()
  }
}

@Suite("CoreAgentTalon host lifecycle")
struct TalonHostTests {
  @Test("Serializes runs per conversation while allowing distinct conversations")
  func perConversationSerialization() async throws {
    let conversation = CoreAgentTalonConversationID("conversation-a")
    let firstGate = TalonBlockingToolGate()
    let firstModel = RecordedLanguageModel(steps: [
      .toolCall(name: "talon_block", argumentsJSON: #"{"value":"first"}"#),
      .response(text: "first done"),
      .response(text: "second done"),
    ])
    let firstSession = try CoreAgentSession(
      model: firstModel,
      tools: [TalonBlockingTool(gate: firstGate)]
    )
    let host = CoreAgentTalonHost { id in
      #expect(id == conversation)
      return firstSession
    }

    let firstRun = Task {
      await host.respond(to: "first", conversationID: conversation)
    }
    await firstGate.waitForStarts(1)

    let secondRun = Task {
      await host.respond(to: "second", conversationID: conversation)
    }
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(firstModel.recorder.capturedTranscripts().count == 1)

    await firstGate.releaseOne()
    let firstResult = await firstRun.value
    #expect(firstResult.status == .completed)
    #expect(firstResult.content == "first done")

    let secondResult = await secondRun.value
    #expect(secondResult.status == .completed)
    #expect(secondResult.content == "second done")
    #expect(firstModel.recorder.capturedTranscripts().count == 3)

    let siblingA = CoreAgentTalonConversationID("sibling-a")
    let siblingB = CoreAgentTalonConversationID("sibling-b")
    let gateA = TalonBlockingToolGate()
    let gateB = TalonBlockingToolGate()
    let modelA = RecordedLanguageModel(steps: [
      .toolCall(name: "talon_block", argumentsJSON: #"{"value":"a"}"#),
      .response(text: "a done"),
    ])
    let modelB = RecordedLanguageModel(steps: [
      .toolCall(name: "talon_block", argumentsJSON: #"{"value":"b"}"#),
      .response(text: "b done"),
    ])
    let sessionA = try CoreAgentSession(model: modelA, tools: [TalonBlockingTool(gate: gateA)])
    let sessionB = try CoreAgentSession(model: modelB, tools: [TalonBlockingTool(gate: gateB)])
    let sessions = [siblingA: sessionA, siblingB: sessionB]
    let independentHost = CoreAgentTalonHost { id in
      try #require(sessions[id])
    }

    let runA = Task { await independentHost.respond(to: "a", conversationID: siblingA) }
    await gateA.waitForStarts(1)
    let runB = Task { await independentHost.respond(to: "b", conversationID: siblingB) }
    await gateB.waitForStarts(1)

    #expect(await gateA.starts == ["a"])
    #expect(await gateB.starts == ["b"])
    await gateA.releaseOne()
    await gateB.releaseOne()
    #expect(await runA.value.content == "a done")
    #expect(await runB.value.content == "b done")
  }

  @Test("Stop cancels an in-flight run without killing the host")
  func stopCancelsInFlightRun() async throws {
    let conversation = CoreAgentTalonConversationID("conversation-stop")
    let model = RecordedLanguageModel(steps: [
      .delayedResponse(text: "late", delay: .seconds(5)),
      .response(text: "after stop"),
    ])
    let session = try CoreAgentSession(model: model)
    let host = CoreAgentTalonHost { _ in session }

    let running = Task {
      await host.respond(to: "slow", conversationID: conversation)
    }
    while model.recorder.capturedTranscripts().isEmpty {
      await Task.yield()
    }

    let stopResult = await host.stop(conversationID: conversation)
    #expect(stopResult.status == .cancelled)
    #expect(await running.value.status == .cancelled)

    let later = await host.respond(to: "later", conversationID: conversation)
    #expect(later.status == .completed)
    #expect(later.content == "after stop")
  }

  @Test("New rotates the conversation id and resets only that session")
  func newResetsConversation() async throws {
    let original = CoreAgentTalonConversationID("conversation-old")
    let rotated = CoreAgentTalonConversationID("conversation-new")
    let sibling = CoreAgentTalonConversationID("conversation-sibling")
    let originalModel = RecordedLanguageModel(steps: [
      .response(text: "old first"),
      .response(text: "new first"),
    ])
    let siblingModel = RecordedLanguageModel(steps: [
      .response(text: "sibling first"),
      .response(text: "sibling second"),
    ])
    let originalSession = try CoreAgentSession(model: originalModel)
    let siblingSession = try CoreAgentSession(model: siblingModel)
    let sessions = [original: originalSession, sibling: siblingSession]
    let host = CoreAgentTalonHost(
      conversationIDGenerator: { _ in rotated },
      sessionFactory: { id in try #require(sessions[id]) }
    )

    #expect(await host.respond(to: "old one", conversationID: original).content == "old first")
    #expect(
      await host.respond(to: "sibling one", conversationID: sibling).content == "sibling first")

    let newID = try await host.newConversation(replacing: original)
    #expect(newID == rotated)
    #expect(await host.respond(to: "new one", conversationID: newID).content == "new first")
    #expect(
      await host.respond(to: "sibling two", conversationID: sibling).content == "sibling second")

    let originalTranscripts = originalModel.recorder.capturedTranscripts()
    let siblingTranscripts = siblingModel.recorder.capturedTranscripts()
    #expect(originalTranscripts.map(promptCount) == [1, 1])
    #expect(siblingTranscripts.map(promptCount) == [1, 2])
  }

  @Test("Concurrent first responses for one id create exactly one session")
  func concurrentFirstRespondCreatesSingleSession() async throws {
    let conversation = CoreAgentTalonConversationID("conversation-race")
    let factoryGate = TalonBlockingToolGate()
    let factoryCalls = TalonFactoryCallCounter()

    let host = CoreAgentTalonHost { id in
      // Count and block the first creation so a second concurrent caller for the same id
      // reaches `conversation(for:)` while the first is still suspended in the factory.
      await factoryCalls.record(id)
      await factoryGate.markStarted(id.rawValue)
      await factoryGate.waitForRelease()
      let model = RecordedLanguageModel(steps: [
        .response(text: "one"),
        .response(text: "two"),
      ])
      return try CoreAgentSession(model: model)
    }

    let first = Task { await host.respond(to: "first", conversationID: conversation) }
    await factoryGate.waitForStarts(1)
    let second = Task { await host.respond(to: "second", conversationID: conversation) }
    // Give the second task ample opportunity to race into conversation(for:).
    for _ in 0..<50 { await Task.yield() }

    await factoryGate.releaseOne()
    let firstResult = await first.value
    let secondResult = await second.value

    #expect(firstResult.status == .completed)
    #expect(secondResult.status == .completed)
    // The factory must have been invoked exactly once despite two concurrent first calls.
    #expect(await factoryCalls.count(conversation) == 1)
    // Both runs share the single session, so the two prompts are serialized on it.
    #expect(Set([firstResult.content, secondResult.content]) == ["one", "two"])
  }

  @Test("Concurrent new for one source rotates exactly once and never aliases the session")
  func concurrentNewReplacesSourceExactlyOnce() async throws {
    let source = CoreAgentTalonConversationID("conversation-source")
    // A stateful generator that hands out a *distinct* id per call. This is the case the
    // default (random UUID) generator hits: two concurrent replacements of the same source
    // mint different new ids, so the pre-fix re-validation guard (which only checks the new
    // id) cannot catch the alias — both would rotate the shared source conversation and the
    // host map would end up with two keys aliased onto one conversation actor.
    let ids = TalonIDSequence(["conversation-new-1", "conversation-new-2"])
    // Gate the source factory so the first replacement parks inside its critical section
    // (holding the claim) while the second runs its guard: a deterministic race.
    let factoryGate = TalonBlockingToolGate()
    let host = CoreAgentTalonHost(
      conversationIDGenerator: { _ in ids.next() },
      sessionFactory: { id in
        await factoryGate.markStarted(id.rawValue)
        await factoryGate.waitForRelease()
        return try CoreAgentSession(
          model: RecordedLanguageModel(steps: [.response(text: "after reset")]))
      }
    )

    // Race two replacements of the same (not-yet-created) source. Capture each outcome as a
    // Result so a fail-closed rejection does not tear down the test.
    func attempt() -> Task<Result<CoreAgentTalonConversationID, any Error>, Never> {
      Task {
        do { return .success(try await host.newConversation(replacing: source)) } catch {
          return .failure(error)
        }
      }
    }
    let first = attempt()
    // Wait until the first replacement is suspended inside the source factory, holding its
    // claim on `source`, before starting the second.
    await factoryGate.waitForStarts(1)
    let second = attempt()
    // Give the second task ample opportunity to reach its guard / coalesce onto the factory.
    for _ in 0..<50 { await Task.yield() }
    await factoryGate.releaseOne()

    let results = [await first.value, await second.value]
    let successes = results.compactMap { try? $0.get() }
    let failures = results.filter { if case .failure = $0 { return true } else { return false } }
    // Exactly one replacement wins; the other fails closed with a duplicate/claim error.
    #expect(successes.count == 1)
    #expect(failures.count == 1)

    // The host must expose exactly one active conversation: the single winning new id, and
    // never the source. Pre-fix, both callers succeeded and the map held two aliased keys.
    let active = await host.activeConversationIDs()
    #expect(active.count == 1)
    #expect(!active.contains(source))
    let winningID = try #require(successes.first)
    #expect(active == [winningID])
  }
}

/// Thread-safe id dispenser: returns each provided id once, in order, then repeats the last.
private final class TalonIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: [CoreAgentTalonConversationID]
  private let fallback: CoreAgentTalonConversationID

  init(_ raw: [String]) {
    let ids = raw.map(CoreAgentTalonConversationID.init(_:))
    self.remaining = ids
    self.fallback = ids.last ?? CoreAgentTalonConversationID("conversation-fallback")
  }

  func next() -> CoreAgentTalonConversationID {
    lock.lock()
    defer { lock.unlock() }
    guard !remaining.isEmpty else { return fallback }
    return remaining.removeFirst()
  }
}

private actor TalonFactoryCallCounter {
  private var counts: [CoreAgentTalonConversationID: Int] = [:]

  func record(_ id: CoreAgentTalonConversationID) {
    counts[id, default: 0] += 1
  }

  func count(_ id: CoreAgentTalonConversationID) -> Int {
    counts[id, default: 0]
  }
}

private func promptCount(in transcript: Transcript) -> Int {
  transcript.reduce(into: 0) { count, entry in
    if case .prompt = entry {
      count += 1
    }
  }
}
