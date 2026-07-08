```json
{
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "2095–2113",
      "title": "App Intent descriptor validation not enforced in donation flow",
      "description": "appIntentDonationDenial() validates descriptor exposure but the denial is only returned as preflightDenial in RequestPolicy. However, the consent validation path in evaluate() may bypass this check if consent is marked .notRequired or if an attacker provides .granted consent without triggering the preflight denial. The descriptor validation should happen before any consent check, not conditional on preflightDenial being set.",
      "evidence": "In policy() switch case .appIntentDonation, appIntentDonationDenial() is called and stored as preflightDenial. In evaluate(), the check `if let denial = policy.preflightDenial { return .denied(denial) }` runs early, but if an intermediate state allows consent.notRequired to be passed, the descriptor exposure validation is skipped. The validatedForAgentExposure() call inside appIntentDonationDenial() is the only enforcement point.",
      "concrete_fix": "Move descriptor validation out of preflightDenial and into a separate mandatory validation step in evaluate() that runs before any consent negotiation. Ensure appIntentDonationDenial() and appIntentDenial() validation happens regardless of consent state:\n```swift\npublic func evaluate(\n  _ request: CoreAgentAppleExecutionRequest,\n  consent: CoreAgentAppleConsent\n) -> CoreAgentAppleActionGateDecision {\n  // Mandatory descriptor validation before any gate decision\n  if case .appIntentDonation(let descriptor) = request {\n    do {\n      _ = try descriptor.validatedForAgentExposure()\n    } catch let error as CoreAgentAppIntentDescriptorError {\n      return .denied(.invalidAppIntentDescriptor(error))\n    } catch {\n      return .denied(.unexpectedAppIntentDescriptorError(String(describing: error)))\n    }\n  }\n  // ... rest of evaluate()\n}\n```"
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "2142–2160",
      "title": "Mutable App Intent background execution enforcement relies on runtime descriptor state, not schema",
      "description": "The check `descriptor.mutability == .readOnly || target == .foreground` enforces that mutable intents cannot run in background. However, this is a runtime check on descriptor state, not a schema-level or manifest-level constraint. A compromised or modified descriptor passed at runtime could flip mutability or target, and the descriptor itself might be serialized/deserialized without integrity verification. No signature or hash-based proof that the descriptor matches what was registered.",
      "evidence": "appIntentDenial() reads descriptor.mutability and descriptor.allowedExecutionTargets at runtime without any integrity proof. The CoreAgentAppIntentDescriptor is Codable and Equatable but has no embedded signature or tamper-evidence. A malicious caller could construct a descriptor with mutability=.readOnly even if the true registered intent is mutating.",
      "concrete_fix": "Bind App Intent descriptor identity to a manifest hash or certificate embedded in the sandbox profile or consent receipt. Validate that the descriptor hash matches a trusted registry before accepting mutability constraints:\n```swift\nprivate struct TrustedAppIntentManifest {\n  let identifier: String\n  let descriptorHash: String // SHA256 of canonical descriptor JSON\n  let mutability: CoreAgentAppIntentMutability\n}\n\nprivate func validateAppIntentIntegrity(\n  descriptor: CoreAgentAppIntentDescriptor\n) -> CoreAgentAppleActionGateDenial? {\n  let computedHash = sha256(JSONEncoder().encode(descriptor))\n  guard let manifest = trustedManifest[descriptor.identifier] else {\n    return .invalidAppIntentDescriptor(.agentExposureRequired(identifier: descriptor.identifier))\n  }\n  guard manifest.descriptorHash == computedHash else {\n    return .invalidAppIntentDescriptor(.tamperedDescriptor(identifier: descriptor.identifier))\n  }\n  return nil\n}\n```"
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "1655–1675",
      "title": "Time encoding in consent signature payload uses custom format without versioning",
      "description": "stableTimeToken() converts Date to nanosecond Int64 string. The timeToken() function in signaturePayload hardcodes this format with no versioning. If the time encoding function changes (e.g., to milliseconds or to ISO8601), old receipts will silently fail verification with no clear error. No migration path or version tag in the signature payload itself.",
      "evidence": "signaturePayload builds a pipe-delimited string with timeToken(grantedAt) and expiresAt.map(Self.timeToken), but timeToken() is a private function with no version marker. If stableTimeToken() implementation changes, all prior receipts become invalid without alerting the system.",
      "concrete_fix": "Add a time encoding version tag to the signature payload and validate it during verification:\n```swift\nprivate var signaturePayload: Data {\n  let fields = [\n    id,\n    issuerID,\n    authorityBoundaryID,\n    String(policyVersion),\n    capability.rawValue,\n    requestFingerprint,\n    \"v1:ns-int64\",  // time encoding version\n    Self.timeToken(grantedAt),\n    expiresAt.map(Self.timeToken) ?? \"nil\",\n  ]\n  return Data(fields.map { \"\\($0.utf8.count):\\($0)\" }.joined(separator: \"|\").utf8)\n}\n\nfileprivate func verifies(with signingKey: CoreAgentAppleConsentSigningKey) -> Bool {\n  guard let authenticationCode = Self.authenticationCode(from: signature) else {\n    return false\n  }\n  // Re-compute payload to validate time encoding version\n  let expectedPayload = signaturePayload\n  return HMAC<SHA256>.isValidAuthenticationCode(...)\n}\n```"
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "2230–2235",
      "title": "Deterministic instruction set has no bounds on variable/input name length",
      "description": "CoreAgentAppleDeterministicInstruction.set(), .add(), .concatenate(), and .output() accept String names with no length limit. Fingerprint() uses a length-prefixed encoding, but the encoding itself could overflow or create collision vulnerabilities if names are very long or contain pipe characters. No validation that variable names are alphanumeric or safe.",
      "evidence": "case set(String, CoreAgentAppleCodeValue) accepts arbitrary String. fingerprint() uses \"\\($0.utf8.count):\\($0)\" which is safe from injection in isolation, but if a variable name contains NUL or very large UTF-8 sequences, it could cause memory pressure or parser confusion in downstream audit systems.",
      "concrete_fix": "Validate instruction operand names at request time:\n```swift\npublic func run(\n  _ request: CoreAgentAppleDeterministicCodeRequest\n) async -> CoreAgentAppleCodeInterpreterResult {\n  // Validate all variable and output names\n  for instruction in request.program.instructions {\n    switch instruction {\n    case .set(let name, _), .add(let name, _, _), .concatenate(let name, _), .output(let name, _):\n      if !isValidVariableName(name) {\n        return result(\n          request: request,\n          startedAt: startedAt,\n          programDigest: programDigest,\n          inputDigest: inputDigest,\n          status: .failed(.invalidOutputName(name)),\n          stdout: \"\",\n          stderr: \"\",\n          outputs: [:]\n        )\n      }\n    case .emit(_):\n      break\n    }\n  }\n  // ... continue\n}\n\nprivate func isValidVariableName(_ name: String) -> Bool {\n  !name.isEmpty && name.count <= 256 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == \"_\" }\n}\n```"
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "2335–2400",
      "title": "Deterministic interpreter output name validation only rejects path-like names, not unsafe characters",
      "description": "The interpreter rejects path-shaped names (../secret) but does not validate output names against variable name restrictions. An output name like \"var-with-dashes\" or \"\\n\" or \"pipe|char\" could be set but would create audit inconsistencies or injection into logging/serialization.",
      "evidence": "In the run() loop, .output(name, operand) is processed but name validation only happens at the output emission point. The test \"deterministicCodeInterpreterRejectsPathShapedOutputNames\" checks for ../ but not for other unsafe characters.",
      "concrete_fix": "Reuse the isValidVariableName() check (from P2 fix above) for all output names:\n```swift\ncase .output(let name, let operand):\n  guard isValidVariableName(name) else {\n    return failed(\n      .invalidOutputName(name),\n      request: request,\n      startedAt: startedAt,\n      programDigest: programDigest,\n      inputDigest: inputDigest,\n      stdout: stdout,\n      outputs: outputs\n    )\n  }\n  guard let value = resolve(operand, variables: variables, request: request) else {\n    return failed(\n      .typeMismatch(operation: \"output\"),\n      request: request,\n      startedAt: startedAt,\n      programDigest: programDigest,\n      inputDigest: inputDigest,\n      stdout: stdout,\n      outputs: outputs\n    )\n  }\n  guard outputs[name] == nil else {\n    return failed(\n      .invalidOutputName(\"duplicate: \\(name)\"),\n      request: request,\n      startedAt: startedAt,\n      programDigest: programDigest,\n      inputDigest: inputDigest,\n      stdout: stdout,\n      outputs: outputs\n    )\n  }\n  outputs[name] = value\n```"
    },
    {
      "severity": "P3",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "2548–2565",
      "title": "Audit record does not capture consent receipt ID or failure reason",
      "description": "CoreAgentAppleCodeInterpreterAudit records status (succeeded, denied, failed) but does not include the consent receipt ID that granted execution, the specific denial reason, or the failure fingerprint. Auditors cannot trace which receipt authorized a denied request or correlate failures back to program changes.",
      "evidence": "CoreAgentAppleCodeInterpreterAudit has requestID, tier, authorityBoundaryID, policyVersion, workspaceRoot, networkPolicy, startedAt, endedAt, programDigest, inputDigest, and status. It does not have receiptID, denialReason, or failureContext. Status is an enum but provides no audit-scoped identifier.",
      "concrete_fix": "Extend the audit record to include receipt and failure context:\n```swift\npublic struct CoreAgentAppleCodeInterpreterAudit: Equatable, Sendable {\n  public let requestID: String\n  public let tier: CoreAgentAppleInterpreterTier\n  public let authorityBoundaryID: String\n  public let policyVersion: Int\n  public let workspaceRoot: URL\n  public let networkPolicy: CoreAgentAppleNetworkPolicy\n  public let startedAt: Date\n  public let endedAt: Date\n  public let programDigest: String\n  public let inputDigest: String\n  public let status: CoreAgentAppleCodeInterpreterStatus\n  public let consentReceiptID: String?  // Receipt ID that granted execution\n  public let denialReason: String?        // Human-readable denial reason\n  public let outputDigest: String         // SHA256 of outputs dict\n}\n```"
    },
    {
      "severity": "P3",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": "1955–1975",
      "title": "ActionGate does not validate that policyVersion and authorityBoundaryID are stable across interpreter lifetime",
      "description": "CoreAgentAppleActionGate stores sandbox profile at construction time. If the sandbox is mutated between gate construction and request evaluation, or if multiple requests are evaluated with different policy versions, there is no assertion that the authority/version are consistent. The interpreter could run under policy v1 but audit records show v7.",
      "evidence": "ActionGate.sandbox is stored immutably, but the interpreter calls actionGate.evaluate() on each run() with a fresh gateDecision. If actionGate.sandbox were replaced between runs (which shouldn't happen but is not structurally prevented), audit records could be inconsistent.",
      "concrete_fix": "Bind the authority and policy version to the interpreter at construction and assert they match during audit recording:\n```swift\npublic struct CoreAgentAppleD