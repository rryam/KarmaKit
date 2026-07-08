import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
  @Test("Optimization policy rejects empty protected-region markers")
  func optimizationPolicyRejectsEmptyProtectedRegionMarkers() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "protected region markers must be non-empty")
    ) {
      _ = try await optimizer.propose(
        CoreAgentSkillOptimizationProposal(
          skillID: base.id,
          baselineScore: 0.70,
          candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
          validation: Self.validation(score: 0.90)
        ),
        policy: CoreAgentSkillOptimizationPolicy(
          protectedRegions: [
            CoreAgentSkillProtectedRegion(name: "bad", startMarker: "", endMarker: "")
          ]
        )
      )
    }
    let current = try #require(await store.currentSkill(id: base.id))
    #expect(current.version == 1)
  }

  @Test("Whitespace-only replacement targets are rejected")
  func whitespaceOnlyReplacementTargetsAreRejected() throws {
    #expect(throws: CoreAgentSkillOptimizationError.emptyReplacementTarget) {
      _ = try CoreAgentSkillEdit.replace(target: "   ", replacement: "new").apply(
        to: "old value"
      )
    }
  }

  @Test("Harvests Engine traces into SkillOpt evidence without raw event payloads")
  func harvestsEngineTracesIntoSkillOptEvidenceWithoutRawEventPayloads() async throws {
    let engineStore = InMemoryCoreAgentEngineStore()
    let runID = Self.uuid(701)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(
          runID: runID,
          kind: .toolExecutionStarted,
          message: "Started shell with token=harvest-secret",
          attributes: [
            "api_key": "harvest-secret",
            "tool": "shell",
            "arguments": "delete-everything",
          ]
        ),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "Run failed for prompt delete-everything",
          attributes: [
            "error_type": "authorization harvest-secret",
            "tool": "shell delete-everything",
          ]
        ),
      ]
    )
    try await engineStore.ingest(run, projectID: "coreagent", threadID: "thread-a")
    let issues = try await CoreAgentEngineIssueScanner(store: engineStore).scan(
      projectID: "coreagent")
    let issue = try #require(issues.first)

    let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: engineStore)
    let firstHarvest = await harvester.harvest(projectID: "coreagent", threadID: "thread-a")
    let secondHarvest = await harvester.harvest(projectID: "coreagent", threadID: "thread-a")
    let evidence = try #require(firstHarvest.first)
    let encoded =
      String(
        data: try JSONEncoder().encode(evidence),
        encoding: .utf8
      ) ?? ""

    #expect(firstHarvest.count == 1)
    #expect(firstHarvest.map(\.id) == secondHarvest.map(\.id))
    #expect(evidence.id.hasPrefix("engine-trace-"))
    #expect(evidence.taskID.hasPrefix("engine-issue-"))
    #expect(evidence.transcriptDigest.hasPrefix("sha256:"))
    #expect(evidence.toolEventDigest.hasPrefix("sha256:"))
    #expect(evidence.score == 0)
    #expect(evidence.metadata["source"] == "coreagent-engine")
    #expect(evidence.metadata["project_id"] == "coreagent")
    #expect(evidence.metadata["thread_id"] == "thread-a")
    #expect(evidence.metadata["run_id"] == runID.uuidString.lowercased())
    #expect(evidence.metadata["run_status"] == "failed")
    #expect(evidence.metadata["issue_id_digest"]?.hasPrefix("sha256:") == true)
    #expect(evidence.metadata["issue_status"] == CoreAgentEngineIssueStatus.open.rawValue)
    #expect(evidence.verifierFeedback == "engine issue linked")
    #expect(evidence.metadata["error_type"] == nil)
    #expect(evidence.metadata["tool"] == nil)
    #expect(evidence.metadata["issue_fingerprint"] == nil)
    #expect(!encoded.contains("harvest-secret"))
    #expect(!encoded.contains("delete-everything"))
    #expect(!encoded.contains(issue.fingerprint))
  }

  @Test("Harvester filters unverified and non-finalized Engine traces")
  func harvesterFiltersUnverifiedAndNonFinalizedEngineTraces() async throws {
    let validID = Self.uuid(711)
    let tamperedID = Self.uuid(712)
    let partialID = Self.uuid(713)
    let validRun = Self.run(
      id: validID,
      events: [
        Self.event(runID: validID, kind: .runCompleted, message: "done")
      ]
    )
    let originalTamperedRun = Self.run(
      id: tamperedID,
      events: [
        Self.event(runID: tamperedID, kind: .runCompleted, message: "original")
      ]
    )
    let changedTamperedRun = Self.run(
      id: tamperedID,
      events: [
        Self.event(runID: tamperedID, kind: .runFailed, message: "changed")
      ]
    )
    let partialRun = Self.run(
      id: partialID,
      events: [
        Self.event(runID: partialID, kind: .toolExecutionStarted, message: "partial")
      ]
    )
    let store = StaticEngineStore(traces: [
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: validRun,
        receipt: try CoreAgentRunReceipt(run: validRun)
      ),
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: changedTamperedRun,
        receipt: try CoreAgentRunReceipt(run: originalTamperedRun)
      ),
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: partialRun,
        receipt: try CoreAgentRunReceipt(run: partialRun)
      ),
    ])
    let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: store)

    let evidence = await harvester.harvest(projectID: "coreagent")

    #expect(evidence.map { $0.metadata["run_id"] } == [validID.uuidString.lowercased()])
    #expect(evidence.map(\.score) == [1])
  }

  @Test("Replay generator creates deterministic replay and dream rollout requests")
  func replayGeneratorCreatesDeterministicReplayAndDreamRolloutRequests() throws {
    let failed = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-failed",
      taskID: "issue-authorization",
      transcriptDigest: "sha256:failed-transcript",
      toolEventDigest: "sha256:failed-tools",
      verifierFeedback: "typed failure secret-feedback",
      score: 0,
      metadata: [
        "project_id": "coreagent",
        "run_id": "failed-run",
        "run_status": "failed",
        "suite_id": "source-train",
      ]
    )
    let completed = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-completed",
      taskID: "run-completed",
      transcriptDigest: "sha256:completed-transcript",
      toolEventDigest: "sha256:completed-tools",
      verifierFeedback: "typed success secret-feedback",
      score: 1,
      metadata: [
        "project_id": "coreagent",
        "run_id": "completed-run",
        "run_status": "completed",
        "suite_id": "source-heldout",
      ]
    )
    let generator = CoreAgentSkillReplayGenerator()
    let unknownSuite = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-unknown-suite",
      taskID: "run-unknown-suite",
      transcriptDigest: "sha256:unknown-suite-transcript",
      toolEventDigest: "sha256:unknown-suite-tools",
      verifierFeedback: "unknown suite secret-feedback",
      score: 1,
      metadata: [
        "project_id": "coreagent",
        "run_id": "unknown-suite-run",
        "run_status": "completed",
      ]
    )

    let splitSafe = try generator.generate(
      from: [failed, unknownSuite, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        excludedSourceSuiteIDs: ["source-train"],
        includeDreamRolloutsForFailures: true
      )
    )
    let withDreams = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true
      )
    )
    let withDreamsAgain = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true
      )
    )
    let capped = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true,
        maxRequests: 2
      )
    )
    let encoded =
      String(
        data: try JSONEncoder().encode(withDreams),
        encoding: .utf8
      ) ?? ""

    #expect(splitSafe.map(\.sourceEvidenceID) == ["engine-trace-completed"])
    #expect(splitSafe.map(\.mode) == [.replay])
    #expect(splitSafe.first?.heldoutSuiteID == "heldout-replay")
    #expect(splitSafe.first?.metadata["source_suite_id"] == "source-heldout")
    #expect(
      withDreams.map { "\($0.mode.rawValue):\($0.sourceEvidenceID)" } == [
        "replay:engine-trace-failed",
        "dream:engine-trace-failed",
        "replay:engine-trace-completed",
      ])
    #expect(withDreams.map(\.id) == withDreamsAgain.map(\.id))
    #expect(
      capped.map { "\($0.mode.rawValue):\($0.sourceEvidenceID)" } == [
        "replay:engine-trace-failed",
        "dream:engine-trace-failed",
      ])
    #expect(withDreams.allSatisfy { $0.id.hasPrefix("skill-rollout-") })
    #expect(withDreams.allSatisfy { $0.transcriptDigest.hasPrefix("sha256:") })
    #expect(withDreams.allSatisfy { $0.heldoutSuiteID == "heldout-replay" })
    #expect(!encoded.contains("secret-feedback"))
  }

  @Test("Replay generation policy rejects invalid heldout suite and request caps")
  func replayGenerationPolicyRejectsInvalidHeldoutSuiteAndRequestCaps() throws {
    let generator = CoreAgentSkillReplayGenerator()
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-completed",
      taskID: "run-completed",
      transcriptDigest: "sha256:completed-transcript",
      toolEventDigest: "sha256:completed-tools",
      verifierFeedback: "typed success",
      score: 1,
      metadata: ["run_status": "completed"]
    )

    #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try generator.generate(
        from: [evidence],
        policy: CoreAgentSkillReplayGenerationPolicy(heldoutSuiteID: "  ")
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxRequests must be positive"
      )
    ) {
      _ = try generator.generate(
        from: [evidence],
        policy: CoreAgentSkillReplayGenerationPolicy(
          heldoutSuiteID: "heldout-replay",
          maxRequests: 0
        )
      )
    }
  }

  @Test("Replay executor executes requests into sanitized rollout evidence")
  func replayExecutorExecutesRequestsIntoSanitizedRolloutEvidence() async throws {
    let replayRequest = Self.replayRequest(
      id: "request-replay",
      mode: .replay,
      metadata: [
        "source_project_id": "coreagent",
        "raw_prompt": "do not copy replay-secret",
      ]
    )
    let dreamRequest = Self.replayRequest(id: "request-dream", mode: .dream)
    let backend = StaticReplayBackend(outcomes: [
      replayRequest.id: CoreAgentSkillReplayOutcome(
        requestID: replayRequest.id,
        transcriptDigest: Self.digest(910),
        toolEventDigest: Self.digest(911),
        verifierFeedback: "replay passed with do not copy replay-secret",
        score: 0.75
      ),
      dreamRequest.id: CoreAgentSkillReplayOutcome(
        requestID: dreamRequest.id,
        transcriptDigest: Self.digest(920),
        toolEventDigest: Self.digest(921),
        verifierFeedback: "dream found a safer path with do not copy dream-secret",
        score: 0.55
      ),
    ])
    let executor = CoreAgentSkillReplayExecutor(backend: backend)

    let first = try await executor.execute([replayRequest, dreamRequest])
    let second = try await executor.execute([replayRequest, dreamRequest])
    let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""

    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.map(\.taskID) == ["task-auth", "task-auth"])
    #expect(first.map(\.transcriptDigest) == [Self.digest(910), Self.digest(920)])
    #expect(first.map(\.toolEventDigest) == [Self.digest(911), Self.digest(921)])
    #expect(first.map(\.score) == [0.75, 0.55])
    #expect(
      first.map(\.verifierFeedback) == [
        "replay execution completed",
        "dream execution completed",
      ])
    #expect(first.map { $0.metadata["suite_id"] } == ["heldout-replay", "heldout-replay"])
    #expect(first.map { $0.metadata["replay_mode"] } == ["replay", "dream"])
    #expect(first.map { $0.metadata["replay_request_id"] } == ["request-replay", "request-dream"])
    #expect(first.first?.metadata["source_project_id"] == "coreagent")
    #expect(first.first?.metadata["verifier_feedback_digest"]?.hasPrefix("sha256:") == true)
    #expect(first.first?.metadata["raw_prompt"] == nil)
    #expect(first.allSatisfy { $0.id.hasPrefix("replay-evidence-") })
    #expect(!encoded.contains("replay-secret"))
    #expect(!encoded.contains("dream-secret"))
  }

  @Test("Replay executor validates requests and backend outcomes fail closed")
  func replayExecutorValidatesRequestsAndBackendOutcomesFailClosed() async throws {
    let request = Self.replayRequest(id: "request-replay", mode: .replay)
    let countingBackend = CountingReplayBackend()
    let executor = CoreAgentSkillReplayExecutor(backend: countingBackend)

    await #expect(throws: CoreAgentSkillOptimizationError.duplicateReplayRequest("request-replay"))
    {
      _ = try await executor.execute([request, request])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try await executor.execute([
        Self.replayRequest(id: "empty-suite", mode: .replay, heldoutSuiteID: " ")
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request digests must be sha256"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "uppercase-digest",
          mode: .replay,
          transcriptDigest: "sha256:\(String(repeating: "A", count: 64))"
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request digests must be sha256"
      )
    ) {
      _ = try await executor.execute([
        request,
        Self.replayRequest(
          id: "later-invalid-digest",
          mode: .replay,
          transcriptDigest: "sha256:\(String(repeating: "0", count: 63))"
        ),
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request identity fields must be non-empty"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(id: " ", mode: .replay)
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite ID cannot be empty"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "empty-source-suite",
          mode: .replay,
          metadata: ["source_suite_id": " "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite cannot match heldout suite"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "split-leak",
          mode: .replay,
          metadata: ["source_suite_id": "heldout-replay"]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite cannot match heldout suite"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "split-leak-whitespace",
          mode: .replay,
          metadata: ["source_suite_id": " heldout-replay "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite is excluded"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: countingBackend,
        policy: CoreAgentSkillReplayExecutionPolicy(excludedSourceSuiteIDs: ["train"])
      ).execute([
        Self.replayRequest(
          id: "excluded-source",
          mode: .replay,
          metadata: ["source_suite_id": "train"]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite is excluded"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: countingBackend,
        policy: CoreAgentSkillReplayExecutionPolicy(excludedSourceSuiteIDs: ["train"])
      ).execute([
        Self.replayRequest(
          id: "excluded-source-whitespace",
          mode: .replay,
          metadata: ["source_suite_id": " train "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome request ID mismatch"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: "other-request",
            transcriptDigest: Self.digest(930),
            toolEventDigest: Self.digest(931),
            verifierFeedback: "mismatch",
            score: 0.5
          )
        ])
      ).execute([request])
    }

    await #expect(throws: CoreAgentSkillOptimizationError.invalidValidationScore(1.5)) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: Self.digest(940),
            toolEventDigest: Self.digest(941),
            verifierFeedback: "bad score",
            score: 1.5
          )
        ])
      ).execute([request])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome digests must be sha256"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: "raw transcript",
            toolEventDigest: Self.digest(951),
            verifierFeedback: "bad digest",
            score: 0.5
          )
        ])
      ).execute([request])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome digests must be sha256"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: "sha256:\(String(repeating: "z", count: 64))",
            toolEventDigest: Self.digest(961),
            verifierFeedback: "bad hex digest",
            score: 0.5
          )
        ])
      ).execute([request])
    }
  }

}
