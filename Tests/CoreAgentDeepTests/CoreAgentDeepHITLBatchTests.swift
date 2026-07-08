import CoreAgent
import CoreAgentDeep
import CoreAgentGraph
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep graph-level batched HITL")
struct CoreAgentDeepHITLBatchTests {
  struct BatchState: Sendable, Equatable {
    var outputs: [String] = []
  }

  @Test("Graph node interrupts once with all review actions in order")
  func graphNodeInterruptsOnceWithBatchedReviewPayload() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try Self.makeBatchGraph(bundle: Self.reviewBundle()).compile(checkpointer: checkpointer)
    var streamedInterrupt: CoreAgentDeepHITLReviewBundle?

    do {
      for try await event in compiled.stream(BatchState(), threadID: "thread") {
        if case .interrupted(_, let interrupt, _) = event {
          streamedInterrupt = try interrupt.value.decode(as: CoreAgentDeepHITLReviewBundle.self)
        }
      }
      Issue.record("Expected batched HITL interrupt")
    } catch {
      guard case CoreAgentGraphRuntimeError.interrupted(let interrupt) = error else {
        Issue.record("Expected graph interrupt, got \(error)")
        return
      }
      let payload = try interrupt.value.decode(as: CoreAgentDeepHITLReviewBundle.self)
      #expect(interrupt.id == "deep-hitl")
      #expect(payload.actionRequests.map(\.toolCallID) == ["call-1", "call-2"])
      #expect(payload.reviewConfigs.map(\.actionName) == ["write_file", "ask_user"])
    }

    #expect(streamedInterrupt?.actionRequests.map(\.name) == ["write_file", "ask_user"])
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(checkpoint.nextNodeIDs == ["review"])
  }

  @Test("Resume decisions are applied in action order")
  func resumeDecisionsAreAppliedInActionOrder() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try Self.makeBatchGraph(bundle: Self.reviewBundle()).compile(checkpointer: checkpointer)

    await #expect(throws: (any Error).self) {
      _ = try await compiled.invoke(BatchState(), threadID: "thread")
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))

    let result = try await compiled.invoke(
      BatchState(outputs: ["ignored"]),
      threadID: "thread",
      checkpointID: checkpoint.id,
      command: try .resume(
        CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
          .edit(
            action: try Self.identity(for: Self.reviewBundle(), at: 0),
            name: "write_file",
            argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
          ),
          .respond(
            action: try Self.identity(for: Self.reviewBundle(), at: 1),
            message: "Use account ending in 1234."
          ),
        ])
      )
    )

    #expect(result.outputs == [
      #"execute:edit:write_file:{"path":"/safe/report.md","content":"approved"}"#,
      "synthetic:respond:ask_user:Use account ending in 1234.",
    ])
  }

  @Test("Same-tool edits keep reviewed identity without retarget authorization")
  func sameToolEditsKeepReviewedIdentityWithoutRetargetAuthorization() throws {
    let bundle = Self.reviewBundle()
    let identity = try Self.identity(for: bundle, at: 0)
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .edit(
        action: identity,
        name: "write_file",
        argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
      ),
      .respond(action: Self.identity(for: bundle, at: 1), message: "Use account ending in 1234."),
    ])

    let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: "deep-hitl"
    )
    guard case .execute(let action) = resolutions[0] else {
      Issue.record("Expected executable same-tool edit.")
      return
    }
    #expect(action.source == .edit)
    #expect(action.requestedName == "write_file")
    #expect(action.executableName == "write_file")
    #expect(action.requestedArgsJSON == #"{"path":"/tmp/report.md","content":"draft"}"#)
    #expect(action.executableArgsJSON == #"{"path":"/safe/report.md","content":"approved"}"#)
    #expect(action.reviewedActionIdentity == identity)
    #expect(action.editedTargetAuthorization == nil)
  }

  @Test("Invalid resume decisions fail closed before producing actions")
  func invalidResumeDecisionsFailClosed() async throws {
    let bundle = Self.reviewBundle()
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .reject(action: Self.identity(for: bundle, at: 0), message: "not allowed"),
      .approve(action: Self.identity(for: bundle, at: 1)),
    ])

    #expect(throws: CoreAgentDeepHITLError.decisionNotAllowed(
      toolName: "write_file",
      decision: .reject
    )) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Non-edit decisions cannot carry edited actions")
  func nonEditDecisionsCannotCarryEditedActions() throws {
    let bundle = Self.reviewBundle()
    let identity = try Self.identity(for: bundle, at: 0)
    let invalidDecision = try JSONDecoder().decode(
      CoreAgentDeepHITLBatchDecision.self,
      from: Data(
        """
        {
          "action": {
            "tool_call_id": "\(identity.toolCallID)",
            "action_digest": "\(identity.actionDigest)"
          },
          "type": "approve",
          "edited_action": {
            "name": "write_file",
            "args_json": "{\\"path\\":\\"/tmp/report.md\\",\\"content\\":\\"edited\\"}"
          }
        }
        """.utf8
      )
    )
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      invalidDecision,
      .respond(action: Self.identity(for: bundle, at: 1), message: "Use account ending in 1234."),
    ])

    #expect(throws: CoreAgentDeepHITLError.unexpectedEditedAction(
      toolName: "write_file",
      decision: .approve
    )) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Decision count must match action request count")
  func decisionCountMustMatchActionRequestCount() throws {
    let bundle = Self.reviewBundle()
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .approve(action: Self.identity(for: bundle, at: 0)),
    ])

    #expect(throws: CoreAgentDeepHITLError.decisionCountMismatch(expected: 2, actual: 1)) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Resume interrupt ID must match the pending review")
  func resumeInterruptIDMustMatchPendingReview() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try Self.makeBatchGraph(bundle: Self.reviewBundle()).compile(checkpointer: checkpointer)

    await #expect(throws: (any Error).self) {
      _ = try await compiled.invoke(BatchState(), threadID: "thread")
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))

    do {
      _ = try await compiled.invoke(
        BatchState(),
        threadID: "thread",
        checkpointID: checkpoint.id,
        command: try .resume(
          CoreAgentDeepHITLBatchResume(interruptID: "other-hitl", decisions: [
            .approve(action: Self.identity(for: Self.reviewBundle(), at: 0)),
            .respond(
              action: Self.identity(for: Self.reviewBundle(), at: 1),
              message: "Use account ending in 1234."
            ),
          ])
        )
      )
      Issue.record("Expected mismatched interrupt resume to re-interrupt")
    } catch {
      guard case CoreAgentGraphRuntimeError.interrupted(let interrupt) = error else {
        Issue.record("Expected graph interrupt, got \(error)")
        return
      }
      #expect(interrupt.id == "deep-hitl")
      let payload = try interrupt.value.decode(as: CoreAgentDeepHITLReviewBundle.self)
      #expect(payload.actionRequests.map(\.toolCallID) == ["call-1", "call-2"])
    }
  }

  @Test("Malformed resume payloads fail instead of re-interrupting")
  func malformedResumePayloadsFailInsteadOfReinterrupting() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try Self.makeBatchGraph(bundle: Self.reviewBundle()).compile(checkpointer: checkpointer)

    await #expect(throws: (any Error).self) {
      _ = try await compiled.invoke(BatchState(), threadID: "thread")
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))

    await #expect(throws: CoreAgentDeepHITLError.invalidBatchResumeValue(
      interruptID: "deep-hitl"
    )) {
      _ = try await compiled.invoke(
        BatchState(),
        threadID: "thread",
        checkpointID: checkpoint.id,
        command: try .resume("not-a-hitl-batch-resume")
      )
    }
  }

  @Test("Decision identities must match reviewed actions in order")
  func decisionIdentitiesMustMatchReviewedActions() throws {
    let bundle = Self.reviewBundle()
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .approve(action: Self.identity(for: bundle, at: 1)),
      .respond(action: Self.identity(for: bundle, at: 0), message: "Use account ending in 1234."),
    ])

    #expect(throws: CoreAgentDeepHITLError.decisionActionMismatch(
      expectedToolCallID: "call-1",
      actualToolCallID: "call-2"
    )) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Duplicate resume decisions fail before action production")
  func duplicateResumeDecisionsFailBeforeActionProduction() throws {
    let bundle = Self.reviewBundle()
    let duplicatedIdentity = try Self.identity(for: bundle, at: 0)
    let resume = CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .approve(action: duplicatedIdentity),
      .reject(action: duplicatedIdentity, message: "duplicate"),
    ])

    #expect(throws: CoreAgentDeepHITLError.duplicateResumeDecision(toolCallID: "call-1")) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Duplicate action requests fail before identities are issued")
  func duplicateActionRequestsFailBeforeIdentitiesAreIssued() throws {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/a.md"}"#,
          description: "Write first file.",
          toolCallID: "call-1"
        ),
        CoreAgentDeepHITLActionRequest(
          name: "ask_user",
          argsJSON: #"{"question":"Which account?"}"#,
          description: "Ask the user.",
          toolCallID: "call-1"
        ),
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(actionName: "write_file", allowedDecisions: [.approve]),
        CoreAgentDeepHITLReviewConfig(actionName: "ask_user", allowedDecisions: [.respond]),
      ]
    )

    #expect(throws: CoreAgentDeepHITLError.duplicateActionRequest(toolCallID: "call-1")) {
      _ = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)
    }
  }

  @Test("Action digest mismatch catches reviewed argument tampering")
  func actionDigestMismatchCatchesReviewedArgumentTampering() throws {
    let originalBundle = Self.singleWriteReviewBundle(allowedEditedActionNames: ["append_file"])
    let tamperedBundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/other.md","content":"draft"}"#,
          description: "Write a report file.",
          toolCallID: "call-1"
        )
      ],
      reviewConfigs: originalBundle.reviewConfigs
    )
    let resume = CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .edit(
        action: try Self.identity(for: originalBundle, at: 0),
        name: "append_file",
        argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
      )
    ])

    #expect(throws: CoreAgentDeepHITLError.decisionActionDigestMismatch(toolCallID: "call-1")) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: tamperedBundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Retargeted edit decisions require an explicit edited-target policy")
  func retargetedEditDecisionsRequireExplicitEditedTargetPolicy() throws {
    let bundle = Self.reviewBundle()
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .edit(
        action: Self.identity(for: bundle, at: 0),
        name: "delete_file",
        argsJSON: #"{"path":"/safe/report.md"}"#
      ),
      .respond(action: Self.identity(for: bundle, at: 1), message: "Use account ending in 1234."),
    ])

    #expect(throws: CoreAgentDeepHITLError.editedToolNameNotAllowed(
      reviewed: "write_file",
      edited: "delete_file",
      allowedEditedActionNames: []
    )) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Allowed retargeted edits preserve reviewed and executable identities")
  func allowedRetargetedEditsPreserveReviewedAndExecutableIdentities() throws {
    let bundle = Self.retargetableReviewBundle()
    let identity = try Self.identity(for: bundle, at: 0)
    let resume = CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .edit(
        action: identity,
        name: "append_file",
        argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
      )
    ])

    let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: "deep-hitl"
    )
    guard case .execute(let action) = try #require(resolutions.first) else {
      Issue.record("Expected executable retargeted action.")
      return
    }
    #expect(action.source == .edit)
    #expect(action.name == "append_file")
    #expect(action.executableName == "append_file")
    #expect(action.argsJSON == #"{"path":"/safe/report.md","content":"approved"}"#)
    #expect(action.executableArgsJSON == #"{"path":"/safe/report.md","content":"approved"}"#)
    #expect(action.requestedName == "write_file")
    #expect(action.requestedArgsJSON == #"{"path":"/tmp/report.md","content":"draft"}"#)
    #expect(action.toolCallID == "call-1")
    #expect(action.reviewedActionIdentity == identity)
    let authorization = try #require(action.editedTargetAuthorization)
    #expect(authorization.reviewedActionName == "write_file")
    #expect(authorization.editedActionName == "append_file")
    #expect(authorization.allowedEditedActionNames == ["append_file"])
    #expect(authorization.reviewedActionIdentity == identity)
  }

  @Test("Edited target policy participates in action identity")
  func editedTargetPolicyParticipatesInActionIdentity() throws {
    let plainBundle = Self.singleWriteReviewBundle(allowedEditedActionNames: [])
    let retargetableBundle = Self.singleWriteReviewBundle(allowedEditedActionNames: ["append_file"])
    let staleIdentity = try Self.identity(for: plainBundle, at: 0)
    let currentIdentity = try Self.identity(for: retargetableBundle, at: 0)
    #expect(staleIdentity.toolCallID == currentIdentity.toolCallID)
    #expect(staleIdentity.actionDigest != currentIdentity.actionDigest)

    let resume = CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .edit(
        action: staleIdentity,
        name: "append_file",
        argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
      )
    ])

    #expect(throws: CoreAgentDeepHITLError.decisionActionDigestMismatch(toolCallID: "call-1")) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: retargetableBundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Every action must have a same-index review config")
  func everyActionMustHaveSameIndexReviewConfig() throws {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/a.md"}"#,
          description: "Write first file.",
          toolCallID: "call-1"
        ),
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/b.md"}"#,
          description: "Write second file.",
          toolCallID: "call-2"
        ),
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.approve]
        ),
      ]
    )

    #expect(throws: CoreAgentDeepHITLError.reviewConfigCountMismatch(expected: 2, actual: 1)) {
      _ = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)
    }
  }

  @Test("Review config action names must match same-index action requests")
  func reviewConfigActionNamesMustMatchSameIndexActionRequests() throws {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/a.md"}"#,
          description: "Write file.",
          toolCallID: "call-1"
        )
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "append_file",
          allowedDecisions: [.edit],
          allowedEditedActionNames: ["write_file"]
        )
      ]
    )

    #expect(throws: CoreAgentDeepHITLError.reviewConfigActionMismatch(
      index: 0,
      expected: "write_file",
      actual: "append_file"
    )) {
      _ = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)
    }
  }

  @Test("Review config Codable preserves edited target allowlists")
  func reviewConfigCodablePreservesEditedTargetAllowlists() throws {
    let config = CoreAgentDeepHITLReviewConfig(
      actionName: "write_file",
      allowedDecisions: [.approve, .edit],
      allowedEditedActionNames: ["append_file", "rewrite_file"],
      description: "Review write."
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(CoreAgentDeepHITLReviewConfig.self, from: data)
    #expect(decoded == config)

    let legacyJSON = Data(
      #"""
      {
        "action_name": "write_file",
        "allowed_decisions": ["edit"]
      }
      """#.utf8
    )
    let legacy = try JSONDecoder().decode(CoreAgentDeepHITLReviewConfig.self, from: legacyJSON)
    #expect(legacy.allowedEditedActionNames.isEmpty)
  }

  @Test("Empty allowed decision sets fail closed in batch resolution")
  func emptyAllowedDecisionSetsFailClosed() throws {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/a.md"}"#,
          description: "Write file.",
          toolCallID: "call-1"
        ),
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(actionName: "write_file", allowedDecisions: []),
      ]
    )
    let resume = try CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
      .approve(action: Self.identity(for: bundle, at: 0)),
    ])

    #expect(throws: CoreAgentDeepHITLError.emptyAllowedDecisions(toolName: "write_file")) {
      _ = try CoreAgentDeepHITLBatchResolver.resolve(
        bundle: bundle,
        resume: resume,
        expectedInterruptID: "deep-hitl"
      )
    }
  }

  @Test("Default review IDs are scoped by graph node")
  func defaultReviewIDsAreScopedByGraphNode() async throws {
    let bundle = Self.reviewBundle()
    var graph = CoreAgentStateGraph<BatchState> { current, update in
      BatchState(outputs: current.outputs + update.outputs)
    }
    try graph.addNode("a") { state, context in
      let resolutions = try context.requestDeepHITLReview(bundle)
      var next = state
      next.outputs = resolutions.map { "a:\(Self.summary($0))" }
      return next
    }
    try graph.addNode("b") { state, context in
      let resolutions = try context.requestDeepHITLReview(bundle)
      var next = state
      next.outputs = resolutions.map { "b:\(Self.summary($0))" }
      return next
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try graph.compile(checkpointer: checkpointer)

    do {
      _ = try await compiled.invoke(BatchState(), threadID: "thread")
      Issue.record("Expected first default HITL interrupt")
    } catch {
      guard case CoreAgentGraphRuntimeError.interrupted(let interrupt) = error else {
        Issue.record("Expected graph interrupt, got \(error)")
        return
      }
      #expect(interrupt.id == "coreagent-deep-hitl/a")
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))

    do {
      _ = try await compiled.invoke(
        BatchState(),
        threadID: "thread",
        checkpointID: checkpoint.id,
        command: try .resume(
          CoreAgentDeepHITLBatchResume(interruptID: "coreagent-deep-hitl/a", decisions: [
            .edit(
              action: Self.identity(for: bundle, at: 0),
              name: "write_file",
              argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
            ),
            .respond(
              action: Self.identity(for: bundle, at: 1),
              message: "Use account ending in 1234."
            ),
          ])
        )
      )
      Issue.record("Expected second default HITL interrupt")
    } catch {
      guard case CoreAgentGraphRuntimeError.interrupted(let interrupt) = error else {
        Issue.record("Expected graph interrupt, got \(error)")
        return
      }
      #expect(interrupt.id == "coreagent-deep-hitl/b")
    }
    let resumedCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(resumedCheckpoint.pendingWrites.map(\.nodeID) == ["a"])
  }

  @Test("Native batch adapter reviews interrupted tool requests once")
  func nativeBatchAdapterReviewsInterruptedRequestsOnce() async throws {
    let writeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let askID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let readID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let requests = try [
      Self.toolRequest(
        invocationID: writeID,
        name: "write_file",
        description: "Write a report.",
        argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#
      ),
      Self.toolRequest(
        invocationID: askID,
        name: "ask_user",
        description: "Ask the user.",
        argsJSON: #"{"question":"Which account?"}"#
      ),
      Self.toolRequest(
        invocationID: readID,
        name: "read_file",
        description: "Read a file.",
        argsJSON: #"{"path":"/tmp/input.md"}"#
      ),
    ]
    let reviewer = RecordingBatchReviewer { review in
      #expect(review.interruptID == "native-hitl")
      #expect(review.bundle.actionRequests.map(\.name) == ["write_file", "ask_user"])
      #expect(review.bundle.actionRequests.map(\.toolCallID) == [
        writeID.uuidString.lowercased(),
        askID.uuidString.lowercased(),
      ])
      return [
        .edit(
          action: review.actionIdentities[0],
          name: "write_file",
          argsJSON: #"{"path":"/tmp/report.md","content":"approved"}"#
        ),
        .respond(
          action: review.actionIdentities[1],
          message: "Use account ending in 1234."
        ),
      ]
    }
    let adapter = CoreAgentDeepNativeToolBatchHITLAdapter(
      interruptOn: [
        "write_file": .interrupt(allowedDecisions: [.approve, .edit]),
        "ask_user": .interrupt(allowedDecisions: [.respond]),
      ],
      reviewer: reviewer
    )

    let decisions = try await adapter.decide(requests, interruptID: "native-hitl")

    #expect(await reviewer.requests.count == 1)
    #expect(decisions.map(\.toolCallID) == [
      writeID.uuidString.lowercased(),
      askID.uuidString.lowercased(),
      readID.uuidString.lowercased(),
    ])
    #expect(decisions.map(\.wasReviewed) == [true, true, false])
    Self.expectEdit(decisions[0].decision, contains: "approved")
    Self.expectRespond(decisions[1].decision, contains: "Use account ending in 1234.")
    Self.expectApprove(decisions[2].decision)
  }

  @Test("Native batch adapter does not call the reviewer when no rules match")
  func nativeBatchAdapterSkipsReviewerWhenNoRulesMatch() async throws {
    let reviewer = RecordingBatchReviewer { _ in
      Issue.record("Reviewer should not be called when no tool request matches interrupt rules.")
      return []
    }
    let adapter = CoreAgentDeepNativeToolBatchHITLAdapter(
      interruptOn: ["write_file": .interrupt],
      reviewer: reviewer
    )

    let decisions = try await adapter.decide([
      Self.toolRequest(
        invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        name: "read_file",
        description: "Read a file.",
        argsJSON: #"{"path":"/tmp/input.md"}"#
      )
    ])

    #expect(await reviewer.requests.isEmpty)
    #expect(decisions.count == 1)
    #expect(decisions.first?.wasReviewed == false)
    Self.expectApprove(try #require(decisions.first?.decision))
  }

  @Test("Native batch adapter fails closed before reviewer when a rule has no decisions")
  func nativeBatchAdapterRejectsEmptyAllowedDecisionSetBeforeReviewer() async throws {
    let reviewer = RecordingBatchReviewer { _ in
      Issue.record("Reviewer should not be called for invalid review config.")
      return []
    }
    let adapter = CoreAgentDeepNativeToolBatchHITLAdapter(
      interruptOn: ["write_file": .interrupt(allowedDecisions: [])],
      reviewer: reviewer
    )

    await #expect(throws: CoreAgentDeepHITLError.emptyAllowedDecisions(toolName: "write_file")) {
      _ = try await adapter.decide([
        Self.toolRequest(
          invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
          name: "write_file",
          description: "Write a file.",
          argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#
        )
      ])
    }
    #expect(await reviewer.requests.isEmpty)
  }

  @Test("Native batch adapter binds reviewer decisions to reviewed action identity")
  func nativeBatchAdapterBindsReviewerDecisionsToActionIdentity() async throws {
    let reviewer = RecordingBatchReviewer { review in
      [
        .approve(action: review.actionIdentities[1]),
        .respond(action: review.actionIdentities[0], message: "Use account ending in 1234."),
      ]
    }
    let adapter = CoreAgentDeepNativeToolBatchHITLAdapter(
      interruptOn: [
        "write_file": .interrupt(allowedDecisions: [.approve]),
        "ask_user": .interrupt(allowedDecisions: [.respond]),
      ],
      reviewer: reviewer
    )

    await #expect(throws: CoreAgentDeepHITLError.decisionActionMismatch(
      expectedToolCallID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        .uuidString.lowercased(),
      actualToolCallID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        .uuidString.lowercased()
    )) {
      _ = try await adapter.decide(
        [
          Self.toolRequest(
            invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            name: "write_file",
            description: "Write a file.",
            argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#
          ),
          Self.toolRequest(
            invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
            name: "ask_user",
            description: "Ask the user.",
            argsJSON: #"{"question":"Which account?"}"#
          ),
        ],
        interruptID: "native-hitl"
      )
    }
  }

  @Test("Native batch adapter rejects retargeted edits at the args-only tool boundary")
  func nativeBatchAdapterRejectsRetargetedEditsAtArgsOnlyToolBoundary() async throws {
    let reviewer = RecordingBatchReviewer { review in
      [
        .edit(
          action: review.actionIdentities[0],
          name: "append_file",
          argsJSON: #"{"path":"/tmp/report.md","content":"approved"}"#
        )
      ]
    }
    let adapter = CoreAgentDeepNativeToolBatchHITLAdapter(
      interruptOn: [
        "write_file": .interrupt(
          allowedDecisions: [.edit],
          allowedEditedActionNames: ["append_file"]
        )
      ],
      reviewer: reviewer
    )

    await #expect(throws: CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
      reviewed: "write_file",
      edited: "append_file"
    )) {
      _ = try await adapter.decide([
        Self.toolRequest(
          invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
          name: "write_file",
          description: "Write a file.",
          argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#
        )
      ])
    }
    #expect(await reviewer.requests.isEmpty)
  }

  @Test("Graph resume returns allowed retarget executable evidence")
  func graphResumeReturnsAllowedRetargetExecutableEvidence() async throws {
    let bundle = Self.retargetableReviewBundle()
    var graph = CoreAgentStateGraph<BatchState>()
    try graph.addNode("review") { state, context in
      let resolutions = try context.requestDeepHITLReview(bundle, id: "deep-hitl")
      var next = state
      next.outputs = resolutions.map { resolution in
        switch resolution {
        case .execute(let action):
          let authorization = action.editedTargetAuthorization
          return [
            action.requestedName,
            action.executableName,
            action.reviewedActionIdentity?.toolCallID ?? "missing-id",
            authorization?.editedActionName ?? "missing-target",
          ].joined(separator: "->")
        case .syntheticToolOutput(let output):
          return "synthetic:\(output.name)"
        }
      }
      return next
    }
    try graph.addEdge(.start, .node("review"))
    try graph.addEdge(.node("review"), .end)
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<BatchState>()
    let compiled = try graph.compile(checkpointer: checkpointer)

    await #expect(throws: (any Error).self) {
      _ = try await compiled.invoke(BatchState(), threadID: "thread")
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))
    let result = try await compiled.invoke(
      BatchState(),
      threadID: "thread",
      checkpointID: checkpoint.id,
      command: try .resume(
        CoreAgentDeepHITLBatchResume(interruptID: "deep-hitl", decisions: [
          .edit(
            action: Self.identity(for: bundle, at: 0),
            name: "append_file",
            argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
          )
        ])
      )
    )

    #expect(result.outputs == ["write_file->append_file->call-1->append_file"])
  }

  private static func makeBatchGraph(
    bundle: CoreAgentDeepHITLReviewBundle
  ) throws -> CoreAgentStateGraph<BatchState> {
    var graph = CoreAgentStateGraph<BatchState>()
    try graph.addNode("review") { state, context in
      let resolutions = try context.requestDeepHITLReview(bundle, id: "deep-hitl")
      var next = state
      next.outputs = resolutions.map(summary)
      return next
    }
    try graph.addEdge(.start, .node("review"))
    try graph.addEdge(.node("review"), .end)
    return graph
  }

  private static func summary(_ resolution: CoreAgentDeepHITLBatchResolution) -> String {
    switch resolution {
    case .execute(let action):
      "execute:\(action.source.rawValue):\(action.name):\(action.argsJSON)"
    case .syntheticToolOutput(let output):
      "synthetic:\(output.decision.rawValue):\(output.name):\(output.message)"
    }
  }

  private static func identity(
    for bundle: CoreAgentDeepHITLReviewBundle,
    at index: Int
  ) throws -> CoreAgentDeepHITLActionIdentity {
    try CoreAgentDeepHITLBatchResolver.identities(for: bundle)[index]
  }

  private static func reviewBundle() -> CoreAgentDeepHITLReviewBundle {
    CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#,
          description: "Write a report file.",
          toolCallID: "call-1"
        ),
        CoreAgentDeepHITLActionRequest(
          name: "ask_user",
          argsJSON: #"{"question":"Which account?"}"#,
          description: "Ask the user for missing account detail.",
          toolCallID: "call-2"
        ),
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.approve, .edit]
        ),
        CoreAgentDeepHITLReviewConfig(
          actionName: "ask_user",
          allowedDecisions: [.approve, .respond]
        ),
      ]
    )
  }

  private static func retargetableReviewBundle() -> CoreAgentDeepHITLReviewBundle {
    singleWriteReviewBundle(allowedEditedActionNames: ["append_file"])
  }

  private static func singleWriteReviewBundle(
    allowedEditedActionNames: Set<String>
  ) -> CoreAgentDeepHITLReviewBundle {
    CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/tmp/report.md","content":"draft"}"#,
          description: "Write a report file.",
          toolCallID: "call-1"
        )
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.edit],
          allowedEditedActionNames: allowedEditedActionNames
        )
      ]
    )
  }

  private static func toolRequest(
    invocationID: UUID,
    name: String,
    description: String,
    argsJSON: String
  ) throws -> CoreAgentToolRequest {
    CoreAgentToolRequest(
      runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      invocationID: invocationID,
      manifest: CoreAgentToolManifest(
        name: name,
        description: description,
        schemaJSON: "{}"
      ),
      arguments: try GeneratedContent(json: argsJSON)
    )
  }

  private static func expectApprove(_ decision: CoreAgentToolInterventionDecision) {
    if case .approve = decision {
      return
    }
    Issue.record("Expected approve decision, got \(decision).")
  }

  private static func expectEdit(
    _ decision: CoreAgentToolInterventionDecision,
    contains expected: String
  ) {
    guard case .edit(let arguments) = decision else {
      Issue.record("Expected edit decision, got \(decision).")
      return
    }
    #expect(arguments.jsonString.contains(expected))
  }

  private static func expectRespond(
    _ decision: CoreAgentToolInterventionDecision,
    contains expected: String
  ) {
    guard case .respond(let prompt) = decision else {
      Issue.record("Expected respond decision, got \(decision).")
      return
    }
    #expect(String(describing: prompt).contains(expected))
  }
}

private actor RecordingBatchReviewer: CoreAgentDeepHITLBatchReviewer {
  private let handler:
    @Sendable (CoreAgentDeepHITLBatchReviewRequest) async throws
      -> [CoreAgentDeepHITLBatchDecision]
  private(set) var requests: [CoreAgentDeepHITLBatchReviewRequest] = []

  init(
    _ handler: @escaping @Sendable (CoreAgentDeepHITLBatchReviewRequest) async throws
      -> [CoreAgentDeepHITLBatchDecision]
  ) {
    self.handler = handler
  }

  func decide(_ request: CoreAgentDeepHITLBatchReviewRequest) async throws
    -> [CoreAgentDeepHITLBatchDecision]
  {
    requests.append(request)
    return try await handler(request)
  }
}
