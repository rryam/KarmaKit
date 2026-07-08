You are reviewing a Swift 6.4 / Xcode 27 CoreAgent slice. Be adversarial and concise.

Context:
- Goal: Swift-native CoreAgent port of DeepAgents/LangGraph/SkillOpt/LangSmith patterns into Apple-platform idioms.
- This slice adds an OS AppIntents donation bridge over CoreAgent's typed donation records and action gate.
- Required contract: OS donation through IntentDonationManager must not bypass CoreAgent donation policy, consent/capability gating, stable non-sensitive donation identity, run-ID validation, or invalidation semantics.
- Review for correctness/security/concurrency/API-contract bugs only. Ignore cosmetic style unless it hides a bug.
- Findings should be P0/P1/P2 with exact file/line references. If no blockers, say so.

Important latest-source context checked today:
- PyPI deepagents latest: 0.6.12 released 2026-06-25.
- PyPI langgraph latest: 1.2.8 released 2026-07-06.
- PyPI langsmith latest: 0.9.8 released 2026-07-06.
- SkillOpt latest GitHub release: v0.2.0 SkillOpt-Sleep released 2026-07-02.

Source: Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift lines 240-590
```swift
0240:   }
0241: }
0242: 
0243: public struct CoreAgentAppIntentOSDonationToken:
0244:   Codable, Equatable, Hashable, Sendable
0245: {
0246:   public let encodedIdentifier: Data
0247:   public let digest: String
0248: 
0249:   public init(encodedIdentifier: Data) {
0250:     self.encodedIdentifier = encodedIdentifier
0251:     self.digest = "sha256:" + sha256Hex(encodedIdentifier)
0252:   }
0253: 
0254:   fileprivate init(identifier: IntentDonationIdentifier) throws {
0255:     self.init(encodedIdentifier: try JSONEncoder().encode(identifier))
0256:   }
0257: 
0258:   fileprivate func osIdentifier() throws -> IntentDonationIdentifier {
0259:     try JSONDecoder().decode(IntentDonationIdentifier.self, from: encodedIdentifier)
0260:   }
0261: }
0262: 
0263: public struct CoreAgentRunAppIntentDonationBackendRequest:
0264:   Codable, Equatable, Hashable, Sendable
0265: {
0266:   public let kind: CoreAgentRunAppIntentKind
0267:   public let runID: String
0268: 
0269:   public init(kind: CoreAgentRunAppIntentKind, runID: String) {
0270:     self.kind = kind
0271:     self.runID = runID
0272:   }
0273: }
0274: 
0275: public enum CoreAgentRunAppIntentDonationBackendError:
0276:   Error, Equatable, Sendable
0277: {
0278:   case invalidRunID(CoreAgentRunAppIntentKind)
0279:   case disabledDonation(identifier: String)
0280: }
0281: 
0282: public protocol CoreAgentRunAppIntentDonationBackend: Sendable {
0283:   func donate(
0284:     _ request: CoreAgentRunAppIntentDonationBackendRequest
0285:   ) async throws -> CoreAgentAppIntentOSDonationToken
0286: 
0287:   func deleteDonation(
0288:     _ token: CoreAgentAppIntentOSDonationToken
0289:   ) async throws -> [CoreAgentAppIntentOSDonationToken]
0290: }
0291: 
0292: public struct CoreAgentIntentDonationManagerRunBackend:
0293:   CoreAgentRunAppIntentDonationBackend
0294: {
0295:   public init() {}
0296: 
0297:   public func validate(
0298:     _ request: CoreAgentRunAppIntentDonationBackendRequest
0299:   ) throws -> CoreAgentAppIntentDescriptor {
0300:     guard CoreAgentRunAppIntentRuntime.isValidRunID(request.runID) else {
0301:       throw CoreAgentRunAppIntentDonationBackendError.invalidRunID(request.kind)
0302:     }
0303:     let descriptor = try Self.descriptor(for: request.kind).validatedForAgentExposure()
0304:     guard descriptor.donationPolicy != .doNotDonate else {
0305:       throw CoreAgentRunAppIntentDonationBackendError.disabledDonation(
0306:         identifier: descriptor.identifier
0307:       )
0308:     }
0309:     return descriptor
0310:   }
0311: 
0312:   public func donate(
0313:     _ request: CoreAgentRunAppIntentDonationBackendRequest
0314:   ) async throws -> CoreAgentAppIntentOSDonationToken {
0315:     _ = try validate(request)
0316:     let identifier: IntentDonationIdentifier
0317:     switch request.kind {
0318:     case .openRun:
0319:       identifier = try await IntentDonationManager.shared.donate(
0320:         intent: CoreAgentOpenRunIntent(runID: request.runID)
0321:       )
0322:     case .pauseRun:
0323:       identifier = try await IntentDonationManager.shared.donate(
0324:         intent: CoreAgentPauseRunIntent(runID: request.runID)
0325:       )
0326:     case .continueRun:
0327:       identifier = try await IntentDonationManager.shared.donate(
0328:         intent: CoreAgentContinueRunIntent(runID: request.runID)
0329:       )
0330:     }
0331:     return try CoreAgentAppIntentOSDonationToken(identifier: identifier)
0332:   }
0333: 
0334:   public func deleteDonation(
0335:     _ token: CoreAgentAppIntentOSDonationToken
0336:   ) async throws -> [CoreAgentAppIntentOSDonationToken] {
0337:     let identifier = try token.osIdentifier()
0338:     let deleted = try await IntentDonationManager.shared.deleteDonations(
0339:       matching: .donationIdentifier(identifier)
0340:     )
0341:     return try deleted.map(CoreAgentAppIntentOSDonationToken.init(identifier:))
0342:   }
0343: 
0344:   private static func descriptor(
0345:     for kind: CoreAgentRunAppIntentKind
0346:   ) -> CoreAgentAppIntentDescriptor {
0347:     switch kind {
0348:     case .openRun:
0349:       CoreAgentOpenRunIntent.coreAgentDescriptor
0350:     case .pauseRun:
0351:       CoreAgentPauseRunIntent.coreAgentDescriptor
0352:     case .continueRun:
0353:       CoreAgentContinueRunIntent.coreAgentDescriptor
0354:     }
0355:   }
0356: }
0357: 
0358: public struct CoreAgentRunAppIntentDonationRequest: Equatable, Sendable {
0359:   public let kind: CoreAgentRunAppIntentKind
0360:   public let runID: String
0361:   public let subject: CoreAgentAppIntentDonationSubject
0362:   public let authorityBoundaryID: String
0363:   public let policyVersion: Int
0364:   public let consent: CoreAgentAppleConsent
0365: 
0366:   public init(
0367:     kind: CoreAgentRunAppIntentKind,
0368:     runID: String,
0369:     subject: CoreAgentAppIntentDonationSubject,
0370:     authorityBoundaryID: String,
0371:     policyVersion: Int,
0372:     consent: CoreAgentAppleConsent
0373:   ) {
0374:     self.kind = kind
0375:     self.runID = runID
0376:     self.subject = subject
0377:     self.authorityBoundaryID = authorityBoundaryID
0378:     self.policyVersion = policyVersion
0379:     self.consent = consent
0380:   }
0381: }
0382: 
0383: public enum CoreAgentRunAppIntentDonationRejection: Equatable, Sendable {
0384:   case invalidRunID(CoreAgentRunAppIntentKind)
0385:   case invalidDonationRecord(CoreAgentAppIntentDonationError)
0386:   case unexpectedDonationRecordError(String)
0387:   case localRecordRejected(String)
0388: }
0389: 
0390: public struct CoreAgentRunAppIntentDonationReceipt:
0391:   Codable, Equatable, Identifiable, Sendable
0392: {
0393:   public var id: String { record.donationIdentifier }
0394: 
0395:   public let record: CoreAgentAppIntentDonationRecord
0396:   public let osDonationIdentifierDigest: String
0397:   public let donatedAt: Date
0398: 
0399:   public init(
0400:     record: CoreAgentAppIntentDonationRecord,
0401:     osDonationIdentifierDigest: String,
0402:     donatedAt: Date
0403:   ) {
0404:     self.record = record
0405:     self.osDonationIdentifierDigest = osDonationIdentifierDigest
0406:     self.donatedAt = donatedAt
0407:   }
0408: }
0409: 
0410: public enum CoreAgentRunAppIntentDonationStatus: Equatable, Sendable {
0411:   case donated(CoreAgentRunAppIntentDonationReceipt)
0412:   case denied(CoreAgentAppleActionGateDenial)
0413:   case rejected(CoreAgentRunAppIntentDonationRejection)
0414:   case failed(String)
0415: }
0416: 
0417: public struct CoreAgentRunAppIntentDonationResult: Equatable, Sendable {
0418:   public let status: CoreAgentRunAppIntentDonationStatus
0419: 
0420:   public init(status: CoreAgentRunAppIntentDonationStatus) {
0421:     self.status = status
0422:   }
0423: }
0424: 
0425: public struct CoreAgentRunAppIntentDonationInvalidationRequest:
0426:   Equatable, Sendable
0427: {
0428:   public let receipt: CoreAgentRunAppIntentDonationReceipt
0429:   public let osDonationToken: CoreAgentAppIntentOSDonationToken
0430:   public let request: CoreAgentAppIntentDonationInvalidationRequest
0431: 
0432:   public init(
0433:     receipt: CoreAgentRunAppIntentDonationReceipt,
0434:     osDonationToken: CoreAgentAppIntentOSDonationToken,
0435:     request: CoreAgentAppIntentDonationInvalidationRequest
0436:   ) {
0437:     self.receipt = receipt
0438:     self.osDonationToken = osDonationToken
0439:     self.request = request
0440:   }
0441: }
0442: 
0443: public enum CoreAgentRunAppIntentDonationInvalidationStatus:
0444:   Equatable, Sendable
0445: {
0446:   case invalidated
0447:   case skipped
0448:   case failed(String)
0449: }
0450: 
0451: public struct CoreAgentRunAppIntentDonationInvalidationResult:
0452:   Equatable, Sendable
0453: {
0454:   public let receipt: CoreAgentRunAppIntentDonationReceipt
0455:   public let deletedOSDonationIdentifierDigests: [String]
0456:   public let invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord]
0457:   public let status: CoreAgentRunAppIntentDonationInvalidationStatus
0458: 
0459:   public init(
0460:     receipt: CoreAgentRunAppIntentDonationReceipt,
0461:     deletedOSDonationIdentifierDigests: [String],
0462:     invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord],
0463:     status: CoreAgentRunAppIntentDonationInvalidationStatus
0464:   ) {
0465:     self.receipt = receipt
0466:     self.deletedOSDonationIdentifierDigests = deletedOSDonationIdentifierDigests
0467:     self.invalidationRecords = invalidationRecords
0468:     self.status = status
0469:   }
0470: }
0471: 
0472: public struct CoreAgentRunAppIntentDonationBridge: Sendable {
0473:   public let actionGate: CoreAgentAppleActionGate
0474:   private let backend: any CoreAgentRunAppIntentDonationBackend
0475:   private let store: InMemoryCoreAgentAppIntentDonationStore?
0476:   private let now: @Sendable () -> Date
0477: 
0478:   public init(
0479:     actionGate: CoreAgentAppleActionGate,
0480:     backend: any CoreAgentRunAppIntentDonationBackend =
0481:       CoreAgentIntentDonationManagerRunBackend(),
0482:     store: InMemoryCoreAgentAppIntentDonationStore? = nil,
0483:     now: @escaping @Sendable () -> Date = Date.init
0484:   ) {
0485:     self.actionGate = actionGate
0486:     self.backend = backend
0487:     self.store = store
0488:     self.now = now
0489:   }
0490: 
0491:   public func donate(
0492:     _ request: CoreAgentRunAppIntentDonationRequest
0493:   ) async -> CoreAgentRunAppIntentDonationResult {
0494:     guard CoreAgentRunAppIntentRuntime.isValidRunID(request.runID) else {
0495:       return CoreAgentRunAppIntentDonationResult(status: .rejected(.invalidRunID(request.kind)))
0496:     }
0497:     let donationTime = now()
0498:     let record: CoreAgentAppIntentDonationRecord
0499:     do {
0500:       record = try CoreAgentAppIntentDonationRecord(
0501:         descriptor: Self.descriptor(for: request.kind),
0502:         subject: request.subject,
0503:         authorityBoundaryID: request.authorityBoundaryID,
0504:         policyVersion: request.policyVersion,
0505:         donatedAt: donationTime
0506:       )
0507:     } catch let error as CoreAgentAppIntentDonationError {
0508:       return CoreAgentRunAppIntentDonationResult(
0509:         status: .rejected(.invalidDonationRecord(error))
0510:       )
0511:     } catch {
0512:       return CoreAgentRunAppIntentDonationResult(
0513:         status: .rejected(.unexpectedDonationRecordError(String(describing: error)))
0514:       )
0515:     }
0516: 
0517:     let executionRequest = CoreAgentAppleExecutionRequest.appIntentDonationRecord(record: record)
0518:     switch actionGate.evaluate(executionRequest, consent: request.consent) {
0519:     case .allowed:
0520:       break
0521:     case .denied(let denial):
0522:       return CoreAgentRunAppIntentDonationResult(status: .denied(denial))
0523:     }
0524: 
0525:     if let store {
0526:       let recorded = await store.record(record)
0527:       guard recorded else {
0528:         return CoreAgentRunAppIntentDonationResult(
0529:           status: .rejected(.localRecordRejected(record.donationIdentifier))
0530:         )
0531:       }
0532:     }
0533: 
0534:     do {
0535:       let token = try await backend.donate(
0536:         CoreAgentRunAppIntentDonationBackendRequest(kind: request.kind, runID: request.runID)
0537:       )
0538:       return CoreAgentRunAppIntentDonationResult(
0539:         status: .donated(CoreAgentRunAppIntentDonationReceipt(
0540:           record: record,
0541:           osDonationIdentifierDigest: token.digest,
0542:           donatedAt: donationTime
0543:         ))
0544:       )
0545:     } catch {
0546:       if let store {
0547:         _ = await store.invalidate(CoreAgentAppIntentDonationInvalidationRequest(
0548:           donationIdentifier: record.donationIdentifier,
0549:           reason: .policyChanged,
0550:           invalidatedAt: now()
0551:         ))
0552:       }
0553:       return CoreAgentRunAppIntentDonationResult(status: .failed(String(describing: error)))
0554:     }
0555:   }
0556: 
0557:   public func invalidate(
0558:     _ request: CoreAgentRunAppIntentDonationInvalidationRequest
0559:   ) async -> CoreAgentRunAppIntentDonationInvalidationResult {
0560:     guard Self.invalidationRequest(request.request, matches: request.receipt.record) else {
0561:       return CoreAgentRunAppIntentDonationInvalidationResult(
0562:         receipt: request.receipt,
0563:         deletedOSDonationIdentifierDigests: [],
0564:         invalidationRecords: [],
0565:         status: .skipped
0566:       )
0567:     }
0568:     do {
0569:       let deleted = try await backend.deleteDonation(request.osDonationToken)
0570:       let invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord]
0571:       if let store {
0572:         invalidationRecords = await store.invalidate(request.request)
0573:       } else {
0574:         invalidationRecords = [
0575:           CoreAgentAppIntentDonationInvalidationRecord(
0576:             donationIdentifier: request.receipt.record.donationIdentifier,
0577:             descriptorIdentifier: request.receipt.record.descriptorIdentifier,
0578:             subject: request.receipt.record.subject,
0579:             reason: request.request.reason,
0580:             invalidatedAt: request.request.invalidatedAt
0581:           )
0582:         ]
0583:       }
0584:       return CoreAgentRunAppIntentDonationInvalidationResult(
0585:         receipt: request.receipt,
0586:         deletedOSDonationIdentifierDigests: deleted.map(\.digest).sorted(),
0587:         invalidationRecords: invalidationRecords,
0588:         status: .invalidated
0589:       )
0590:     } catch {
```

Source: Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift lines 591-760
```swift
0591:       return CoreAgentRunAppIntentDonationInvalidationResult(
0592:         receipt: request.receipt,
0593:         deletedOSDonationIdentifierDigests: [],
0594:         invalidationRecords: [],
0595:         status: .failed(String(describing: error))
0596:       )
0597:     }
0598:   }
0599: 
0600:   private static func invalidationRequest(
0601:     _ request: CoreAgentAppIntentDonationInvalidationRequest,
0602:     matches record: CoreAgentAppIntentDonationRecord
0603:   ) -> Bool {
0604:     let matchesDonation = request.donationIdentifier.map {
0605:       $0 == record.donationIdentifier
0606:     } ?? false
0607:     let matchesScope = request.scopeID.map {
0608:       $0 == record.subject.scopeID
0609:     } ?? false
0610:     return matchesDonation || matchesScope
0611:   }
0612: 
0613:   private static func descriptor(
0614:     for kind: CoreAgentRunAppIntentKind
0615:   ) -> CoreAgentAppIntentDescriptor {
0616:     switch kind {
0617:     case .openRun:
0618:       CoreAgentOpenRunIntent.coreAgentDescriptor
0619:     case .pauseRun:
0620:       CoreAgentPauseRunIntent.coreAgentDescriptor
0621:     case .continueRun:
0622:       CoreAgentContinueRunIntent.coreAgentDescriptor
0623:     }
0624:   }
0625: }
0626: 
0627: public enum CoreAgentRunAppIntentKind: String, Codable, Equatable, Sendable {
0628:   case openRun = "CoreAgentOpenRunIntent"
0629:   case pauseRun = "CoreAgentPauseRunIntent"
0630:   case continueRun = "CoreAgentContinueRunIntent"
0631: }
0632: 
0633: public struct CoreAgentRunAppIntentRuntimeRequest: Equatable, Sendable {
0634:   public let kind: CoreAgentRunAppIntentKind
0635:   public let runID: String
0636: 
0637:   public init(kind: CoreAgentRunAppIntentKind, runID: String) {
0638:     self.kind = kind
0639:     self.runID = runID
0640:   }
0641: }
0642: 
0643: public enum CoreAgentRunAppIntentRuntimeError: Error, Equatable, Sendable {
0644:   case invalidRunID(CoreAgentRunAppIntentKind)
0645:   case handlerUnavailable(CoreAgentRunAppIntentKind)
0646:   case cancelled(CoreAgentRunAppIntentKind)
0647:   case denied(CoreAgentRunAppIntentKind, CoreAgentAppleActionGateDenial)
0648:   case missingCheckpoint(CoreAgentRunAppIntentKind)
0649:   case failed(CoreAgentRunAppIntentKind, String)
0650: }
0651: 
0652: public struct CoreAgentRunAppIntentRuntimeEnvironment: Sendable {
0653:   public typealias ModeProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
0654:     -> CoreAgentAppleAppIntentMode
0655:   public typealias TargetProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
0656:     -> CoreAgentAppleAppIntentExecutionTarget
0657:   public typealias ConsentProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
0658:     -> CoreAgentAppleConsent
0659:   public typealias CheckpointKeyProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
0660:     -> String?
0661:   public typealias Operation = @Sendable (CoreAgentRunAppIntentRuntimeRequest) async throws -> Void
0662: 
0663:   public let bridge: CoreAgentAppIntentBridge
0664:   public let mode: ModeProvider
0665:   public let target: TargetProvider
0666:   public let consent: ConsentProvider
0667:   public let checkpointKey: CheckpointKeyProvider
0668:   public let operation: Operation
0669: 
0670:   public init(
0671:     bridge: CoreAgentAppIntentBridge,
0672:     mode: @escaping ModeProvider,
0673:     target: @escaping TargetProvider,
0674:     consent: @escaping ConsentProvider,
0675:     checkpointKey: @escaping CheckpointKeyProvider,
0676:     operation: @escaping Operation
0677:   ) {
0678:     self.bridge = bridge
0679:     self.mode = mode
0680:     self.target = target
0681:     self.consent = consent
0682:     self.checkpointKey = checkpointKey
0683:     self.operation = operation
0684:   }
0685: }
0686: 
0687: public actor CoreAgentRunAppIntentRuntime {
0688:   public static let shared = CoreAgentRunAppIntentRuntime()
0689:   private static let maxRunIDBytes = 128
0690: 
0691:   private var environment: CoreAgentRunAppIntentRuntimeEnvironment?
0692: 
0693:   public init(environment: CoreAgentRunAppIntentRuntimeEnvironment? = nil) {
0694:     self.environment = environment
0695:   }
0696: 
0697:   public func setEnvironment(_ environment: CoreAgentRunAppIntentRuntimeEnvironment) {
0698:     self.environment = environment
0699:   }
0700: 
0701:   public func resetEnvironment() {
0702:     environment = nil
0703:   }
0704: 
0705:   public func perform(_ request: CoreAgentRunAppIntentRuntimeRequest) async throws {
0706:     guard Self.isValidRunID(request.runID) else {
0707:       throw CoreAgentRunAppIntentRuntimeError.invalidRunID(request.kind)
0708:     }
0709:     guard !Task.isCancelled else {
0710:       throw CoreAgentRunAppIntentRuntimeError.cancelled(request.kind)
0711:     }
0712:     guard let environment else {
0713:       throw CoreAgentRunAppIntentRuntimeError.handlerUnavailable(request.kind)
0714:     }
0715:     let mode = environment.mode(request)
0716:     let target = environment.target(request)
0717:     let descriptor = Self.descriptor(for: request.kind)
0718:     let bridgeRequest = CoreAgentAppIntentBridgeRequest(
0719:       actionID: "\(request.kind.rawValue):\(request.runID)",
0720:       descriptor: descriptor,
0721:       mode: mode,
0722:       target: target,
0723:       consent: environment.consent(request),
0724:       checkpointKey: environment.checkpointKey(request)
0725:     )
0726:     let result = await environment.bridge.perform(bridgeRequest) { _ in
0727:       try await environment.operation(request)
0728:       return CoreAgentAppIntentBridgeOperationResult()
0729:     }
0730:     switch result.status {
0731:     case .completed:
0732:       return
0733:     case .cancelled:
0734:       throw CoreAgentRunAppIntentRuntimeError.cancelled(request.kind)
0735:     case .denied(let denial):
0736:       throw CoreAgentRunAppIntentRuntimeError.denied(request.kind, denial)
0737:     case .missingCheckpoint:
0738:       throw CoreAgentRunAppIntentRuntimeError.missingCheckpoint(request.kind)
0739:     case .failed(let reason):
0740:       throw CoreAgentRunAppIntentRuntimeError.failed(request.kind, reason)
0741:     }
0742:   }
0743: 
0744:   fileprivate static func isValidRunID(_ runID: String) -> Bool {
0745:     let trimmed = runID.trimmingCharacters(in: .whitespacesAndNewlines)
0746:     guard trimmed == runID && !runID.isEmpty && runID.utf8.count <= maxRunIDBytes else {
0747:       return false
0748:     }
0749:     guard let first = runID.unicodeScalars.first, isASCIIAlphanumeric(first) else {
0750:       return false
0751:     }
0752:     return runID.unicodeScalars.allSatisfy { scalar in
0753:       isASCIIAlphanumeric(scalar)
0754:         || scalar.value == 45
0755:         || scalar.value == 46
0756:         || scalar.value == 95
0757:     }
0758:   }
0759: 
0760:   private static func descriptor(
```

Tests: Tests/CoreAgentAppIntentsTests/CoreAgentAppIntentsTests.swift lines 288-430
```swift
0288:   @Test("OS donation bridge gates records and donates through backend")
0289:   func osDonationBridgeGatesRecordsAndDonatesThroughBackend() async throws {
0290:     let backend = FakeRunDonationBackend(tokens: [
0291:       CoreAgentRunAppIntentDonationBackendRequest(kind: .pauseRun, runID: "run-1"):
0292:         CoreAgentAppIntentOSDonationToken(encodedIdentifier: Data("os:pause:run-1".utf8))
0293:     ])
0294:     let store = InMemoryCoreAgentAppIntentDonationStore()
0295:     let gate = Self.appIntentDonationGate()
0296:     let bridge = CoreAgentRunAppIntentDonationBridge(
0297:       actionGate: gate,
0298:       backend: backend,
0299:       store: store,
0300:       now: { Date(timeIntervalSince1970: 1_800_000_500) }
0301:     )
0302:     let subject = CoreAgentAppIntentDonationSubject(
0303:       kind: .runOutcome,
0304:       stableIdentifier: "run-1:paused",
0305:       scopeID: "workspace:coreagent"
0306:     )
0307:     let expectedRecord = try CoreAgentAppIntentDonationRecord(
0308:       descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
0309:       subject: subject,
0310:       authorityBoundaryID: "workspace:coreagent",
0311:       policyVersion: 27,
0312:       donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
0313:     )
0314:     let requirement = gate.consentRequirement(
0315:       for: .appIntentDonationRecord(record: expectedRecord)
0316:     )
0317: 
0318:     let result = await bridge.donate(
0319:       CoreAgentRunAppIntentDonationRequest(
0320:         kind: .pauseRun,
0321:         runID: "run-1",
0322:         subject: subject,
0323:         authorityBoundaryID: "workspace:coreagent",
0324:         policyVersion: 27,
0325:         consent: .granted(Self.receipt(id: "pause-donation", requirement: requirement))
0326:       )
0327:     )
0328: 
0329:     #expect(result.status == .donated(CoreAgentRunAppIntentDonationReceipt(
0330:       record: expectedRecord,
0331:       osDonationIdentifierDigest: CoreAgentAppIntentOSDonationToken(
0332:         encodedIdentifier: Data("os:pause:run-1".utf8)
0333:       ).digest,
0334:       donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
0335:     )))
0336:     #expect(await backend.donationRequests == [
0337:       CoreAgentRunAppIntentDonationBackendRequest(kind: .pauseRun, runID: "run-1")
0338:     ])
0339:     #expect(await store.activeRecords() == [expectedRecord])
0340:   }
0341: 
0342:   @Test("OS donation bridge denies before backend work")
0343:   func osDonationBridgeDeniesBeforeBackendWork() async throws {
0344:     let backend = FakeRunDonationBackend(tokens: [:])
0345:     let gate = Self.appIntentDonationGate(capabilities: [])
0346:     let bridge = CoreAgentRunAppIntentDonationBridge(
0347:       actionGate: gate,
0348:       backend: backend,
0349:       now: { Date(timeIntervalSince1970: 1_800_000_500) }
0350:     )
0351:     let subject = CoreAgentAppIntentDonationSubject(
0352:       kind: .runOutcome,
0353:       stableIdentifier: "run-1:paused",
0354:       scopeID: "workspace:coreagent"
0355:     )
0356: 
0357:     let denied = await bridge.donate(
0358:       CoreAgentRunAppIntentDonationRequest(
0359:         kind: .pauseRun,
0360:         runID: "run-1",
0361:         subject: subject,
0362:         authorityBoundaryID: "workspace:coreagent",
0363:         policyVersion: 27,
0364:         consent: .notRequired
0365:       )
0366:     )
0367:     let disabled = await bridge.donate(
0368:       CoreAgentRunAppIntentDonationRequest(
0369:         kind: .openRun,
0370:         runID: "run-1",
0371:         subject: subject,
0372:         authorityBoundaryID: "workspace:coreagent",
0373:         policyVersion: 27,
0374:         consent: .notRequired
0375:       )
0376:     )
0377:     let invalidRun = await bridge.donate(
0378:       CoreAgentRunAppIntentDonationRequest(
0379:         kind: .pauseRun,
0380:         runID: "../run-1",
0381:         subject: subject,
0382:         authorityBoundaryID: "workspace:coreagent",
0383:         policyVersion: 27,
0384:         consent: .notRequired
0385:       )
0386:     )
0387: 
0388:     #expect(denied.status == .denied(.missingCapability(.appIntentDonation)))
0389:     #expect(disabled.status == .rejected(.invalidDonationRecord(
0390:       .disabledDonation(identifier: "CoreAgentOpenRunIntent")
0391:     )))
0392:     #expect(invalidRun.status == .rejected(.invalidRunID(.pauseRun)))
0393:     #expect(await backend.donationRequests.isEmpty)
0394:   }
0395: 
0396:   @Test("OS donation backend rejects invalid requests before OS work")
0397:   func osDonationBackendRejectsInvalidRequestsBeforeOSWork() async throws {
0398:     let backend = CoreAgentIntentDonationManagerRunBackend()
0399: 
0400:     #expect(throws: CoreAgentRunAppIntentDonationBackendError.disabledDonation(
0401:       identifier: "CoreAgentOpenRunIntent"
0402:     )) {
0403:       _ = try backend.validate(CoreAgentRunAppIntentDonationBackendRequest(
0404:         kind: .openRun,
0405:         runID: "run-1"
0406:       ))
0407:     }
0408:     #expect(throws: CoreAgentRunAppIntentDonationBackendError.invalidRunID(.pauseRun)) {
0409:       _ = try backend.validate(CoreAgentRunAppIntentDonationBackendRequest(
0410:         kind: .pauseRun,
0411:         runID: "../run-1"
0412:       ))
0413:     }
0414:   }
0415: 
0416:   @Test("OS donation bridge invalidates matching donations through backend")
0417:   func osDonationBridgeInvalidatesMatchingDonationsThroughBackend() async throws {
0418:     let token = CoreAgentAppIntentOSDonationToken(
0419:       encodedIdentifier: Data("os:pause:run-1".utf8)
0420:     )
0421:     let backend = FakeRunDonationBackend(tokens: [:], deletedTokens: [token: [token]])
0422:     let store = InMemoryCoreAgentAppIntentDonationStore()
0423:     let gate = Self.appIntentDonationGate()
0424:     let bridge = CoreAgentRunAppIntentDonationBridge(
0425:       actionGate: gate,
0426:       backend: backend,
0427:       store: store,
0428:       now: { Date(timeIntervalSince1970: 1_800_000_500) }
0429:     )
0430:     let record = try CoreAgentAppIntentDonationRecord(
```

Tests: fake backend lines 741-780
```swift
0741:     recordedRequests
0742:   }
0743: 
0744:   func record(_ request: CoreAgentRunAppIntentRuntimeRequest) {
0745:     recordedRequests.append(request)
0746:   }
0747: }
0748: 
0749: private final class CancellationProbe: @unchecked Sendable {
0750:   private let lock = NSLock()
0751:   private var checks = 0
0752: 
0753:   func cancelAfterFirstCheck() -> Bool {
0754:     lock.withLock {
0755:       checks += 1
0756:       return checks > 1
0757:     }
0758:   }
0759: }
0760: 
0761: private actor FakeRunDonationBackend: CoreAgentRunAppIntentDonationBackend {
0762:   private let tokens: [CoreAgentRunAppIntentDonationBackendRequest:
0763:     CoreAgentAppIntentOSDonationToken]
0764:   private let deletedTokenResults: [CoreAgentAppIntentOSDonationToken:
0765:     [CoreAgentAppIntentOSDonationToken]]
0766:   private var recordedDonationRequests: [CoreAgentRunAppIntentDonationBackendRequest] = []
0767:   private var recordedDeletedTokens: [CoreAgentAppIntentOSDonationToken] = []
0768: 
0769:   init(
0770:     tokens: [CoreAgentRunAppIntentDonationBackendRequest: CoreAgentAppIntentOSDonationToken],
0771:     deletedTokens: [CoreAgentAppIntentOSDonationToken: [CoreAgentAppIntentOSDonationToken]] = [:]
0772:   ) {
0773:     self.tokens = tokens
0774:     self.deletedTokenResults = deletedTokens
0775:   }
0776: 
0777:   var donationRequests: [CoreAgentRunAppIntentDonationBackendRequest] {
0778:     recordedDonationRequests
0779:   }
0780: 
```
