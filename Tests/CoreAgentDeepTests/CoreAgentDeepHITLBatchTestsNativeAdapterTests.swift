import CoreAgent
import CoreAgentDeep
import CoreAgentGraph
import Foundation
import FoundationModels
import Testing

extension CoreAgentDeepHITLBatchTests {
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
      #expect(
        review.bundle.actionRequests.map(\.toolCallID) == [
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
    #expect(
      decisions.map(\.toolCallID) == [
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

    await #expect(
      throws: CoreAgentDeepHITLError.decisionActionMismatch(
        expectedToolCallID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
          .uuidString.lowercased(),
        actualToolCallID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
          .uuidString.lowercased()
      )
    ) {
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

    await #expect(
      throws: CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
        reviewed: "write_file",
        edited: "append_file"
      )
    ) {
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
        CoreAgentDeepHITLBatchResume(
          interruptID: "deep-hitl",
          decisions: [
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

  static func makeBatchGraph(
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

  static func summary(_ resolution: CoreAgentDeepHITLBatchResolution) -> String {
    switch resolution {
    case .execute(let action):
      "execute:\(action.source.rawValue):\(action.name):\(action.argsJSON)"
    case .syntheticToolOutput(let output):
      "synthetic:\(output.decision.rawValue):\(output.name):\(output.message)"
    }
  }

  static func identity(
    for bundle: CoreAgentDeepHITLReviewBundle,
    at index: Int
  ) throws -> CoreAgentDeepHITLActionIdentity {
    try CoreAgentDeepHITLBatchResolver.identities(for: bundle)[index]
  }

  static func reviewBundle() -> CoreAgentDeepHITLReviewBundle {
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

  static func retargetableReviewBundle() -> CoreAgentDeepHITLReviewBundle {
    singleWriteReviewBundle(allowedEditedActionNames: ["append_file"])
  }

  static func singleWriteReviewBundle(
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

  static func toolRequest(
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

  static func expectApprove(_ decision: CoreAgentToolInterventionDecision) {
    if case .approve = decision {
      return
    }
    Issue.record("Expected approve decision, got \(decision).")
  }

  static func expectEdit(
    _ decision: CoreAgentToolInterventionDecision,
    contains expected: String
  ) {
    guard case .edit(let arguments) = decision else {
      Issue.record("Expected edit decision, got \(decision).")
      return
    }
    #expect(arguments.jsonString.contains(expected))
  }

  static func expectRespond(
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
