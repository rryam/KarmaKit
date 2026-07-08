import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep subagent task tool")
struct CoreAgentDeepTaskTests {
  @Test("Task tool exposes Deep-compatible name and subagent descriptions")
  func taskToolManifest() throws {
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "researcher",
          description: "Researches complex topics.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ]
    )

    #expect(taskTool.name == "task")
    #expect(taskTool.description.contains("researcher"))
    #expect(taskTool.description.contains("description"))
    #expect(taskTool.description.contains("subagent_type"))
    #expect(
      taskTool.availableSubagents() == [
        CoreAgentDeepSubagentDescriptor(
          name: "researcher",
          description: "Researches complex topics."
        )
      ])
  }

  @Test("Task tool runs an isolated child session and returns only the final handoff")
  func taskToolRunsIsolatedChildSession() async throws {
    let childTool = ChildProbeTool()
    let childModel = RecordedLanguageModel(steps: [
      .toolCall(name: "child_probe", argumentsJSON: #"{"value":"intermediate-secret"}"#),
      .response(text: "child final summary"),
    ])
    let childCheckpointStore = InMemoryCheckpointStore()
    let parentCheckpointStore = InMemoryCheckpointStore()
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let subagent = CoreAgentDeepSessionSubagent(
      name: "researcher",
      description: "Researches complex topics and returns concise findings.",
      model: childModel,
      tools: [childTool],
      instructions: Instructions("Return only a concise final handoff."),
      toolConfiguration: .init(policy: ToolNameAllowlistPolicy(["child_probe"])),
      checkpointStore: childCheckpointStore
    )
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [subagent],
      auditStore: auditStore
    )
    let parentModel = RecordedLanguageModel(steps: [
      .toolCall(
        id: "parent-call-1",
        name: "task",
        argumentsJSON:
          #"{"description":"Research the topic and return a short answer.","subagent_type":"researcher"}"#
      ),
      .response(text: "parent used child result"),
    ])
    let parent = try CoreAgentSession(
      model: parentModel,
      tools: [taskTool],
      checkpointStore: parentCheckpointStore,
      checkpointKey: "parent"
    )

    let response = try await parent.respond(to: "Use the researcher subagent.")

    #expect(response.content == "parent used child result")
    #expect(await childTool.values == ["intermediate-secret"])
    let auditRecord = try #require(await auditStore.records().first)
    let childCheckpointKey = try #require(auditRecord.checkpointKey)
    #expect(childCheckpointKey.hasPrefix("coreagent-deep/subagents/researcher/"))
    #expect(childCheckpointKey != "parent")
    let childCheckpoint = try #require(
      await childCheckpointStore.loadCheckpoint(for: childCheckpointKey)
    )
    #expect(childCheckpoint.transcript.containsText("child final summary"))

    let parentTranscripts = parentModel.recorder.capturedTranscripts()
    #expect(parentTranscripts.count == 2)
    #expect(parentTranscripts[1].containsText("child final summary"))
    #expect(!parentTranscripts[1].containsText("intermediate-secret"))
    let parentCheckpoint = try #require(await parentCheckpointStore.loadCheckpoint(for: "parent"))
    #expect(parentCheckpoint.transcript.containsText("child final summary"))
    #expect(!parentCheckpoint.transcript.containsText("intermediate-secret"))
    #expect(!parentCheckpoint.transcript.containsText("Return only a concise final handoff."))

    #expect(auditRecord.subagentName == "researcher")
    #expect(auditRecord.description == "Research the topic and return a short answer.")
    #expect(auditRecord.parentToolInvocationID != nil)
    #expect(auditRecord.childRunID != nil)
    #expect(auditRecord.childReceiptRootHash != nil)
    #expect(auditRecord.checkpointKey == childCheckpointKey)
    #expect(auditRecord.status == .completed)

    let parentInvocationID = response.run.events
      .first { $0.kind == .toolExecutionCompleted }?
      .attributes["invocation_id"]
    #expect(parentInvocationID == auditRecord.parentToolInvocationID?.uuidString.lowercased())
  }

  @Test("Direct task tool calls cannot forge parent invocation lineage")
  func directTaskToolCallsAreUnaffiliated() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do one.",
        subagent_type: "worker"
      )
    )

    let record = try #require(await auditStore.records().first)
    #expect(record.parentRunID == nil)
    #expect(record.parentToolInvocationID == nil)
  }

  @Test("Concurrent task tool calls use separate child checkpoint keys")
  func concurrentTaskCallsUseSeparateChildSessions() async throws {
    let childModel = RecordedLanguageModel(steps: [
      .response(text: "first child"),
      .response(text: "second child"),
    ])
    let childCheckpointStore = InMemoryCheckpointStore()
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: childModel,
          checkpointStore: childCheckpointStore
        )
      ],
      auditStore: auditStore
    )

    async let first = taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do one.",
        subagent_type: "worker"
      )
    )
    async let second = taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do two.",
        subagent_type: "worker"
      )
    )

    let outputs = try await [first, second]
    #expect(outputs.allSatisfy { $0.contains("COREAGENT_DEEP_SUBAGENT_RESULT_V1") })
    let records = await auditStore.records()
    #expect(records.count == 2)
    let checkpointKeys = Set(records.compactMap(\.checkpointKey))
    #expect(checkpointKeys.count == 2)
    for key in checkpointKeys {
      #expect(await childCheckpointStore.loadCheckpoint(for: key) != nil)
    }
  }

  @Test("Session subagents do not advertise checkpoint keys when no checkpoint store exists")
  func noCheckpointStoreDoesNotAdvertiseCheckpointKey() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: RecordedLanguageModel(steps: [.response(text: "done")])
        )
      ],
      auditStore: auditStore
    )

    let result = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do work.",
        subagent_type: "worker"
      )
    )

    #expect(!result.contains("checkpoint_key="))
    #expect(await auditStore.records().first?.checkpointKey == nil)
  }

  @Test("Session subagents persist file-backed checkpoints without default metadata poisoning")
  func fileCheckpointStoreReceivesChildCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "coreagent-deep-task-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let checkpointStore = FileCheckpointStore(directory: directory)
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: RecordedLanguageModel(steps: [.response(text: "file checkpointed")]),
          checkpointStore: checkpointStore
        )
      ],
      auditStore: auditStore
    )

    let result = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do work.",
        subagent_type: "worker"
      )
    )

    let checkpointKey = try #require(await auditStore.records().first?.checkpointKey)
    #expect(result.contains("checkpoint_key=\(checkpointKey)"))
    #expect(try await checkpointStore.loadCheckpoint(for: checkpointKey) != nil)
  }

  @Test("Subagents plugin exposes task tool to CoreAgent sessions")
  func subagentsPluginExposesTaskTool() async throws {
    let plugin = try CoreAgentDeepSubagentsPlugin(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "reviewer",
          description: "Reviews final work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "review handoff"
            )
          }
        )
      ]
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "task",
        argumentsJSON: #"{"description":"Review this.","subagent_type":"reviewer"}"#
      ),
      .response(text: "parent final"),
    ])
    let session = try CoreAgentSession(model: model, plugins: [plugin])

    let response = try await session.respond(to: "Delegate review.")

    #expect(response.content == "parent final")
    #expect(response.run.events.contains { $0.attributes["tool"] == "task" })
    #expect(await plugin.taskTool.auditStore.records().first?.subagentName == "reviewer")
  }

  @Test("Session subagent child tools are denied unless authority is explicit")
  func childToolsDenyByDefault() async throws {
    let childTool = ChildProbeTool()
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: RecordedLanguageModel(steps: [
            .toolCall(name: "child_probe", argumentsJSON: #"{"value":"must-not-run"}"#)
          ]),
          tools: [childTool]
        )
      ],
      auditStore: auditStore
    )

    await #expect(throws: CoreAgentDeepSubagentFailure.self) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Use the child tool.",
          subagent_type: "worker"
        )
      )
    }

    #expect(await childTool.values.isEmpty)
    let record = try #require(await auditStore.records().first)
    #expect(record.status == .failed)
    #expect(record.errorType != nil)
    #expect(record.errorDescription?.isEmpty == false)
  }

  @Test("Failed subagent runs are audit-visible")
  func failedTaskCallsAreAudited() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "failing",
          description: "Always fails.",
          handler: { _ in throw TaskTestError.intentional }
        )
      ],
      auditStore: auditStore
    )

    await #expect(throws: TaskTestError.self) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Fail now.",
          subagent_type: "failing"
        )
      )
    }

    let record = try #require(await auditStore.records().first)
    #expect(record.status == .failed)
    #expect(record.subagentName == "failing")
    #expect(record.errorDescription?.contains("intentional") == true)
  }

  @Test("Session subagent failures retain checkpoint keys and redact audit errors")
  func sessionSubagentFailuresRetainCheckpointAndRedactError() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: RecordedLanguageModel(steps: [
            .failure("Bearer abcd1234 password=supersecret")
          ]),
          checkpointStore: checkpointStore
        )
      ],
      auditStore: auditStore
    )

    await #expect(throws: CoreAgentDeepSubagentFailure.self) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Fail with a secret.",
          subagent_type: "worker"
        )
      )
    }

    let record = try #require(await auditStore.records().first)
    let checkpointKey = try #require(record.checkpointKey)
    #expect(await checkpointStore.loadCheckpoint(for: checkpointKey) != nil)
    #expect(record.errorDescription?.contains("abcd1234") == false)
    #expect(record.errorDescription?.contains("supersecret") == false)
    #expect(record.errorDescription?.contains("[REDACTED]") == true)
    #expect(record.errorType?.contains("RecordedLanguageModelError") == true)
  }

  @Test("Failed child audits drop checkpoint keys when checkpoint persistence failed")
  func failedChildAuditDropsFailedCheckpointKey() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        CoreAgentDeepSessionSubagent(
          name: "worker",
          description: "Completes delegated work.",
          model: RecordedLanguageModel(steps: [
            .failure("child failed")
          ]),
          checkpointStore: ThrowingCheckpointStore()
        )
      ],
      auditStore: auditStore
    )

    await #expect(throws: CoreAgentDeepSubagentFailure.self) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Fail with checkpoint persistence failure.",
          subagent_type: "worker"
        )
      )
    }

    let record = try #require(await auditStore.records().first)
    #expect(record.status == .failed)
    #expect(record.childRunID != nil)
    #expect(record.checkpointKey == nil)
  }

  @Test("Task tool exposes available subagent names and rejects unknown subagents visibly")
  func taskToolRejectsUnknownSubagent() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "reviewer",
          description: "Reviews final work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "review complete"
            )
          }
        )
      ],
      auditStore: auditStore
    )

    let result = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do the work.",
        subagent_type: "missing"
      )
    )

    #expect(result.contains("COREAGENT_DEEP_SUBAGENT_UNAVAILABLE_V1"))
    #expect(result.contains("reviewer"))
    let record = try #require(await auditStore.records().first)
    #expect(record.status == .denied)
    #expect(record.subagentName == "missing")
  }

  @Test("Task tool rejects parse-unsafe subagent names")
  func taskToolRejectsUnsafeSubagentNames() {
    #expect(throws: CoreAgentDeepSubagentError.self) {
      _ = try CoreAgentDeepTaskTool(
        subagents: [
          ClosureCoreAgentDeepSubagent(
            name: "bad\nname",
            description: "Invalid.",
            handler: { request in
              CoreAgentDeepSubagentResult(
                subagentName: request.subagentType,
                content: "done"
              )
            }
          )
        ]
      )
    }
  }

  @Test("Task result headers and audits use the canonical registry key")
  func taskResultUsesCanonicalSubagentKey() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { _ in
            CoreAgentDeepSubagentResult(
              subagentName: "wrong\nname",
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore
    )

    let result = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do work.",
        subagent_type: "worker"
      )
    )

    #expect(result.contains("COREAGENT_DEEP_SUBAGENT_RESULT_V1 subagent=worker"))
    #expect(!result.contains("wrong\nname"))
    #expect(await auditStore.records().first?.subagentName == "worker")
  }

  @Test("Task tool passes recursive budget state to child requests")
  func taskToolPassesBudgetStateToChildRequests() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            #expect(request.budget?.depth == 1)
            #expect(request.budget?.maximumDepth == 2)
            #expect(request.budget?.delegationsUsed == 1)
            #expect(request.budget?.maximumDelegations == 3)
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "budgeted"
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 2, maximumDelegations: 3)
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do budgeted work.",
        subagent_type: "worker"
      )
    )

    let record = try #require(await auditStore.records().first)
    #expect(record.budgetDepth == 1)
    #expect(record.budgetDelegationsUsed == 1)
  }

  @Test("Task tool defaults to a bounded model-facing budget")
  func taskToolDefaultsToBoundedModelFacingBudget() async throws {
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            #expect(
              request.budget?.maximumDepth
                == CoreAgentDeepSubagentBudget.modelFacingDefault.maximumDepth)
            #expect(
              request.budget?.maximumDelegations
                == CoreAgentDeepSubagentBudget.modelFacingDefault.maximumDelegations)
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "bounded"
            )
          }
        )
      ]
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do bounded work.",
        subagent_type: "worker"
      )
    )
  }

  @Test("Task audits redact delegated descriptions")
  func taskAuditsRedactDelegatedDescriptions() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            #expect(request.description.contains("supersecret"))
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Handle this password=supersecret without leaking it.",
        subagent_type: "worker"
      )
    )

    let record = try #require(await auditStore.records().first)
    #expect(!record.description.contains("supersecret"))
    #expect(record.description.contains("[REDACTED]"))
  }

}

private enum TaskTestError: Error, Equatable {
  case intentional
}

private enum ThrowingCheckpointStoreError: Error {
  case intentional
}

actor CallCounter {
  private var count = 0

  var value: Int { count }

  func increment() {
    count += 1
  }
}

private actor ThrowingCheckpointStore: CoreAgentCheckpointStore {
  func loadCheckpoint(for key: String) throws -> CoreAgentCheckpoint? {
    nil
  }

  func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) throws {
    throw ThrowingCheckpointStoreError.intentional
  }

  func removeCheckpoint(for key: String) throws {}
}

@Generable
private struct ChildProbeArguments: Sendable {
  let value: String
}

private actor ChildProbeTool: Tool {
  let name = "child_probe"
  let description = "Records a child-only intermediate value."

  private var recordedValues: [String] = []

  var values: [String] {
    recordedValues
  }

  @concurrent
  func call(arguments: ChildProbeArguments) async throws -> String {
    await append(arguments.value)
    return arguments.value
  }

  func append(_ value: String) {
    recordedValues.append(value)
  }
}

extension Transcript {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { entry in
      switch entry {
      case .instructions(let instructions):
        instructions.segments.containsText(expected)
      case .prompt(let prompt):
        prompt.segments.containsText(expected)
      case .toolOutput(let output):
        output.segments.containsText(expected)
      case .response(let response):
        response.segments.containsText(expected)
      case .reasoning(let reasoning):
        reasoning.segments.containsText(expected)
      case .toolCalls(let calls):
        calls.contains { $0.arguments.jsonString.contains(expected) }
      @unknown default:
        false
      }
    }
  }
}

extension [Transcript.Segment] {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}

@Suite("CoreAgentDeep dynamic subagents")
struct CoreAgentDeepDynamicSubagentTests {
  @Test("Propose and approve tools register dynamically spawned subagents")
  func proposeAndApproveToolsRegisterDynamicallySpawnedSubagents() async throws {
    let proposal = try CoreAgentDeepSubagentDescriptorProposalBuilder.makeProposal(
      name: "worker",
      description: "Handles delegated work."
    )
    let plugin = try CoreAgentDeepDynamicSubagentsPlugin(
      generator: CoreAgentDeepRecordingSubagentDescriptorGenerator(proposals: [proposal]),
      spawnFactory: ClosureCoreAgentDeepSubagentSpawnFactory { _ in
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Handles delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "child-output"
            )
          }
        )
      }
    )

    let proposeOutput = try await plugin.proposeTool.call(
      arguments: CoreAgentDeepProposeSubagentArguments(task_description: "Do work")
    )
    #expect(proposeOutput.contains("worker"))
    #expect(proposeOutput.contains(proposal.proposalID.uuidString))

    let approveOutput = try await plugin.approveTool.call(
      arguments: CoreAgentDeepApproveSubagentArguments(
        proposal_id: proposal.proposalID.uuidString,
        proposal_digest: proposal.proposalDigest,
        approver_id: "host"
      )
    )
    #expect(approveOutput.contains("Approved subagent worker"))

    let taskOutput = try await plugin.taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do work",
        subagent_type: "worker"
      )
    )
    #expect(taskOutput.contains("child-output"))
    #expect(taskOutput.contains("subagent=worker"))
  }
  @Test("Auto approval registers matching proposals without approve_subagent")
  func autoApprovalRegistersMatchingProposals() async throws {
    let proposal = try CoreAgentDeepSubagentDescriptorProposalBuilder.makeProposal(
      name: "worker",
      description: "Handles delegated work."
    )
    let registry = try CoreAgentDeepSubagentApprovedRegistry(staticSubagents: [])
    let proposalStore = CoreAgentDeepSubagentProposalStore()
    let spawnFactory = ClosureCoreAgentDeepSubagentSpawnFactory { _ in
      ClosureCoreAgentDeepSubagent(
        name: "worker",
        description: "Handles delegated work.",
        handler: { request in
          CoreAgentDeepSubagentResult(
            subagentName: request.subagentType,
            content: "child-output"
          )
        }
      )
    }
    let tool = CoreAgentDeepProposeSubagentTool(
      generator: CoreAgentDeepRecordingSubagentDescriptorGenerator(proposals: [proposal]),
      proposalStore: proposalStore,
      proposalRegistrar: CoreAgentDeepSubagentProposalRegistrar(
        registry: registry,
        spawnFactory: spawnFactory
      ),
      autoApprovalPolicy: CoreAgentDeepDynamicSubagentsAutoApprovalPolicy(
        approverID: "policy-bot",
        allowedNames: ["worker"]
      )
    )

    let output = try await tool.call(
      arguments: CoreAgentDeepProposeSubagentArguments(task_description: "Do work")
    )
    #expect(output.contains(proposal.proposalID.uuidString))

    let descriptors = await registry.availableDescriptors()
    #expect(descriptors.map(\.name) == ["worker"])
  }

}
