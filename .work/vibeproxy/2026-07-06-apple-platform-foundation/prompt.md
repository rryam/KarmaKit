# Review Prompt: CoreAgent Apple Platform Foundation

You are reviewing a Swift Package diff for /Users/basitmustafa/Documents/GitHub/coreagent. The slice adds CoreAgentApplePlatform, an optional Apple-only adapter foundation for SwiftData checkpoint wrappers, sandbox/computer-use capability gating, App Intent exposure descriptors, and a SwiftUI/Observation projection store.

Review stance: adversarial. Return PASS only if there are no Critical/P1/P2 blockers. Findings must cite file paths and concrete line or symbol references. Ignore style-only comments. Do not request Python API compatibility. Do not treat missing future live stores/executors/AppIntent bundles as blockers if the runtime doc explicitly marks them non-goals. Do block issues where the current contract is unsafe, brittle, misleading, likely not to compile under Swift 6.4/Xcode 27, or creates an authority bypass.

Context: Package.swift already declares Apple OS 27 platforms for the whole package and the existing CoreAgent target imports FoundationModels, so generic Linux portability is not a blocker for this repo. Focus on this target’s actual Apple-platform contract. The diff includes all relevant new files; other new targets referenced in Package.swift have source directories in the working tree outside this focused diff.

Known explicit non-goals: concrete ModelContext-backed stores, JavaScriptCore/WASI/helper/remote executors, real AppIntent structs, AppIntentsTesting bundles, donation invalidation, and SwiftUI views. Contract gaps inside the implemented foundation are still blockers.

Specific risks to check:
- SwiftData @Model misuse or making row fields canonical instead of checkpoint bytes.
- Authority/read-barrier ordering, envelope digest verification, policy-version handling, sidecar metadata binding, and canonical checkpoint round trip.
- Swift concurrency/Sendable/Observation/@MainActor issues.
- Sandbox/computer-use/checkpoint-persistence/donation capability separation and consent bypasses.
- App Intent descriptor holes around explicit agent exposure, authorization, HITL, supported modes, allowed execution targets, foreground execution, exposure revisions, and donations.
- HMAC receipt issuer/signature verification, mandatory expiry, request fingerprint binding, and descriptor replay.
- Brittle tests that assert incidental implementation details rather than durable contracts.
- Documentation claims that overstate implementation.

Return format:
VERDICT: PASS or BLOCK
FINDINGS:
- severity, file/symbol, issue, why it matters, concrete fix
TEST GAPS:
- list only material gaps

Diff follows:
```diff
diff --git a/Package.swift b/Package.swift
index 9bd0098..f0a4ad4 100644
--- a/Package.swift
+++ b/Package.swift
@@ -11,7 +11,12 @@ let package = Package(
   ],
   products: [
     .library(name: "CoreAgent", targets: ["CoreAgent"]),
+    .library(name: "CoreAgentApplePlatform", targets: ["CoreAgentApplePlatform"]),
+    .library(name: "CoreAgentDeep", targets: ["CoreAgentDeep"]),
+    .library(name: "CoreAgentEngine", targets: ["CoreAgentEngine"]),
+    .library(name: "CoreAgentGraph", targets: ["CoreAgentGraph"]),
     .library(name: "CoreAgentMemory", targets: ["CoreAgentMemory"]),
+    .library(name: "CoreAgentSkills", targets: ["CoreAgentSkills"]),
     .library(name: "CoreAgentTestSupport", targets: ["CoreAgentTestSupport"]),
     .library(name: "CoreAgentProviders", targets: ["CoreAgentProviders"]),
   ],
@@ -51,11 +56,31 @@ let package = Package(
   ],
   targets: [
     .target(name: "CoreAgent"),
+    .target(
+      name: "CoreAgentApplePlatform",
+      dependencies: ["CoreAgent", "CoreAgentEngine"]
+    ),
+    .target(
+      name: "CoreAgentDeep",
+      dependencies: ["CoreAgent", "CoreAgentGraph"]
+    ),
+    .target(
+      name: "CoreAgentEngine",
+      dependencies: ["CoreAgent"]
+    ),
+    .target(
+      name: "CoreAgentGraph",
+      dependencies: ["CoreAgent"]
+    ),
     .target(
       name: "CoreAgentMemory",
       dependencies: ["CoreAgent"],
       linkerSettings: [.linkedLibrary("sqlite3")]
     ),
+    .target(
+      name: "CoreAgentSkills",
+      dependencies: ["CoreAgent"]
+    ),
     .target(
       name: "CoreAgentTestSupport",
       dependencies: ["CoreAgent"]
@@ -90,6 +115,10 @@ let package = Package(
       name: "CoreAgentTests",
       dependencies: ["CoreAgent", "CoreAgentTestSupport"]
     ),
+    .testTarget(
+      name: "CoreAgentApplePlatformTests",
+      dependencies: ["CoreAgent", "CoreAgentApplePlatform", "CoreAgentEngine"]
+    ),
     .testTarget(
       name: "CoreAgentProviderTests",
       dependencies: ["CoreAgent", "CoreAgentProviders"],
@@ -107,5 +136,21 @@ let package = Package(
       name: "CoreAgentMemoryIntegrationTests",
       dependencies: ["CoreAgent", "CoreAgentMemory", "CoreAgentTestSupport"]
     ),
+    .testTarget(
+      name: "CoreAgentGraphTests",
+      dependencies: ["CoreAgentGraph"]
+    ),
+    .testTarget(
+      name: "CoreAgentDeepTests",
+      dependencies: ["CoreAgentDeep", "CoreAgentTestSupport"]
+    ),
+    .testTarget(
+      name: "CoreAgentEngineTests",
+      dependencies: ["CoreAgentEngine", "CoreAgentTestSupport"]
+    ),
+    .testTarget(
+      name: "CoreAgentSkillsTests",
+      dependencies: ["CoreAgentSkills"]
+    ),
   ]
 )
diff --git a/Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift b/Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift
new file mode 100644
index 0000000..d00f21e
--- /dev/null
+++ b/Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift
@@ -0,0 +1,905 @@
+import CoreAgent
+import CoreAgentEngine
+import CryptoKit
+import Foundation
+import Observation
+import SwiftData
+
+public enum CoreAgentSwiftDataCheckpointAccessError: Error, Equatable, Sendable {
+  case authorityBoundaryMismatch(expected: String, actual: String)
+  case policyVersionMismatch(expected: Int, actual: Int)
+  case digestMismatch(expected: String, actual: String)
+  case formatVersionMismatch(expected: Int, actual: Int)
+  case compatibilityRevisionMismatch(expected: String, actual: String)
+}
+
+public struct CoreAgentSwiftDataCheckpointSnapshot: Equatable, Sendable {
+  public let checkpointID: UUID
+  public let checkpointKey: String
+  public let authorityBoundaryID: String
+  public let policyVersion: Int
+  public let checkpointFormatVersion: Int
+  public let compatibilityRevision: String
+  public let savedAt: Date
+  public let storedAt: Date
+  public let canonicalCheckpointData: Data
+  public let checkpointDigest: String
+
+  public init(
+    checkpointID: UUID = UUID(),
+    checkpointKey: String,
+    checkpoint: CoreAgentCheckpoint,
+    authorityBoundaryID: String,
+    policyVersion: Int,
+    storedAt: Date = Date()
+  ) throws {
+    let data = try Self.encoder().encode(checkpoint)
+    self.init(
+      checkpointID: checkpointID,
+      checkpointKey: checkpointKey,
+      authorityBoundaryID: authorityBoundaryID,
+      policyVersion: policyVersion,
+      checkpointFormatVersion: checkpoint.formatVersion,
+      compatibilityRevision: checkpoint.compatibilityRevision,
+      savedAt: checkpoint.savedAt,
+      storedAt: storedAt,
+      canonicalCheckpointData: data,
+      checkpointDigest: Self.digest(
+        checkpointKey: checkpointKey,
+        authorityBoundaryID: authorityBoundaryID,
+        policyVersion: policyVersion,
+        checkpointFormatVersion: checkpoint.formatVersion,
+        compatibilityRevision: checkpoint.compatibilityRevision,
+        savedAt: checkpoint.savedAt,
+        canonicalCheckpointData: data
+      )
+    )
+  }
+
+  public init(
+    checkpointID: UUID = UUID(),
+    checkpointKey: String,
+    authorityBoundaryID: String,
+    policyVersion: Int,
+    checkpointFormatVersion: Int,
+    compatibilityRevision: String,
+    savedAt: Date,
+    storedAt: Date,
+    canonicalCheckpointData: Data,
+    checkpointDigest: String
+  ) {
+    self.checkpointID = checkpointID
+    self.checkpointKey = checkpointKey
+    self.authorityBoundaryID = authorityBoundaryID
+    self.policyVersion = policyVersion
+    self.checkpointFormatVersion = checkpointFormatVersion
+    self.compatibilityRevision = compatibilityRevision
+    self.savedAt = savedAt
+    self.storedAt = storedAt
+    self.canonicalCheckpointData = canonicalCheckpointData
+    self.checkpointDigest = checkpointDigest
+  }
+
+  public func decodeCheckpoint(
+    expectedAuthorityBoundaryID: String,
+    expectedPolicyVersion: Int
+  ) throws -> CoreAgentCheckpoint {
+    guard authorityBoundaryID == expectedAuthorityBoundaryID else {
+      throw CoreAgentSwiftDataCheckpointAccessError.authorityBoundaryMismatch(
+        expected: expectedAuthorityBoundaryID,
+        actual: authorityBoundaryID
+      )
+    }
+    guard policyVersion == expectedPolicyVersion else {
+      throw CoreAgentSwiftDataCheckpointAccessError.policyVersionMismatch(
+        expected: expectedPolicyVersion,
+        actual: policyVersion
+      )
+    }
+    let actualDigest = Self.digest(
+      checkpointKey: checkpointKey,
+      authorityBoundaryID: authorityBoundaryID,
+      policyVersion: policyVersion,
+      checkpointFormatVersion: checkpointFormatVersion,
+      compatibilityRevision: compatibilityRevision,
+      savedAt: savedAt,
+      canonicalCheckpointData: canonicalCheckpointData
+    )
+    guard actualDigest == checkpointDigest else {
+      throw CoreAgentSwiftDataCheckpointAccessError.digestMismatch(
+        expected: checkpointDigest,
+        actual: actualDigest
+      )
+    }
+    let checkpoint = try Self.decoder().decode(
+      CoreAgentCheckpoint.self,
+      from: canonicalCheckpointData
+    )
+    guard checkpoint.formatVersion == checkpointFormatVersion else {
+      throw CoreAgentSwiftDataCheckpointAccessError.formatVersionMismatch(
+        expected: checkpointFormatVersion,
+        actual: checkpoint.formatVersion
+      )
+    }
+    guard checkpoint.compatibilityRevision == compatibilityRevision else {
+      throw CoreAgentSwiftDataCheckpointAccessError.compatibilityRevisionMismatch(
+        expected: compatibilityRevision,
+        actual: checkpoint.compatibilityRevision
+      )
+    }
+    return checkpoint
+  }
+
+  private static func encoder() -> JSONEncoder {
+    let encoder = JSONEncoder()
+    encoder.dateEncodingStrategy = .deferredToDate
+    encoder.outputFormatting = [.sortedKeys]
+    return encoder
+  }
+
+  private static func decoder() -> JSONDecoder {
+    let decoder = JSONDecoder()
+    decoder.dateDecodingStrategy = .deferredToDate
+    return decoder
+  }
+
+  private static func digest(
+    checkpointKey: String,
+    authorityBoundaryID: String,
+    policyVersion: Int,
+    checkpointFormatVersion: Int,
+    compatibilityRevision: String,
+    savedAt: Date,
+    canonicalCheckpointData: Data
+  ) -> String {
+    let checkpointBytesDigest = sha256Hex(canonicalCheckpointData)
+    let fields = [
+      checkpointKey,
+      authorityBoundaryID,
+      String(policyVersion),
+      String(checkpointFormatVersion),
+      compatibilityRevision,
+      timeToken(savedAt),
+      checkpointBytesDigest,
+    ]
+    return "sha256:" + sha256Hex(
+      Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
+    )
+  }
+
+  private static func sha256Hex(_ data: Data) -> String {
+    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
+    return hash
+  }
+
+  private static func timeToken(_ date: Date) -> String {
+    String(date.timeIntervalSinceReferenceDate.bitPattern)
+  }
+}
+
+@Model
+public final class CoreAgentSwiftDataCheckpointRecord {
+  public private(set) var checkpointID: UUID
+  public private(set) var checkpointKey: String
+  public private(set) var authorityBoundaryID: String
+  public private(set) var policyVersion: Int
+  public private(set) var checkpointFormatVersion: Int
+  public private(set) var compatibilityRevision: String
+  public private(set) var savedAt: Date
+  public private(set) var storedAt: Date
+  public private(set) var encodedCheckpoint: Data
+  public private(set) var checkpointDigest: String
+
+  public init(snapshot: CoreAgentSwiftDataCheckpointSnapshot) {
+    self.checkpointID = snapshot.checkpointID
+    self.checkpointKey = snapshot.checkpointKey
+    self.authorityBoundaryID = snapshot.authorityBoundaryID
+    self.policyVersion = snapshot.policyVersion
+    self.checkpointFormatVersion = snapshot.checkpointFormatVersion
+    self.compatibilityRevision = snapshot.compatibilityRevision
+    self.savedAt = snapshot.savedAt
+    self.storedAt = snapshot.storedAt
+    self.encodedCheckpoint = snapshot.canonicalCheckpointData
+    self.checkpointDigest = snapshot.checkpointDigest
+  }
+
+  public var snapshot: CoreAgentSwiftDataCheckpointSnapshot {
+    CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointID: checkpointID,
+      checkpointKey: checkpointKey,
+      authorityBoundaryID: authorityBoundaryID,
+      policyVersion: policyVersion,
+      checkpointFormatVersion: checkpointFormatVersion,
+      compatibilityRevision: compatibilityRevision,
+      savedAt: savedAt,
+      storedAt: storedAt,
+      canonicalCheckpointData: encodedCheckpoint,
+      checkpointDigest: checkpointDigest
+    )
+  }
+}
+
+public enum CoreAgentAppleExecutionCapability: String, Codable, Hashable, Sendable {
+  case deterministicCodeInterpreter
+  case wasiCodeInterpreter
+  case helperCodeInterpreter
+  case remoteCodeInterpreter
+  case computerUse
+  case appIntentExecution
+  case appIntentDonation
+  case swiftDataCheckpointPersistence
+}
+
+public enum CoreAgentAppleNetworkPolicy: String, Codable, Equatable, Sendable {
+  case denied
+  case localOnly
+  case allowed
+}
+
+public struct CoreAgentAppleSandboxProfile: Equatable, Sendable {
+  public let capabilities: Set<CoreAgentAppleExecutionCapability>
+  public let workspaceRoot: URL
+  public let networkPolicy: CoreAgentAppleNetworkPolicy
+  public let authorityBoundaryID: String
+  public let policyVersion: Int
+
+  public init(
+    capabilities: Set<CoreAgentAppleExecutionCapability>,
+    workspaceRoot: URL,
+    networkPolicy: CoreAgentAppleNetworkPolicy,
+    authorityBoundaryID: String = "default",
+    policyVersion: Int = 1
+  ) {
+    self.capabilities = capabilities
+    self.workspaceRoot = workspaceRoot
+    self.networkPolicy = networkPolicy
+    self.authorityBoundaryID = authorityBoundaryID
+    self.policyVersion = policyVersion
+  }
+
+  public func allows(_ capability: CoreAgentAppleExecutionCapability) -> Bool {
+    capabilities.contains(capability)
+  }
+}
+
+public enum CoreAgentAppleInterpreterTier: String, Codable, Equatable, Sendable {
+  case deterministicInProcess
+  case wasiWebAssembly
+  case helperProcess
+  case remote
+
+  var requiredCapability: CoreAgentAppleExecutionCapability {
+    switch self {
+    case .deterministicInProcess:
+      .deterministicCodeInterpreter
+    case .wasiWebAssembly:
+      .wasiCodeInterpreter
+    case .helperProcess:
+      .helperCodeInterpreter
+    case .remote:
+      .remoteCodeInterpreter
+    }
+  }
+}
+
+public enum CoreAgentAppleExecutionRequest: Equatable, Sendable {
+  case codeInterpreter(tier: CoreAgentAppleInterpreterTier)
+  case computerUse(actionID: String)
+  case swiftDataCheckpointPersistence(checkpointKey: String)
+  case appIntentDonation(descriptor: CoreAgentAppIntentDescriptor)
+  case appIntent(
+    descriptor: CoreAgentAppIntentDescriptor,
+    mode: CoreAgentAppleAppIntentMode,
+    target: CoreAgentAppleAppIntentExecutionTarget
+  )
+}
+
+public struct CoreAgentAppleConsentRequirement:
+  Codable, Equatable, Sendable
+{
+  public let authorityBoundaryID: String
+  public let policyVersion: Int
+  public let capability: CoreAgentAppleExecutionCapability
+  public let requestFingerprint: String
+
+  public init(
+    authorityBoundaryID: String,
+    policyVersion: Int,
+    capability: CoreAgentAppleExecutionCapability,
+    requestFingerprint: String
+  ) {
+    self.authorityBoundaryID = authorityBoundaryID
+    self.policyVersion = policyVersion
+    self.capability = capability
+    self.requestFingerprint = requestFingerprint
+  }
+}
+
+public struct CoreAgentAppleConsentReceipt:
+  Codable, Equatable, Sendable
+{
+  public let id: String
+  public let issuerID: String
+  public let authorityBoundaryID: String
+  public let policyVersion: Int
+  public let capability: CoreAgentAppleExecutionCapability
+  public let requestFingerprint: String
+  public let grantedAt: Date
+  public let expiresAt: Date?
+  public let signature: String
+
+  public init(
+    id: String,
+    issuerID: String,
+    authorityBoundaryID: String,
+    policyVersion: Int,
+    capability: CoreAgentAppleExecutionCapability,
+    requestFingerprint: String,
+    grantedAt: Date,
+    expiresAt: Date? = nil,
+    signature: String
+  ) {
+    self.id = id
+    self.issuerID = issuerID
+    self.authorityBoundaryID = authorityBoundaryID
+    self.policyVersion = policyVersion
+    self.capability = capability
+    self.requestFingerprint = requestFingerprint
+    self.grantedAt = grantedAt
+    self.expiresAt = expiresAt
+    self.signature = signature
+  }
+
+  private init(
+    id: String,
+    issuerID: String,
+    requirement: CoreAgentAppleConsentRequirement,
+    grantedAt: Date,
+    expiresAt: Date? = nil,
+    signature: String
+  ) {
+    self.init(
+      id: id,
+      issuerID: issuerID,
+      authorityBoundaryID: requirement.authorityBoundaryID,
+      policyVersion: requirement.policyVersion,
+      capability: requirement.capability,
+      requestFingerprint: requirement.requestFingerprint,
+      grantedAt: grantedAt,
+      expiresAt: expiresAt,
+      signature: signature
+    )
+  }
+
+  public static func issue(
+    id: String,
+    issuerID: String,
+    requirement: CoreAgentAppleConsentRequirement,
+    signingKey: CoreAgentAppleConsentSigningKey,
+    grantedAt: Date,
+    expiresAt: Date? = nil
+  ) -> CoreAgentAppleConsentReceipt {
+    let unsigned = CoreAgentAppleConsentReceipt(
+      id: id,
+      issuerID: issuerID,
+      requirement: requirement,
+      grantedAt: grantedAt,
+      expiresAt: expiresAt,
+      signature: ""
+    )
+    return CoreAgentAppleConsentReceipt(
+      id: id,
+      issuerID: issuerID,
+      requirement: requirement,
+      grantedAt: grantedAt,
+      expiresAt: expiresAt,
+      signature: unsigned.signature(signingKey: signingKey)
+    )
+  }
+
+  fileprivate func verifies(with signingKey: CoreAgentAppleConsentSigningKey) -> Bool {
+    signature == self.signature(signingKey: signingKey)
+  }
+
+  private func signature(signingKey: CoreAgentAppleConsentSigningKey) -> String {
+    let mac = HMAC<SHA256>.authenticationCode(
+      for: signaturePayload,
+      using: SymmetricKey(data: signingKey.material)
+    )
+    return "hmac-sha256:" + mac.map { String(format: "%02x", $0) }.joined()
+  }
+
+  private var signaturePayload: Data {
+    let fields = [
+      id,
+      issuerID,
+      authorityBoundaryID,
+      String(policyVersion),
+      capability.rawValue,
+      requestFingerprint,
+      Self.timeToken(grantedAt),
+      expiresAt.map(Self.timeToken) ?? "nil",
+    ]
+    return Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
+  }
+
+  private static func timeToken(_ date: Date) -> String {
+    String(date.timeIntervalSinceReferenceDate.bitPattern)
+  }
+}
+
+public struct CoreAgentAppleConsentSigningKey: Equatable, Sendable {
+  fileprivate let material: Data
+
+  public init(_ material: Data) {
+    self.material = material
+  }
+}
+
+public enum CoreAgentAppleConsent: Equatable, Sendable {
+  case notRequired
+  case required(reason: String)
+  case granted(CoreAgentAppleConsentReceipt)
+}
+
+public enum CoreAgentAppleActionGateDenial: Equatable, Sendable {
+  case missingCapability(CoreAgentAppleExecutionCapability)
+  case missingConsent(CoreAgentAppleExecutionCapability)
+  case remoteExecutionRequiresNetworkPolicy
+  case invalidConsentReceipt(String)
+  case consentAuthorityBoundaryMismatch(expected: String, actual: String)
+  case consentPolicyVersionMismatch(expected: Int, actual: Int)
+  case consentCapabilityMismatch(
+    expected: CoreAgentAppleExecutionCapability,
+    actual: CoreAgentAppleExecutionCapability
+  )
+  case consentRequestMismatch(expected: String, actual: String)
+  case expiredConsentReceipt(String)
+  case missingConsentExpiry(String)
+  case untrustedConsentIssuer(expected: String, actual: String)
+  case invalidConsentSignature(String)
+  case consentVerifierUnavailable(CoreAgentAppleExecutionCapability)
+  case invalidAppIntentDescriptor(CoreAgentAppIntentDescriptorError)
+  case unsupportedAppIntentMode(identifier: String, mode: CoreAgentAppleAppIntentMode)
+  case unsupportedAppIntentExecutionTarget(
+    identifier: String,
+    target: CoreAgentAppleAppIntentExecutionTarget
+  )
+  case appIntentDonationDisabled(identifier: String)
+  case appIntentExecutionTargetRequiresForeground(
+    identifier: String,
+    target: CoreAgentAppleAppIntentExecutionTarget
+  )
+}
+
+public enum CoreAgentAppleActionGateDecision: Equatable, Sendable {
+  case allowed
+  case denied(CoreAgentAppleActionGateDenial)
+
+  public var isAllowed: Bool {
+    if case .allowed = self { return true }
+    return false
+  }
+}
+
+public struct CoreAgentAppleActionGate: Sendable {
+  public let sandbox: CoreAgentAppleSandboxProfile
+  public let trustedConsentIssuerID: String
+  private let consentSigningKey: CoreAgentAppleConsentSigningKey?
+  private let now: @Sendable () -> Date
+
+  public init(
+    sandbox: CoreAgentAppleSandboxProfile,
+    trustedConsentIssuerID: String = "default",
+    consentSigningKey: CoreAgentAppleConsentSigningKey? = nil,
+    now: @escaping @Sendable () -> Date = { Date() }
+  ) {
+    self.sandbox = sandbox
+    self.trustedConsentIssuerID = trustedConsentIssuerID
+    self.consentSigningKey = consentSigningKey
+    self.now = now
+  }
+
+  public func consentRequirement(
+    for request: CoreAgentAppleExecutionRequest
+  ) -> CoreAgentAppleConsentRequirement {
+    let policy = policy(for: request)
+    return CoreAgentAppleConsentRequirement(
+      authorityBoundaryID: sandbox.authorityBoundaryID,
+      policyVersion: sandbox.policyVersion,
+      capability: policy.requiredCapability,
+      requestFingerprint: policy.requestFingerprint
+    )
+  }
+
+  public func evaluate(
+    _ request: CoreAgentAppleExecutionRequest,
+    consent: CoreAgentAppleConsent
+  ) -> CoreAgentAppleActionGateDecision {
+    let policy = policy(for: request)
+
+    if let denial = policy.preflightDenial {
+      return .denied(denial)
+    }
+    guard sandbox.allows(policy.requiredCapability) else {
+      return .denied(.missingCapability(policy.requiredCapability))
+    }
+    guard !policy.consentRequired else {
+      let requirement = CoreAgentAppleConsentRequirement(
+        authorityBoundaryID: sandbox.authorityBoundaryID,
+        policyVersion: sandbox.policyVersion,
+        capability: policy.requiredCapability,
+        requestFingerprint: policy.requestFingerprint
+      )
+      if let denial = validate(consent: consent, requirement: requirement) {
+        return .denied(denial)
+      }
+      return .allowed
+    }
+    return .allowed
+  }
+
+  private struct RequestPolicy {
+    let requiredCapability: CoreAgentAppleExecutionCapability
+    let consentRequired: Bool
+    let requestFingerprint: String
+    let preflightDenial: CoreAgentAppleActionGateDenial?
+  }
+
+  private func policy(for request: CoreAgentAppleExecutionRequest) -> RequestPolicy {
+    switch request {
+    case .codeInterpreter(let tier):
+      if tier == .remote && sandbox.networkPolicy != .allowed {
+        return RequestPolicy(
+          requiredCapability: tier.requiredCapability,
+          consentRequired: true,
+          requestFingerprint: fingerprint(["code", tier.rawValue]),
+          preflightDenial: .remoteExecutionRequiresNetworkPolicy
+        )
+      }
+      return RequestPolicy(
+        requiredCapability: tier.requiredCapability,
+        consentRequired: tier == .helperProcess || tier == .remote,
+        requestFingerprint: fingerprint(["code", tier.rawValue]),
+        preflightDenial: nil
+      )
+    case .computerUse(let actionID):
+      return RequestPolicy(
+        requiredCapability: .computerUse,
+        consentRequired: true,
+        requestFingerprint: fingerprint(["computer-use", actionID]),
+        preflightDenial: nil
+      )
+    case .swiftDataCheckpointPersistence(let checkpointKey):
+      return RequestPolicy(
+        requiredCapability: .swiftDataCheckpointPersistence,
+        consentRequired: false,
+        requestFingerprint: fingerprint(["swiftdata-checkpoint", checkpointKey]),
+        preflightDenial: nil
+      )
+    case .appIntentDonation(let descriptor):
+      if let denial = appIntentDonationDenial(descriptor: descriptor) {
+        return RequestPolicy(
+          requiredCapability: .appIntentDonation,
+          consentRequired: true,
+          requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
+          preflightDenial: denial
+        )
+      }
+      return RequestPolicy(
+        requiredCapability: .appIntentDonation,
+        consentRequired: true,
+        requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
+        preflightDenial: nil
+      )
+    case .appIntent(let descriptor, let mode, let target):
+      if let denial = appIntentDenial(descriptor: descriptor, mode: mode, target: target) {
+        return RequestPolicy(
+          requiredCapability: .appIntentExecution,
+          consentRequired: true,
+          requestFingerprint: fingerprint([
+            "app-intent",
+            descriptor.exposureFingerprint,
+            mode.rawValue,
+            target.rawValue,
+          ]),
+          preflightDenial: denial
+        )
+      }
+      return RequestPolicy(
+        requiredCapability: .appIntentExecution,
+        consentRequired: true,
+        requestFingerprint: fingerprint([
+          "app-intent",
+          descriptor.exposureFingerprint,
+          mode.rawValue,
+          target.rawValue,
+        ]),
+        preflightDenial: nil
+      )
+    }
+  }
+
+  private func appIntentDonationDenial(
+    descriptor: CoreAgentAppIntentDescriptor
+  ) -> CoreAgentAppleActionGateDenial? {
+    do {
+      _ = try descriptor.validatedForAgentExposure()
+    } catch let error as CoreAgentAppIntentDescriptorError {
+      return .invalidAppIntentDescriptor(error)
+    } catch {
+      return .invalidConsentReceipt("unexpected App Intent descriptor error")
+    }
+    guard descriptor.donationPolicy != .doNotDonate else {
+      return .appIntentDonationDisabled(identifier: descriptor.identifier)
+    }
+    return nil
+  }
+
+  private func appIntentDenial(
+    descriptor: CoreAgentAppIntentDescriptor,
+    mode: CoreAgentAppleAppIntentMode,
+    target: CoreAgentAppleAppIntentExecutionTarget
+  ) -> CoreAgentAppleActionGateDenial? {
+    do {
+      _ = try descriptor.validatedForAgentExposure()
+    } catch let error as CoreAgentAppIntentDescriptorError {
+      return .invalidAppIntentDescriptor(error)
+    } catch {
+      return .invalidConsentReceipt("unexpected App Intent descriptor error")
+    }
+    guard descriptor.supportedModes.contains(mode) else {
+      return .unsupportedAppIntentMode(identifier: descriptor.identifier, mode: mode)
+    }
+    guard descriptor.allowedExecutionTargets.contains(target) else {
+      return .unsupportedAppIntentExecutionTarget(
+        identifier: descriptor.identifier,
+        target: target
+      )
+    }
+    guard descriptor.mutability == .readOnly || target == .foreground else {
+      return .appIntentExecutionTargetRequiresForeground(
+        identifier: descriptor.identifier,
+        target: target
+      )
+    }
+    return nil
+  }
+
+  private func validate(
+    consent: CoreAgentAppleConsent,
+    requirement: CoreAgentAppleConsentRequirement
+  ) -> CoreAgentAppleActionGateDenial? {
+    guard case .granted(let receipt) = consent else {
+      return .missingConsent(requirement.capability)
+    }
+    guard !receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
+      return .invalidConsentReceipt("empty receipt id")
+    }
+    guard receipt.authorityBoundaryID == requirement.authorityBoundaryID else {
+      return .consentAuthorityBoundaryMismatch(
+        expected: requirement.authorityBoundaryID,
+        actual: receipt.authorityBoundaryID
+      )
+    }
+    guard receipt.policyVersion == requirement.policyVersion else {
+      return .consentPolicyVersionMismatch(
+        expected: requirement.policyVersion,
+        actual: receipt.policyVersion
+      )
+    }
+    guard receipt.capability == requirement.capability else {
+      return .consentCapabilityMismatch(
+        expected: requirement.capability,
+        actual: receipt.capability
+      )
+    }
+    guard receipt.requestFingerprint == requirement.requestFingerprint else {
+      return .consentRequestMismatch(
+        expected: requirement.requestFingerprint,
+        actual: receipt.requestFingerprint
+      )
+    }
+    guard let expiresAt = receipt.expiresAt else {
+      return .missingConsentExpiry(receipt.id)
+    }
+    if expiresAt <= now() {
+      return .expiredConsentReceipt(receipt.id)
+    }
+    guard receipt.issuerID == trustedConsentIssuerID else {
+      return .untrustedConsentIssuer(expected: trustedConsentIssuerID, actual: receipt.issuerID)
+    }
+    guard let consentSigningKey else {
+      return .consentVerifierUnavailable(requirement.capability)
+    }
+    guard receipt.verifies(with: consentSigningKey) else {
+      return .invalidConsentSignature(receipt.id)
+    }
+    return nil
+  }
+
+  private func fingerprint(_ fields: [String]) -> String {
+    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
+  }
+}
+
+public enum CoreAgentAppIntentMutability: String, Codable, Equatable, Sendable {
+  case readOnly
+  case mutating
+  case destructive
+}
+
+public enum CoreAgentAppleAppIntentExecutionTarget: String, Codable, Hashable, Sendable {
+  case foreground
+  case background
+}
+
+public enum CoreAgentAppleAppIntentMode: String, Codable, Hashable, Sendable {
+  case app
+  case siri
+  case shortcuts
+  case spotlight
+}
+
+public enum CoreAgentAppIntentDonationPolicy: String, Codable, Equatable, Sendable {
+  case doNotDonate
+  case donateAfterUserInitiatedAction
+}
+
+public enum CoreAgentAppIntentDescriptorError: Error, Equatable, Sendable {
+  case missingExecutionTarget(identifier: String)
+  case missingSupportedMode(identifier: String)
+  case agentExposureRequired(identifier: String)
+  case authorizationRequired(identifier: String)
+  case hitlRequired(identifier: String)
+  case foregroundExecutionRequired(identifier: String)
+}
+
+public struct CoreAgentAppIntentDescriptor: Equatable, Sendable {
+  public let identifier: String
+  public let title: String
+  public let mutability: CoreAgentAppIntentMutability
+  public let exposureRevision: String
+  public let allowsAgentExecution: Bool
+  public let allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>
+  public let supportedModes: Set<CoreAgentAppleAppIntentMode>
+  public let donationPolicy: CoreAgentAppIntentDonationPolicy
+  public let requiresAuthorization: Bool
+  public let requiresHITLForSensitiveOperations: Bool
+
+  public init(
+    identifier: String,
+    title: String,
+    mutability: CoreAgentAppIntentMutability,
+    exposureRevision: String = "1",
+    allowsAgentExecution: Bool,
+    allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>,
+    supportedModes: Set<CoreAgentAppleAppIntentMode>,
+    donationPolicy: CoreAgentAppIntentDonationPolicy,
+    requiresAuthorization: Bool,
+    requiresHITLForSensitiveOperations: Bool
+  ) {
+    self.identifier = identifier
+    self.title = title
+    self.mutability = mutability
+    self.exposureRevision = exposureRevision
+    self.allowsAgentExecution = allowsAgentExecution
+    self.allowedExecutionTargets = allowedExecutionTargets
+    self.supportedModes = supportedModes
+    self.donationPolicy = donationPolicy
+    self.requiresAuthorization = requiresAuthorization
+    self.requiresHITLForSensitiveOperations = requiresHITLForSensitiveOperations
+  }
+
+  public func validatedForAgentExposure() throws -> Self {
+    guard !allowedExecutionTargets.isEmpty else {
+      throw CoreAgentAppIntentDescriptorError.missingExecutionTarget(identifier: identifier)
+    }
+    guard !supportedModes.isEmpty else {
+      throw CoreAgentAppIntentDescriptorError.missingSupportedMode(identifier: identifier)
+    }
+    guard allowsAgentExecution else {
+      throw CoreAgentAppIntentDescriptorError.agentExposureRequired(identifier: identifier)
+    }
+    guard mutability == .readOnly || requiresAuthorization else {
+      throw CoreAgentAppIntentDescriptorError.authorizationRequired(identifier: identifier)
+    }
+    guard mutability == .readOnly || requiresHITLForSensitiveOperations else {
+      throw CoreAgentAppIntentDescriptorError.hitlRequired(identifier: identifier)
+    }
+    guard mutability == .readOnly || allowedExecutionTargets.contains(.foreground) else {
+      throw CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(identifier: identifier)
+    }
+    return self
+  }
+
+  public var exposureFingerprint: String {
+    Self.fingerprint([
+      identifier,
+      title,
+      mutability.rawValue,
+      exposureRevision,
+      allowsAgentExecution ? "agent-exposed" : "not-agent-exposed",
+      allowedExecutionTargets.map(\.rawValue).sorted().joined(separator: ","),
+      supportedModes.map(\.rawValue).sorted().joined(separator: ","),
+      donationPolicy.rawValue,
+      requiresAuthorization ? "requires-authorization" : "no-authorization",
+      requiresHITLForSensitiveOperations ? "requires-hitl" : "no-hitl",
+    ])
+  }
+
+  private static func fingerprint(_ fields: [String]) -> String {
+    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
+  }
+}
+
+public enum CoreAgentRunProjectionStatus: String, Codable, Equatable, Sendable {
+  case running
+  case completed
+  case failed
+}
+
+public struct CoreAgentRunProjection: Codable, Equatable, Identifiable, Sendable {
+  public var id: UUID { runID }
+
+  public let runID: UUID
+  public let projectID: String
+  public let threadID: String?
+  public let startedAt: Date
+  public let endedAt: Date
+  public let duration: TimeInterval
+  public let status: CoreAgentRunProjectionStatus
+  public let lastEventKind: CoreAgentEventKind?
+  public let eventCounts: [CoreAgentEventKind: Int]
+  public let ingestedAt: Date
+
+  public init(trace: CoreAgentEngineTrace) {
+    self.runID = trace.run.id
+    self.projectID = trace.projectID
+    self.threadID = trace.threadID
+    self.startedAt = trace.run.startedAt
+    self.endedAt = trace.run.endedAt
+    self.duration = trace.run.duration
+    self.status = Self.status(for: trace.run)
+    self.lastEventKind = trace.run.events.last?.kind
+    self.eventCounts = Dictionary(
+      grouping: trace.run.events,
+      by: \.kind
+    ).mapValues(\.count)
+    self.ingestedAt = trace.ingestedAt
+  }
+
+  private static func status(for run: CoreAgentRun) -> CoreAgentRunProjectionStatus {
+    if run.events.contains(where: { $0.kind == .runFailed }) {
+      return .failed
+    }
+    if run.events.contains(where: { $0.kind == .runCompleted }) {
+      return .completed
+    }
+    return .running
+  }
+}
+
+@MainActor
+@Observable
+public final class CoreAgentRunProjectionStore {
+  public private(set) var projections: [CoreAgentRunProjection]
+
+  public init(projections: [CoreAgentRunProjection] = []) {
+    self.projections = projections
+  }
+
+  public func apply(traces: [CoreAgentEngineTrace]) {
+    var projectionsByRunID: [UUID: CoreAgentRunProjection] = [:]
+    for trace in traces {
+      projectionsByRunID[trace.run.id] = CoreAgentRunProjection(trace: trace)
+    }
+    projections = projectionsByRunID.values
+      .sorted { lhs, rhs in
+        if lhs.startedAt != rhs.startedAt {
+          return lhs.startedAt < rhs.startedAt
+        }
+        return lhs.runID.uuidString < rhs.runID.uuidString
+      }
+  }
+}
diff --git a/Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift b/Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift
new file mode 100644
index 0000000..002324f
--- /dev/null
+++ b/Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift
@@ -0,0 +1,745 @@
+import CoreAgent
+import CoreAgentApplePlatform
+import CoreAgentEngine
+import Foundation
+import FoundationModels
+import Testing
+
+@Suite("CoreAgent Apple platform adapters")
+struct CoreAgentApplePlatformTests {
+  @Test("SwiftData checkpoint snapshots preserve canonical bytes and policy metadata")
+  func swiftDataCheckpointSnapshotsPreserveCanonicalBytesAndPolicyMetadata() throws {
+    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))
+    let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
+
+    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointKey: "thread/session",
+      checkpoint: checkpoint,
+      authorityBoundaryID: "user:basit/device:mac",
+      policyVersion: 7,
+      storedAt: storedAt
+    )
+
+    let restored = try snapshot.decodeCheckpoint(
+      expectedAuthorityBoundaryID: "user:basit/device:mac",
+      expectedPolicyVersion: 7
+    )
+
+    #expect(snapshot.checkpointKey == "thread/session")
+    #expect(snapshot.checkpointFormatVersion == CoreAgentCheckpoint.currentFormatVersion)
+    #expect(snapshot.compatibilityRevision == "revision-a")
+    #expect(snapshot.authorityBoundaryID == "user:basit/device:mac")
+    #expect(snapshot.policyVersion == 7)
+    #expect(snapshot.storedAt == storedAt)
+    #expect(snapshot.canonicalCheckpointData.count > 0)
+    #expect(snapshot.checkpointDigest.hasPrefix("sha256:"))
+    #expect(restored.savedAt == checkpoint.savedAt)
+    #expect(restored.compatibilityRevision == checkpoint.compatibilityRevision)
+    #expect(restored.transcript == checkpoint.transcript)
+  }
+
+  @Test("SwiftData checkpoint snapshots preserve subsecond Date precision")
+  func swiftDataCheckpointSnapshotsPreserveSubsecondDatePrecision() throws {
+    let savedAt = Date(timeIntervalSinceReferenceDate: 987_654_321.987654)
+    let checkpoint = Self.checkpoint(savedAt: savedAt)
+    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointKey: "thread/subsecond",
+      checkpoint: checkpoint,
+      authorityBoundaryID: "workspace:coreagent",
+      policyVersion: 1
+    )
+
+    let restored = try snapshot.decodeCheckpoint(
+      expectedAuthorityBoundaryID: "workspace:coreagent",
+      expectedPolicyVersion: 1
+    )
+
+    #expect(restored.savedAt == savedAt)
+  }
+
+  @Test("SwiftData checkpoint snapshots enforce read barriers before decode")
+  func swiftDataCheckpointSnapshotsEnforceReadBarriersBeforeDecode() throws {
+    let snapshot = CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
+      checkpointKey: "thread/session",
+      authorityBoundaryID: "user:other/device:mac",
+      policyVersion: 4,
+      checkpointFormatVersion: CoreAgentCheckpoint.currentFormatVersion,
+      compatibilityRevision: "revision-a",
+      savedAt: Date(timeIntervalSince1970: 1_700_000_000),
+      storedAt: Date(timeIntervalSince1970: 1_800_000_000),
+      canonicalCheckpointData: Data("not-json".utf8),
+      checkpointDigest: "sha256:not-a-real-digest"
+    )
+
+    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.authorityBoundaryMismatch(
+      expected: "user:basit/device:mac",
+      actual: "user:other/device:mac"
+    )) {
+      _ = try snapshot.decodeCheckpoint(
+        expectedAuthorityBoundaryID: "user:basit/device:mac",
+        expectedPolicyVersion: 4
+      )
+    }
+
+    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.policyVersionMismatch(
+      expected: 9,
+      actual: 4
+    )) {
+      _ = try snapshot.decodeCheckpoint(
+        expectedAuthorityBoundaryID: "user:other/device:mac",
+        expectedPolicyVersion: 9
+      )
+    }
+  }
+
+  @Test("SwiftData checkpoint snapshots bind sidecar metadata into the digest")
+  func swiftDataCheckpointSnapshotsBindSidecarMetadataIntoDigest() throws {
+    let original = try CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointKey: "thread/session",
+      checkpoint: Self.checkpoint(),
+      authorityBoundaryID: "workspace:coreagent",
+      policyVersion: 2
+    )
+    let tampered = CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointID: original.checkpointID,
+      checkpointKey: original.checkpointKey,
+      authorityBoundaryID: "workspace:other",
+      policyVersion: original.policyVersion,
+      checkpointFormatVersion: original.checkpointFormatVersion,
+      compatibilityRevision: original.compatibilityRevision,
+      savedAt: original.savedAt,
+      storedAt: original.storedAt,
+      canonicalCheckpointData: original.canonicalCheckpointData,
+      checkpointDigest: original.checkpointDigest
+    )
+
+    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.self) {
+      _ = try tampered.decodeCheckpoint(
+        expectedAuthorityBoundaryID: "workspace:other",
+        expectedPolicyVersion: 2
+      )
+    }
+  }
+
+  @Test("SwiftData checkpoint snapshots reject payload metadata mismatches")
+  func swiftDataCheckpointSnapshotsRejectPayloadMetadataMismatches() throws {
+    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointKey: "thread/session",
+      checkpoint: Self.checkpoint(),
+      authorityBoundaryID: "workspace:coreagent",
+      policyVersion: 2
+    )
+    let formatMismatch = CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointID: snapshot.checkpointID,
+      checkpointKey: snapshot.checkpointKey,
+      authorityBoundaryID: snapshot.authorityBoundaryID,
+      policyVersion: snapshot.policyVersion,
+      checkpointFormatVersion: 999,
+      compatibilityRevision: snapshot.compatibilityRevision,
+      savedAt: snapshot.savedAt,
+      storedAt: snapshot.storedAt,
+      canonicalCheckpointData: snapshot.canonicalCheckpointData,
+      checkpointDigest: "sha256:not-the-envelope-digest"
+    )
+
+    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.self) {
+      _ = try formatMismatch.decodeCheckpoint(
+        expectedAuthorityBoundaryID: "workspace:coreagent",
+        expectedPolicyVersion: 2
+      )
+    }
+  }
+
+  @Test("SwiftData checkpoint records expose indexed metadata without rebuilding canonical data")
+  func swiftDataCheckpointRecordsExposeIndexedMetadataWithoutRebuildingCanonicalData() throws {
+    let checkpoint = Self.checkpoint()
+    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
+      checkpointKey: "thread/session",
+      checkpoint: checkpoint,
+      authorityBoundaryID: "workspace:coreagent",
+      policyVersion: 2,
+      storedAt: Date(timeIntervalSince1970: 1_800_000_000)
+    )
+
+    let record = CoreAgentSwiftDataCheckpointRecord(snapshot: snapshot)
+    let restored = try record.snapshot.decodeCheckpoint(
+      expectedAuthorityBoundaryID: "workspace:coreagent",
+      expectedPolicyVersion: 2
+    )
+
+    #expect(record.checkpointKey == "thread/session")
+    #expect(record.authorityBoundaryID == "workspace:coreagent")
+    #expect(record.policyVersion == 2)
+    #expect(record.checkpointDigest == snapshot.checkpointDigest)
+    #expect(record.encodedCheckpoint == snapshot.canonicalCheckpointData)
+    #expect(restored.transcript == checkpoint.transcript)
+  }
+
+  @Test("Apple action gate separates code sandboxing from computer-use consent")
+  func appleActionGateSeparatesCodeSandboxingFromComputerUseConsent() {
+    let codeSandbox = CoreAgentAppleSandboxProfile(
+      capabilities: [.deterministicCodeInterpreter],
+      workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+      networkPolicy: .denied
+    )
+    let codeGate = CoreAgentAppleActionGate(sandbox: codeSandbox)
+
+    #expect(codeGate.evaluate(
+      .codeInterpreter(tier: .deterministicInProcess),
+      consent: .notRequired
+    ).isAllowed)
+
+    #expect(codeGate.evaluate(
+      .computerUse(actionID: "click-toolbar-save"),
+      consent: .granted(Self.receipt(
+        id: "receipt-1",
+        requirement: CoreAgentAppleConsentRequirement(
+          authorityBoundaryID: "default",
+          policyVersion: 1,
+          capability: .computerUse,
+          requestFingerprint: "computer-use"
+        )
+      ))
+    ) == .denied(.missingCapability(.computerUse)))
+
+    let automationGate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.computerUse],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey
+    )
+
+    #expect(automationGate.evaluate(
+      .computerUse(actionID: "click-toolbar-save"),
+      consent: .notRequired
+    ) == .denied(.missingConsent(.computerUse)))
+    let requirement = automationGate.consentRequirement(
+      for: .computerUse(actionID: "click-toolbar-save")
+    )
+    #expect(automationGate.evaluate(
+      .computerUse(actionID: "click-toolbar-save"),
+      consent: .granted(Self.receipt(id: "receipt-2", requirement: requirement))
+    ).isAllowed)
+  }
+
+  @Test("Action gate rejects reused empty or expired consent receipts")
+  func actionGateRejectsReusedEmptyOrExpiredConsentReceipts() {
+    let now = Date(timeIntervalSince1970: 1_800_000_000)
+    let gate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.computerUse, .remoteCodeInterpreter],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .allowed,
+        authorityBoundaryID: "workspace:coreagent",
+        policyVersion: 3
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey,
+      now: { now }
+    )
+    let request = CoreAgentAppleExecutionRequest.computerUse(actionID: "click-toolbar-save")
+    let requirement = gate.consentRequirement(for: request)
+
+    let wrongCapabilityRequirement = CoreAgentAppleConsentRequirement(
+      authorityBoundaryID: requirement.authorityBoundaryID,
+      policyVersion: requirement.policyVersion,
+      capability: .remoteCodeInterpreter,
+      requestFingerprint: requirement.requestFingerprint
+    )
+    let wrongCapability = Self.receipt(id: "receipt-1", requirement: wrongCapabilityRequirement)
+    #expect(gate.evaluate(request, consent: .granted(wrongCapability)) == .denied(
+      .consentCapabilityMismatch(expected: .computerUse, actual: .remoteCodeInterpreter)
+    ))
+
+    let otherActionRequirement = gate.consentRequirement(
+      for: .computerUse(actionID: "click-toolbar-open")
+    )
+    #expect(gate.evaluate(
+      request,
+      consent: .granted(Self.receipt(id: "receipt-2", requirement: otherActionRequirement))
+    ) == .denied(.consentRequestMismatch(
+      expected: requirement.requestFingerprint,
+      actual: otherActionRequirement.requestFingerprint
+    )))
+
+    #expect(gate.evaluate(
+      request,
+      consent: .granted(Self.receipt(id: " ", requirement: requirement))
+    ) == .denied(.invalidConsentReceipt("empty receipt id")))
+
+    #expect(gate.evaluate(
+      request,
+      consent: .granted(Self.receipt(
+        id: "receipt-3",
+        requirement: requirement,
+        expiresAt: now.addingTimeInterval(-1)
+      ))
+    ) == .denied(.expiredConsentReceipt("receipt-3")))
+
+    let noExpiry = CoreAgentAppleConsentReceipt.issue(
+      id: "receipt-4",
+      issuerID: Self.issuerID,
+      requirement: requirement,
+      signingKey: Self.signingKey,
+      grantedAt: Self.grantedAt,
+      expiresAt: nil
+    )
+    #expect(gate.evaluate(request, consent: .granted(noExpiry)) == .denied(
+      .missingConsentExpiry("receipt-4")
+    ))
+  }
+
+  @Test("Action gate rejects authority policy issuer and signature mismatches")
+  func actionGateRejectsAuthorityPolicyIssuerAndSignatureMismatches() {
+    let gate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.computerUse],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied,
+        authorityBoundaryID: "workspace:coreagent",
+        policyVersion: 5
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey
+    )
+    let request = CoreAgentAppleExecutionRequest.computerUse(actionID: "click-toolbar-save")
+    let requirement = gate.consentRequirement(for: request)
+
+    let wrongAuthority = Self.receipt(
+      id: "receipt-authority",
+      requirement: CoreAgentAppleConsentRequirement(
+        authorityBoundaryID: "workspace:other",
+        policyVersion: requirement.policyVersion,
+        capability: requirement.capability,
+        requestFingerprint: requirement.requestFingerprint
+      )
+    )
+    #expect(gate.evaluate(request, consent: .granted(wrongAuthority)) == .denied(
+      .consentAuthorityBoundaryMismatch(
+        expected: "workspace:coreagent",
+        actual: "workspace:other"
+      )
+    ))
+
+    let wrongPolicy = Self.receipt(
+      id: "receipt-policy",
+      requirement: CoreAgentAppleConsentRequirement(
+        authorityBoundaryID: requirement.authorityBoundaryID,
+        policyVersion: 4,
+        capability: requirement.capability,
+        requestFingerprint: requirement.requestFingerprint
+      )
+    )
+    #expect(gate.evaluate(request, consent: .granted(wrongPolicy)) == .denied(
+      .consentPolicyVersionMismatch(expected: 5, actual: 4)
+    ))
+
+    let wrongIssuer = CoreAgentAppleConsentReceipt.issue(
+      id: "receipt-issuer",
+      issuerID: "other-issuer",
+      requirement: requirement,
+      signingKey: Self.signingKey,
+      grantedAt: Self.grantedAt,
+      expiresAt: Self.grantedAt.addingTimeInterval(300)
+    )
+    #expect(gate.evaluate(request, consent: .granted(wrongIssuer)) == .denied(
+      .untrustedConsentIssuer(expected: Self.issuerID, actual: "other-issuer")
+    ))
+
+    let wrongSignature = CoreAgentAppleConsentReceipt.issue(
+      id: "receipt-signature",
+      issuerID: Self.issuerID,
+      requirement: requirement,
+      signingKey: CoreAgentAppleConsentSigningKey(Data("wrong-key".utf8)),
+      grantedAt: Self.grantedAt,
+      expiresAt: Self.grantedAt.addingTimeInterval(300)
+    )
+    #expect(gate.evaluate(request, consent: .granted(wrongSignature)) == .denied(
+      .invalidConsentSignature("receipt-signature")
+    ))
+  }
+
+  @Test("App Intent descriptors cannot bypass authorization HITL or foreground execution")
+  func appIntentDescriptorsCannotBypassAuthorizationHITLOrForegroundExecution() throws {
+    let descriptor = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Task",
+      mutability: .mutating,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app, .siri],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+
+    #expect(try descriptor.validatedForAgentExposure().identifier == descriptor.identifier)
+
+    let backgroundMutation = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentDeleteTaskIntent",
+      title: "Delete Task",
+      mutability: .mutating,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.background],
+      supportedModes: [.siri],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+    #expect(throws: CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(
+      identifier: "CoreAgentDeleteTaskIntent"
+    )) {
+      _ = try backgroundMutation.validatedForAgentExposure()
+    }
+
+    let missingAuthorization = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Task",
+      mutability: .mutating,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .doNotDonate,
+      requiresAuthorization: false,
+      requiresHITLForSensitiveOperations: true
+    )
+    #expect(throws: CoreAgentAppIntentDescriptorError.authorizationRequired(
+      identifier: "CoreAgentCreateTaskIntent"
+    )) {
+      _ = try missingAuthorization.validatedForAgentExposure()
+    }
+
+    let notExposed = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentHiddenIntent",
+      title: "Hidden",
+      mutability: .readOnly,
+      allowsAgentExecution: false,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .doNotDonate,
+      requiresAuthorization: false,
+      requiresHITLForSensitiveOperations: false
+    )
+    #expect(throws: CoreAgentAppIntentDescriptorError.agentExposureRequired(
+      identifier: "CoreAgentHiddenIntent"
+    )) {
+      _ = try notExposed.validatedForAgentExposure()
+    }
+  }
+
+  @Test("Action gate validates App Intent descriptor mode and execution target")
+  func actionGateValidatesAppIntentDescriptorModeAndExecutionTarget() {
+    let gate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.appIntentExecution],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied,
+        authorityBoundaryID: "workspace:coreagent",
+        policyVersion: 11
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey
+    )
+    let descriptor = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Task",
+      mutability: .mutating,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground, .background],
+      supportedModes: [.app],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+    let foregroundRequest = CoreAgentAppleExecutionRequest.appIntent(
+      descriptor: descriptor,
+      mode: .app,
+      target: .foreground
+    )
+    let foregroundRequirement = gate.consentRequirement(for: foregroundRequest)
+
+    #expect(gate.evaluate(
+      foregroundRequest,
+      consent: .granted(Self.receipt(id: "intent-receipt-1", requirement: foregroundRequirement))
+    ).isAllowed)
+
+    let backgroundRequest = CoreAgentAppleExecutionRequest.appIntent(
+      descriptor: descriptor,
+      mode: .app,
+      target: .background
+    )
+    #expect(gate.evaluate(
+      backgroundRequest,
+      consent: .granted(Self.receipt(
+        id: "intent-receipt-2",
+        requirement: gate.consentRequirement(for: backgroundRequest)
+      ))
+    ) == .denied(.appIntentExecutionTargetRequiresForeground(
+      identifier: "CoreAgentCreateTaskIntent",
+      target: .background
+    )))
+
+    let unsupportedModeRequest = CoreAgentAppleExecutionRequest.appIntent(
+      descriptor: descriptor,
+      mode: .siri,
+      target: .foreground
+    )
+    #expect(gate.evaluate(
+      unsupportedModeRequest,
+      consent: .granted(Self.receipt(
+        id: "intent-receipt-3",
+        requirement: gate.consentRequirement(for: unsupportedModeRequest)
+      ))
+    ) == .denied(.unsupportedAppIntentMode(
+      identifier: "CoreAgentCreateTaskIntent",
+      mode: .siri
+    )))
+  }
+
+  @Test("Action gate rejects remote code when network policy is not allowed")
+  func actionGateRejectsRemoteCodeWhenNetworkPolicyIsNotAllowed() {
+    let gate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.remoteCodeInterpreter],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .localOnly
+      )
+    )
+
+    #expect(gate.evaluate(
+      .codeInterpreter(tier: .remote),
+      consent: .notRequired
+    ) == .denied(.remoteExecutionRequiresNetworkPolicy))
+  }
+
+  @Test("Action gate binds App Intent receipts to descriptor exposure")
+  func actionGateBindsAppIntentReceiptsToDescriptorExposure() {
+    let gate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.appIntentExecution],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied,
+        authorityBoundaryID: "workspace:coreagent",
+        policyVersion: 11
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey
+    )
+    let original = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Task",
+      mutability: .mutating,
+      exposureRevision: "1",
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+    let changed = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Priority Task",
+      mutability: .mutating,
+      exposureRevision: "2",
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+    let originalRequest = CoreAgentAppleExecutionRequest.appIntent(
+      descriptor: original,
+      mode: .app,
+      target: .foreground
+    )
+    let changedRequest = CoreAgentAppleExecutionRequest.appIntent(
+      descriptor: changed,
+      mode: .app,
+      target: .foreground
+    )
+    let originalRequirement = gate.consentRequirement(for: originalRequest)
+
+    #expect(gate.evaluate(
+      changedRequest,
+      consent: .granted(Self.receipt(id: "intent-replay", requirement: originalRequirement))
+    ) == .denied(.consentRequestMismatch(
+      expected: gate.consentRequirement(for: changedRequest).requestFingerprint,
+      actual: originalRequirement.requestFingerprint
+    )))
+  }
+
+  @Test("Action gate enforces checkpoint persistence and App Intent donation capabilities")
+  func actionGateEnforcesCheckpointPersistenceAndAppIntentDonationCapabilities() {
+    let deniedGate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied
+      )
+    )
+
+    #expect(deniedGate.evaluate(
+      .swiftDataCheckpointPersistence(checkpointKey: "thread/session"),
+      consent: .notRequired
+    ) == .denied(.missingCapability(.swiftDataCheckpointPersistence)))
+    let donationDescriptor = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentCreateTaskIntent",
+      title: "Create Task",
+      mutability: .mutating,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .donateAfterUserInitiatedAction,
+      requiresAuthorization: true,
+      requiresHITLForSensitiveOperations: true
+    )
+    #expect(deniedGate.evaluate(
+      .appIntentDonation(descriptor: donationDescriptor),
+      consent: .notRequired
+    ) == .denied(.missingCapability(.appIntentDonation)))
+
+    let allowedGate = CoreAgentAppleActionGate(
+      sandbox: CoreAgentAppleSandboxProfile(
+        capabilities: [.swiftDataCheckpointPersistence, .appIntentDonation],
+        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
+        networkPolicy: .denied,
+        authorityBoundaryID: "workspace:coreagent",
+        policyVersion: 1
+      ),
+      trustedConsentIssuerID: Self.issuerID,
+      consentSigningKey: Self.signingKey
+    )
+    let donationRequest = CoreAgentAppleExecutionRequest.appIntentDonation(
+      descriptor: donationDescriptor
+    )
+    #expect(allowedGate.evaluate(
+      .swiftDataCheckpointPersistence(checkpointKey: "thread/session"),
+      consent: .notRequired
+    ).isAllowed)
+    #expect(allowedGate.evaluate(
+      donationRequest,
+      consent: .granted(Self.receipt(
+        id: "donation-receipt",
+        requirement: allowedGate.consentRequirement(for: donationRequest)
+      ))
+    ).isAllowed)
+
+    let disabledDonation = CoreAgentAppIntentDescriptor(
+      identifier: "CoreAgentReadTaskIntent",
+      title: "Read Task",
+      mutability: .readOnly,
+      allowsAgentExecution: true,
+      allowedExecutionTargets: [.foreground],
+      supportedModes: [.app],
+      donationPolicy: .doNotDonate,
+      requiresAuthorization: false,
+      requiresHITLForSensitiveOperations: false
+    )
+    #expect(allowedGate.evaluate(
+      .appIntentDonation(descriptor: disabledDonation),
+      consent: .granted(Self.receipt(
+        id: "disabled-donation-receipt",
+        requirement: allowedGate.consentRequirement(
+          for: .appIntentDonation(descriptor: disabledDonation)
+        )
+      ))
+    ) == .denied(.appIntentDonationDisabled(identifier: "CoreAgentReadTaskIntent")))
+  }
+
+  @MainActor
+  @Test("SwiftUI projection store summarizes run state without raw event payloads")
+  func swiftUIProjectionStoreSummarizesRunStateWithoutRawEventPayloads() throws {
+    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
+    let run = CoreAgentRun(
+      id: runID,
+      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
+      endedAt: Date(timeIntervalSince1970: 1_800_000_003),
+      usage: nil,
+      events: [
+        Self.event(runID: runID, kind: .runStarted, message: "contains token=secret"),
+        Self.event(
+          runID: runID,
+          kind: .runFailed,
+          message: "failed with token=secret",
+          attributes: ["api_key": "secret", "tool": "write_file"]
+        ),
+      ]
+    )
+    let trace = try CoreAgentEngineTrace(
+      projectID: "coreagent",
+      threadID: "thread-a",
+      run: run,
+      receipt: CoreAgentRunReceipt(run: run),
+      ingestedAt: Date(timeIntervalSince1970: 1_800_000_004)
+    )
+
+    let store = CoreAgentRunProjectionStore()
+    store.apply(traces: [trace, trace])
+    let projection = try #require(store.projections.first)
+
+    #expect(store.projections.count == 1)
+    #expect(projection.runID == runID)
+    #expect(projection.projectID == "coreagent")
+    #expect(projection.threadID == "thread-a")
+    #expect(projection.status == .failed)
+    #expect(projection.lastEventKind == .runFailed)
+    #expect(projection.eventCounts[.runStarted] == 1)
+    #expect(projection.eventCounts[.runFailed] == 1)
+    #expect(projection.duration == 3)
+  }
+
+  private static func checkpoint(
+    savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
+  ) -> CoreAgentCheckpoint {
+    CoreAgentCheckpoint(
+      savedAt: savedAt,
+      compatibilityRevision: "revision-a",
+      transcript: Transcript(entries: [
+        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
+      ])
+    )
+  }
+
+  private static func event(
+    runID: UUID,
+    kind: CoreAgentEventKind,
+    message: String,
+    attributes: [String: String] = [:]
+  ) -> CoreAgentEvent {
+    CoreAgentEvent(
+      id: UUID(),
+      runID: runID,
+      timestamp: Date(timeIntervalSince1970: 1_800_000_000),
+      kind: kind,
+      message: message,
+      attributes: attributes
+    )
+  }
+
+  private static func receipt(
+    id: String,
+    requirement: CoreAgentAppleConsentRequirement,
+    expiresAt: Date? = nil
+  ) -> CoreAgentAppleConsentReceipt {
+    CoreAgentAppleConsentReceipt.issue(
+      id: id,
+      issuerID: Self.issuerID,
+      requirement: requirement,
+      signingKey: Self.signingKey,
+      grantedAt: Self.grantedAt,
+      expiresAt: expiresAt ?? Self.grantedAt.addingTimeInterval(300)
+    )
+  }
+
+  private static let issuerID = "coreagent.test.consent"
+  private static let signingKey = CoreAgentAppleConsentSigningKey(
+    Data("coreagent-apple-platform-test-signing-key".utf8)
+  )
+  private static let grantedAt = Date(timeIntervalSince1970: 1_799_999_990)
+}
diff --git a/Documentation/CoreAgentApplePlatform-Runtime.md b/Documentation/CoreAgentApplePlatform-Runtime.md
new file mode 100644
index 0000000..a8b689e
--- /dev/null
+++ b/Documentation/CoreAgentApplePlatform-Runtime.md
@@ -0,0 +1,108 @@
+# CoreAgentApplePlatform Runtime
+
+Date: 2026-07-06
+Status: Apple adapter contract foundation
+
+`CoreAgentApplePlatform` is the optional Apple-only adapter target for platform
+integration points that should not leak into the portable CoreAgent products.
+This slice defines tested contracts for SwiftData checkpoint wrapping, platform
+capability gating, App Intent exposure policy, and SwiftUI/Observation run
+projections. It is not a full sandbox backend, live SwiftData store, or App
+Intents bundle.
+
+## Implemented
+
+- `CoreAgentSwiftDataCheckpointSnapshot`
+  - Encodes a canonical `CoreAgentCheckpoint` as CoreAgent-owned JSON bytes.
+    Dates use lossless `Date` coding rather than the default ISO-8601 strategy
+    so sub-second checkpoint timestamps round trip exactly.
+  - Stores indexed metadata beside those bytes: checkpoint key, checkpoint ID,
+    authority boundary, policy version, checkpoint format, compatibility
+    revision, save time, store time, and SHA-256 digest.
+  - Binds the checkpoint key, authority boundary, policy version, format,
+    compatibility revision, save time, and canonical checkpoint bytes into the
+    digest so SwiftData sidecar metadata cannot be replayed across authority
+    boundaries without detection.
+  - Enforces authority-boundary and policy-version read barriers before digest
+    verification and checkpoint decode.
+  - Verifies decoded checkpoint format and compatibility metadata against the
+    indexed record metadata.
+
+- `CoreAgentSwiftDataCheckpointRecord`
+  - SwiftData `@Model` wrapper around the snapshot fields.
+  - Keeps the encoded checkpoint bytes as the canonical payload. SwiftData row
+    fields are indexes/readback metadata, not the checkpoint schema.
+
+- `CoreAgentAppleSandboxProfile` and `CoreAgentAppleActionGate`
+  - Capability-scoped policy vocabulary for deterministic/WASI/helper/remote
+    code interpreters, computer use, App Intent execution/donation, and
+    SwiftData checkpoint persistence.
+  - Keeps code interpreter authority separate from computer-use consent.
+  - Requires scoped consent receipts for computer-use/App Intent actions and
+    higher-risk helper/remote interpreter tiers. A receipt must match the
+    sandbox authority boundary, policy version, required capability, request
+    fingerprint, non-nil expiry, trusted issuer, and HMAC signature.
+  - Rejects remote interpreter requests unless the sandbox network policy
+    explicitly allows network execution.
+  - Enforces SwiftData checkpoint persistence and App Intent donation as
+    separate gateable capabilities instead of passive vocabulary.
+  - Donation requests carry the App Intent descriptor and are denied when the
+    descriptor's donation policy is `doNotDonate`.
+
+- `CoreAgentAppIntentDescriptor`
+  - App Intent exposure policy descriptor for stable workflow/entity actions.
+  - Requires the host to mark a descriptor as agent-exposed before it can pass
+    validation for agent execution.
+  - Rejects mutating/destructive intents unless authorization and HITL are
+    required and foreground execution is allowed.
+  - Captures supported modes, execution targets, and donation policy as typed
+    metadata that concrete App Intent wrappers can map to OS APIs.
+  - App Intent execution requests pass the descriptor plus the current mode and
+    execution target through `CoreAgentAppleActionGate`; descriptor validation
+    alone is not treated as execution authority.
+  - Consent request fingerprints include a descriptor exposure fingerprint over
+    identifier, title, mutability, explicit agent exposure, exposure revision,
+    supported modes, allowed targets, donation policy, and authorization/HITL
+    requirements, so old
+    receipts cannot be replayed after security-relevant descriptor changes.
+
+- `CoreAgentRunProjectionStore`
+  - Main-actor `@Observable` projection store for SwiftUI apps.
+  - Produces narrow `CoreAgentRunProjection` values from `CoreAgentEngineTrace`.
+  - Deduplicates projections by run ID when a trace batch contains repeated
+    runs.
+  - Exposes run ID, project/thread IDs, timing, status, last event kind, and
+    event counts.
+  - Deliberately omits raw event messages, attributes, receipts, transcripts,
+    and trace blobs from view state.
+
+## Explicit Non-Goals For This Slice
+
+- No live `ModelContext`-backed `CoreAgentCheckpointStore` conformance yet.
+- No SwiftData graph checkpointer/store or Engine trace store yet.
+- No JavaScriptCore, WASI, helper-process, shell, remote, or computer-use
+  executor implementation yet.
+- No concrete `AppIntent` structs, `AppIntentsTesting` integration target, or
+  donation invalidation implementation yet.
+- No SwiftUI views. This target provides the observable projection model that
+  app UI can consume.
+
+These should build on the tested contracts here rather than inventing separate
+authority, checkpoint, projection, or App Intent exposure shapes.
+
+## Verification
+
+- `swift test --skip-update --filter CoreAgentApplePlatformTests` first failed
+  on missing Apple adapter API, then passed 15 focused tests after
+  implementation and hardening.
+- A delegated Swift/iOS review found two valid authority gaps: generic consent
+  receipts and descriptor-detached App Intent execution. Both were fixed with
+  regressions.
+- VibeProxy review found valid hardening gaps around lossless checkpoint date
+  coding, descriptor-bound App Intent consent, direct test-target dependencies,
+  and gateable checkpoint/donation capabilities. Those were fixed with focused
+  regressions.
+- Follow-up VibeProxy review found two more valid contract gaps: checkpoint
+  sidecar metadata was not digest-bound, and App Intent donation was
+  descriptor-detached. Those were fixed with envelope digests and
+  descriptor-bound donation requests.
```
