import CoreAgent
import CoreAgentDeep
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep graph HITL executable action dispatch")
struct CoreAgentDeepHITLExecutionTests {
  @Test("Retargeted graph HITL actions dispatch through the executable target manifest")
  func retargetedActionsDispatchThroughExecutableTargetManifest() async throws {
    let action = try Self.retargetedAction()
    let appendManifest = Self.manifest(name: "append_file")
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        appendManifest,
      ],
      policy: ToolNameAllowlistPolicy(["append_file"]),
      backend: ClosureCoreAgentDeepHITLExecutableActionBackend { request, action in
        #expect(request.manifest == appendManifest)
        #expect(request.manifest.name == action.executableName)
        #expect(request.argumentsJSON.contains("approved"))
        #expect(CoreAgentToolInvocation.current?.toolName == "append_file")
        #expect(CoreAgentToolInvocation.current?.manifestDigest == appendManifest.digest)
        return Prompt("executed:\(request.manifest.name)")
      }
    )

    let result = try await executor.execute(
      action,
      runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    #expect(result.graphToolCallID == "call-1")
    #expect(result.requestedName == "write_file")
    #expect(result.executableName == "append_file")
    #expect(result.source == .edit)
    #expect(result.manifest == appendManifest)
    #expect(result.request.manifest == appendManifest)
    #expect(result.request.argumentsJSON.contains("approved"))
    #expect(String(describing: result.output).contains("executed:append_file"))
    #expect(result.reviewedActionIdentity != nil)
    #expect(result.editedTargetAuthorization?.reviewedActionName == "write_file")
    #expect(result.editedTargetAuthorization?.editedActionName == "append_file")
  }

  @Test("Retargeted graph HITL actions authorize the executable target, not the reviewed tool")
  func retargetedActionsAuthorizeExecutableTargetNotReviewedTool() async throws {
    let action = try Self.retargetedAction()
    let backend = RecordingGraphActionBackend()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: ToolNameAllowlistPolicy(["write_file"]),
      backend: backend
    )

    do {
      _ = try await executor.execute(
        action,
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      )
      Issue.record("Expected executable target authorization to fail.")
    } catch CoreAgentPolicyError.denied(let toolName, _) {
      #expect(toolName == "append_file")
    } catch {
      Issue.record("Expected CoreAgentPolicyError.denied, got \(error).")
    }
    #expect(await backend.requests.isEmpty)
  }

  @Test("Missing executable target manifests fail before policy and backend execution")
  func missingExecutableTargetManifestsFailBeforeBackendExecution() async throws {
    let action = try Self.retargetedAction()
    let backend = RecordingGraphActionBackend()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [Self.manifest(name: "write_file")],
      policy: ToolNameAllowlistPolicy(["append_file"]),
      backend: backend
    )

    await #expect(
      throws: CoreAgentDeepHITLError.missingExecutableManifest(
        toolName: "append_file"
      )
    ) {
      _ = try await executor.execute(
        action,
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      )
    }
    #expect(await backend.requests.isEmpty)
  }

  @Test("Malformed executable arguments fail before policy and backend execution")
  func malformedExecutableArgumentsFailBeforePolicyAndBackendExecution() async throws {
    let action = try Self.retargetedAction(argsJSON: "not-json")
    let backend = RecordingGraphActionBackend()
    let policy = RecordingPolicy()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: policy,
      backend: backend
    )

    await #expect(
      throws: CoreAgentDeepHITLError.invalidExecutableArguments(
        toolName: "append_file"
      )
    ) {
      _ = try await executor.execute(
        action,
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      )
    }
    #expect(await policy.requests.isEmpty)
    #expect(await backend.requests.isEmpty)
  }

  @Test("Malformed requested arguments fail before policy and backend execution")
  func malformedRequestedArgumentsFailBeforePolicyAndBackendExecution() async throws {
    let action = try Self.retargetedAction(requestedArgsJSON: "not-json")
    let backend = RecordingGraphActionBackend()
    let policy = RecordingPolicy()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: policy,
      backend: backend
    )

    await #expect(
      throws: CoreAgentDeepHITLError.invalidRequestedArguments(
        toolName: "write_file"
      )
    ) {
      _ = try await executor.execute(
        action,
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      )
    }
    #expect(await policy.requests.isEmpty)
    #expect(await backend.requests.isEmpty)
  }

  @Test("Graph HITL executable dispatch derives stable invocation context from graph tool calls")
  func executableDispatchDerivesStableInvocationContextFromGraphToolCalls() async throws {
    let action = try Self.retargetedAction()
    let backend = RecordingGraphActionBackend()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: backend
    )
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let first = try await executor.execute(action, runID: runID)
    let second = try await executor.execute(action, runID: runID)
    let contexts = await backend.contexts
    let requests = await backend.requests

    #expect(first.request.invocationID == second.request.invocationID)
    #expect(first.request.invocationID == contexts[0]?.invocationID)
    #expect(contexts.map(\.?.toolName) == ["append_file", "append_file"])
    #expect(requests.map(\.manifest.name) == ["append_file", "append_file"])
  }

  @Test(
    "Graph HITL executable dispatch changes invocation identity when executable arguments change")
  func executableDispatchChangesInvocationIdentityWhenExecutableArgumentsChange() async throws {
    let firstAction = try Self.retargetedAction(
      argsJSON: #"{"path":"/safe/report.md","content":"first"}"#
    )
    let secondAction = try Self.retargetedAction(
      argsJSON: #"{"path":"/safe/report.md","content":"second"}"#
    )
    let backend = RecordingGraphActionBackend()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: backend
    )
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let first = try await executor.execute(firstAction, runID: runID)
    let second = try await executor.execute(secondAction, runID: runID)

    #expect(first.request.invocationID != second.request.invocationID)
    #expect(first.executableArgumentsDigest != second.executableArgumentsDigest)
  }

  @Test(
    "Graph HITL executable dispatch keeps invocation identity stable for canonical argument equivalents"
  )
  func executableDispatchKeepsInvocationIdentityStableForCanonicalArgumentEquivalents()
    async throws
  {
    let firstAction = try Self.retargetedAction(
      argsJSON: #"{"path":"/safe/report.md","content":"approved"}"#
    )
    let secondAction = try Self.retargetedAction(
      argsJSON: #"{ "content": "approved", "path": "/safe/report.md" }"#
    )
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let first = try await executor.execute(firstAction, runID: runID)
    let second = try await executor.execute(secondAction, runID: runID)

    #expect(first.request.invocationID == second.request.invocationID)
    #expect(first.executableArgumentsDigest == second.executableArgumentsDigest)
  }

  @Test("Graph HITL executable dispatch changes invocation identity when run identity changes")
  func executableDispatchChangesInvocationIdentityWhenRunIdentityChanges() async throws {
    let action = try Self.retargetedAction()
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )

    let first = try await executor.execute(
      action,
      runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
    let second = try await executor.execute(
      action,
      runID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    )

    #expect(first.request.invocationID != second.request.invocationID)
  }

  @Test(
    "Graph HITL executable dispatch changes invocation identity when graph call identity changes")
  func executableDispatchChangesInvocationIdentityWhenGraphCallIdentityChanges() async throws {
    let firstAction = try Self.retargetedAction(toolCallID: "call-1")
    let secondAction = try Self.retargetedAction(toolCallID: "call-2")
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let first = try await executor.execute(firstAction, runID: runID)
    let second = try await executor.execute(secondAction, runID: runID)

    #expect(first.request.invocationID != second.request.invocationID)
  }

  @Test("Graph HITL executable dispatch changes invocation identity when manifest digest changes")
  func executableDispatchChangesInvocationIdentityWhenManifestDigestChanges() async throws {
    let action = try Self.retargetedAction()
    let firstExecutor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file", schemaJSON: #"{"version":1}"#),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )
    let secondExecutor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file", schemaJSON: #"{"version":2}"#),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let first = try await firstExecutor.execute(action, runID: runID)
    let second = try await secondExecutor.execute(action, runID: runID)

    #expect(first.manifest.digest != second.manifest.digest)
    #expect(first.request.invocationID != second.request.invocationID)
  }

  @Test(
    "Graph HITL executable dispatch returns redacted requested and executable argument evidence")
  func executableDispatchReturnsRedactedArgumentEvidence() async throws {
    let action = try Self.retargetedAction(
      requestedArgsJSON: #"{"path":"/tmp/report.md","api_key":"raw-key"}"#,
      argsJSON: #"{"path":"/safe/report.md","password":"raw-password"}"#
    )
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [
        Self.manifest(name: "write_file"),
        Self.manifest(name: "append_file"),
      ],
      policy: AllowAllCoreAgentToolPolicy(),
      backend: RecordingGraphActionBackend()
    )

    let result = try await executor.execute(
      action,
      runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
    let requestedArguments = try GeneratedContent(json: action.requestedArgsJSON)

    #expect(result.requestedArgumentsDigest != result.executableArgumentsDigest)
    #expect(result.requestedArgumentsDigest == CoreAgentArgumentAudit.digest(requestedArguments))
    #expect(
      result.executableArgumentsDigest == CoreAgentArgumentAudit.digest(result.request.arguments))
    #expect(!result.requestedArgumentsRedactedJSON.contains("raw-key"))
    #expect(!result.executableArgumentsRedactedJSON.contains("raw-password"))
    #expect(result.requestedArgumentsRedactedJSON.contains("[REDACTED]"))
    #expect(result.executableArgumentsRedactedJSON.contains("[REDACTED]"))
  }

  @Test("Approved graph HITL actions preserve source without edited-target authorization")
  func approvedActionsPreserveSourceWithoutEditedTargetAuthorization() async throws {
    let action = try Self.approvedAction()
    let writeManifest = Self.manifest(name: "write_file")
    let executor = try CoreAgentDeepHITLExecutableActionExecutor(
      manifests: [writeManifest],
      policy: ToolNameAllowlistPolicy(["write_file"]),
      backend: RecordingGraphActionBackend()
    )

    let result = try await executor.execute(
      action,
      runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    #expect(result.source == .approve)
    #expect(result.requestedName == "write_file")
    #expect(result.executableName == "write_file")
    #expect(result.manifest == writeManifest)
    #expect(result.reviewedActionIdentity != nil)
    #expect(result.editedTargetAuthorization == nil)
  }

  @Test("Duplicate executable target manifests fail closed at executor construction")
  func duplicateExecutableTargetManifestsFailClosedAtConstruction() {
    #expect(
      throws: CoreAgentDeepHITLError.duplicateExecutableManifest(
        toolName: "append_file"
      )
    ) {
      _ = try CoreAgentDeepHITLExecutableActionExecutor(
        manifests: [
          Self.manifest(name: "append_file"),
          Self.manifest(name: "append_file"),
        ],
        policy: AllowAllCoreAgentToolPolicy(),
        backend: RecordingGraphActionBackend()
      )
    }
  }

  private static func retargetedAction(
    requestedArgsJSON: String = #"{"path":"/tmp/report.md","content":"draft"}"#,
    argsJSON: String = #"{"path":"/safe/report.md","content":"approved"}"#,
    toolCallID: String = "call-1"
  ) throws -> CoreAgentDeepHITLExecutableAction {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: requestedArgsJSON,
          description: "Write a report file.",
          toolCallID: toolCallID
        )
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.edit],
          allowedEditedActionNames: ["append_file"]
        )
      ]
    )
    let identity = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)[0]
    let resume = CoreAgentDeepHITLBatchResume(
      interruptID: "deep-hitl",
      decisions: [
        .edit(action: identity, name: "append_file", argsJSON: argsJSON)
      ])
    let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: "deep-hitl"
    )
    guard case .execute(let action) = try #require(resolutions.first) else {
      Issue.record("Expected executable action.")
      throw CoreAgentDeepHITLError.invalidSyntheticBatchDecision(
        toolName: "write_file",
        decision: .edit
      )
    }
    return action
  }

  private static func approvedAction(
    argsJSON: String = #"{"path":"/safe/report.md","content":"approved"}"#,
    toolCallID: String = "call-1"
  ) throws -> CoreAgentDeepHITLExecutableAction {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: argsJSON,
          description: "Write a report file.",
          toolCallID: toolCallID
        )
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.approve]
        )
      ]
    )
    let identity = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)[0]
    let resume = CoreAgentDeepHITLBatchResume(
      interruptID: "deep-hitl",
      decisions: [.approve(action: identity)]
    )
    let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: "deep-hitl"
    )
    guard case .execute(let action) = try #require(resolutions.first) else {
      Issue.record("Expected executable action.")
      throw CoreAgentDeepHITLError.invalidSyntheticBatchDecision(
        toolName: "write_file",
        decision: .approve
      )
    }
    return action
  }

  private static func manifest(
    name: String,
    schemaJSON: String = "{}"
  ) -> CoreAgentToolManifest {
    CoreAgentToolManifest(
      name: name,
      description: "Execute \(name).",
      schemaJSON: schemaJSON
    )
  }
}

private actor RecordingGraphActionBackend: CoreAgentDeepHITLExecutableActionBackend {
  private(set) var requests: [CoreAgentToolRequest] = []
  private(set) var contexts: [CoreAgentToolInvocationContext?] = []

  func execute(
    _ request: CoreAgentToolRequest,
    action: CoreAgentDeepHITLExecutableAction
  ) async throws -> Prompt {
    requests.append(request)
    contexts.append(CoreAgentToolInvocation.current)
    return Prompt("recorded:\(action.executableName)")
  }
}

private actor RecordingPolicy: CoreAgentToolPolicy {
  private(set) var requests: [CoreAgentToolRequest] = []

  func authorize(_ request: CoreAgentToolRequest) async throws {
    requests.append(request)
  }
}
