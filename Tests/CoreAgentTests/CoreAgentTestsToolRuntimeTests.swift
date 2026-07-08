import CoreAgent
import CoreAgentTestSupport
import CoreGraphics
import Foundation
import FoundationModels
import Testing

extension CoreAgentTests {
  @Test("Replaces restored instructions when current instructions are supplied")
  func instructionRebasing() async throws {
    let store = InMemoryCheckpointStore()
    let first = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "saved")]),
      instructions: Instructions("Old instructions"),
      checkpointStore: store,
      checkpointKey: "instructions"
    )
    _ = try await first.respond(to: "Save")

    let model = RecordedLanguageModel(steps: [.response(text: "rebased")])
    let second = try CoreAgentSession(
      model: model,
      instructions: Instructions("New instructions"),
      checkpointStore: store,
      checkpointKey: "instructions"
    )
    _ = try await second.respond(to: "Restore")

    let transcript = try #require(model.recorder.capturedTranscripts().first)
    let instructionText = transcript.compactMap { entry -> String? in
      guard case .instructions(let instructions) = entry else { return nil }
      return instructions.segments.compactMap { segment in
        guard case .text(let text) = segment else { return nil }
        return text.content
      }.joined(separator: " ")
    }.joined(separator: " ")
    #expect(instructionText.contains("New instructions"))
    #expect(!instructionText.contains("Old instructions"))
  }

  @Test("Rejects a checkpoint restored with a different toolset")
  func checkpointConfigurationMismatch() async throws {
    let store = InMemoryCheckpointStore()
    let first = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "saved")]),
      checkpointStore: store,
      checkpointKey: "toolset"
    )
    _ = try await first.respond(to: "Save")

    let second = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "unused")]),
      tools: [EchoTool(counter: InvocationCounter())],
      checkpointStore: store,
      checkpointKey: "toolset"
    )

    await #expect(throws: CoreAgentError.self) {
      _ = try await second.respond(to: "Restore")
    }
  }

  @Test("File checkpoints encode and decode native transcripts")
  func fileCheckpointRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
    )

    try await store.saveCheckpoint(checkpoint, for: "../../unsafe-key")
    let restored = try #require(try await store.loadCheckpoint(for: "../../unsafe-key"))

    #expect(restored.compatibilityRevision == "revision")
    #expect(restored.transcript == checkpoint.transcript)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
  }

  @Test("File checkpoints reject typed metadata instead of silently erasing its type")
  func fileCheckpointRejectsLossyMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(
          .init(
            metadata: ["provider_flag": true],
            segments: [.text(.init(content: "typed metadata"))]
          )
        )
      ])
    )

    await #expect(throws: CoreAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "lossy")
    }
  }

  @Test("File checkpoints reject custom segments without a rehydration codec")
  func fileCheckpointRejectsCustomSegments() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let custom = TestCustomSegment(
      id: "video",
      content: .init(value: "provider-specific")
    )
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.custom(custom)]))
      ])
    )

    await #expect(throws: CoreAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "custom")
    }
  }

  @Test("Checkpoint failures are recorded without turning a completed side effect into a retry")
  func checkpointFailureRecordsAndContinues() async throws {
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "completed")]),
      checkpointStore: FailingCheckpointStore()
    )

    let response = try await session.respond(to: "Complete")

    #expect(response.content == "completed")
    #expect(response.run.events.contains { $0.kind == .transcriptCheckpointFailed })
    #expect(response.run.events.last?.kind == .runCompleted)
  }

  @Test("Skips automatic retention work when no checkpoint store is configured")
  func disabledPersistenceSkipsRetention() async throws {
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "completed")]),
      configuration: .init(checkpointFailurePolicy: .failRun),
      transcriptRetention: .custom { _ in
        throw RetentionError.shouldNotRunAutomatically
      }
    )

    let response = try await session.respond(to: "Complete without persistence")

    #expect(response.content == "completed")
    #expect(!response.run.events.contains { $0.kind == .transcriptCheckpointFailed })
    await #expect(throws: RetentionError.self) {
      _ = try await session.checkpoint()
    }
  }

  @Test("Receipt verification detects tampering")
  func receiptTampering() async throws {
    let response = try await CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")])
    ).respond(to: "Receipt")
    let valid = try CoreAgentRunReceipt(run: response.run)
    let first = try #require(valid.receipts.first)
    let changedEvent = CoreAgentEvent(
      id: first.event.id,
      runID: first.event.runID,
      timestamp: first.event.timestamp,
      kind: first.event.kind,
      message: "tampered",
      attributes: first.event.attributes
    )
    var changedReceipts = valid.receipts
    changedReceipts[0] = CoreAgentEventReceipt(
      index: first.index,
      previousHash: first.previousHash,
      hash: first.hash,
      event: changedEvent
    )
    let tampered = CoreAgentRunReceipt(
      runID: valid.runID,
      receipts: changedReceipts,
      rootHash: valid.rootHash
    )

    #expect(valid.verify())
    #expect(!tampered.verify())

    let changedRunID = CoreAgentRunReceipt(
      runID: UUID(),
      receipts: valid.receipts,
      rootHash: valid.rootHash
    )
    #expect(!changedRunID.verify())
  }

  @Test("Exported receipts decode and verify with stable date encoding")
  func receiptExportRoundTrip() async throws {
    let response = try await CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")])
    ).respond(to: "Export")
    let exporter = CoreAgentReceiptExporter()

    let decoded = try exporter.decode(exporter.data(for: response.run))

    #expect(decoded.verify())
  }

  @Test("Redacts common credentials before observers and receipts see them")
  func eventRedaction() async throws {
    let capture = EventCapture()
    let model = RecordedLanguageModel(steps: [.failure("Bearer super-secret-token")])
    let session = try CoreAgentSession(
      model: model,
      observers: [ClosureCoreAgentObserver { await capture.append($0) }]
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Fail")
    }

    await session.flushObservers()
    let messages = await capture.events.map(\.message).joined(separator: "\n")
    #expect(!messages.contains("super-secret-token"))
    #expect(messages.contains("[REDACTED]"))
  }

  @Test("Bounds a stalled observer and times out flush instead of blocking the runtime")
  func boundedObserverDelivery() async throws {
    let gate = ObserverGate()
    let capture = EventCapture()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [
        ClosureCoreAgentObserver { event in
          await gate.wait()
          await capture.append(event)
        }
      ],
      observerDeliveryConfiguration: .init(
        maximumPendingEvents: 1,
        overflowPolicy: .dropNewest,
        defaultFlushTimeout: .milliseconds(10)
      )
    )

    let response = try await session.respond(to: "Do not wait for the observer")

    let timedOut = await session.flushObservers()
    #expect(timedOut.status == .timedOut)
    #expect(!timedOut.deliveredAllEvents)
    await gate.open()
    let drained = await session.flushObservers(timeout: .seconds(1))
    #expect(drained.status == .drained)
    #expect(drained.cumulativeDroppedEventCount > 0)
    #expect(!drained.deliveredAllEvents)
    #expect(await capture.events.count < response.run.events.count)
  }

  @Test("Reports a cancelled observer flush separately from a timeout")
  func cancelledObserverFlush() async throws {
    let gate = ObserverGate()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [ClosureCoreAgentObserver { _ in await gate.wait() }]
    )
    _ = try await session.respond(to: "Wait")
    let flush = Task { await session.flushObservers(timeout: .seconds(5)) }

    flush.cancel()

    #expect(await flush.value.status == .cancelled)
    await gate.open()
    #expect(await session.flushObservers(timeout: .seconds(1)).deliveredAllEvents)
  }

  @Test("Rejects a reentrant observer flush without deadlocking")
  func reentrantObserverFlush() async throws {
    let reference = SessionReference()
    let results = BooleanCapture()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [
        ClosureCoreAgentObserver { _ in
          guard let session = await reference.get() else { return }
          let flush = await session.flushObservers(timeout: .seconds(1))
          await results.append(flush.status == .reentrant)
        }
      ]
    )
    await reference.set(session)

    _ = try await session.respond(to: "Observe")

    #expect(await session.flushObservers(timeout: .seconds(1)).deliveredAllEvents)
    let values = await results.values
    #expect(!values.isEmpty)
    #expect(values.allSatisfy { $0 })
  }

}
