{
  "findings": [
    {
      "severity": "high",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 342,
      "title": "Lack of Plan Binding in Consent Receipt Allows Plan Substitution Attacks",
      "description": "The consent requirement fingerprint for computer use only includes the actionID (e.g., fingerprint([\"computer-use\", actionID])). It does not bind the specific plan steps or a hash of the generated plan. Because the plan is retrieved from the backend asynchronously after consent validation, a compromised or dynamic backend could display a benign plan during a dry-run to obtain user consent, but return a different, malicious plan during the execution phase, which would still be executed because the consent validation only checks the actionID.",
      "concrete_fix": "Modify CoreAgentAppleExecutionRequest.computerUse to accept a plan digest: `case computerUse(actionID: String, planDigest: String)`. Ensure that the plan digest is computed and validated against the signed consent receipt before executing the steps in the CoreAgentAppleComputerUseExecutor."
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 103,
      "title": "Compiler Error in Signature Verification Due to Array Type Mismatch",
      "description": "HMAC<SHA256>.isValidAuthenticationCode expects a type conforming to DataProtocol for the authentication code parameter. However, authenticationCode(from:) returns [UInt8]?, which does not conform to DataProtocol, causing a compile-time failure.",
      "concrete_fix": "Wrap the returned bytes in a Data object before verifying: \n\n```swift\nfileprivate func verifies(with signingKey: CoreAgentAppleConsentSigningKey) -> Bool {\n  guard let authenticationCode = Self.authenticationCode(from: signature) else {\n    return false\n  }\n  return HMAC<SHA256>.isValidAuthenticationCode(\n    Data(authenticationCode),\n    authenticating: signaturePayload,\n    using: SymmetricKey(data: signingKey.material)\n  )\n}\n```"
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 155,
      "title": "Undefined Helper Functions stableTimeToken and sha256Hex Cause Compilation Failure",
      "description": "The helper functions stableTimeToken and sha256Hex are invoked to serialize date timestamps and serialize object digests but are not defined in the source code.",
      "concrete_fix": "Define these helper functions using ISO8601 formatting for dates to ensure stable serialization across locales, and standard CryptoKit hashing for SHA256 hex conversions:\n\n```swift\nprivate static func stableTimeToken(_ date: Date) -> String {\n  let formatter = ISO8601DateFormatter()\n  formatter.timeZone = TimeZone(secondsFromGMT: 0)\n  return formatter.string(from: date)\n}\n\nprivate static func sha256Hex(_ data: Data) -> String {\n  let digest = SHA256.hash(data: data)\n  return digest.map { String(format: \"%02x\", $0) }.joined()\n}\n```"
    },
    {
      "severity": "low",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 756,
      "title": "Unicode isNumber Checks Allow Invalid Hexadecimal Characters in SHA-256 Validation",
      "description": "The isSHA256Digest helper validates hex digits using Character.isNumber. In Swift, Character.isNumber matches non-ASCII numeric symbols, including fractions, superscript digits, and Roman numerals. This allows malformed digests containing non-hex characters to bypass the pattern check.",
      "concrete_fix": "Restrict the validation to standard ASCII hexadecimal characters:\n\n```swift\nprivate static func isSHA256Digest(_ digest: String) -> Bool {\n  let prefix = \"sha256:\"\n  guard digest.hasPrefix(prefix), digest.count == prefix.count + 64 else {\n    return false\n  }\n  return digest.dropFirst(prefix.count).allSatisfy { character in\n    (\"0\"...\"9\").contains(character) || (\"a\"...\"f\").contains(character) || (\"A\"...\"F\").contains(character)\n  }\n}\n```"
    },
    {
      "severity": "low",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 183,
      "title": "Unbounded Growth of Consumed Receipt Cache Causes Memory Leak",
      "description": "Consumed consent receipt keys are stored indefinitely in the in-memory Set within CoreAgentAppleConsumedConsentReceipts. In a long-running process, this will cause unbounded memory growth over time.",
      "concrete_fix": "Store the expiration date alongside the receipt key and purge expired entries whenever a new receipt is checked or periodically:\n\n```swift\nprivate final class CoreAgentAppleConsumedConsentReceipts: @unchecked Sendable {\n  private let lock = NSLock()\n  private var consumedReceipts: [String: Date] = [:]\n\n  func consume(_ key: String, expiresAt: Date) -> Bool {\n    lock.withLock {\n      let now = Date()\n      // Clean up expired receipts\n      consumedReceipts = consumedReceipts.filter { $0.value > now }\n      if consumedReceipts[key] != nil {\n        return false\n      }\n      consumedReceipts[key] = expiresAt\n      return true\n    }\n  }\n}\n```"
    }
  ],
  "residual_risks": [
    "Replay protection is currently stateful and stored in-memory. If the agent executor process restarts, the history of consumed consent receipts is lost, allowing receipts to be replayed within their remaining validity window.",
    "Lack of absolute clock-skew tolerance. There is no grace period configured for `grantedAt` validation, which may result in legitimate receipts being rejected if the client and executor clocks are slightly out of sync.",
    "The sandbox checks only enforce policy boundaries at the application level; they do not configure or guarantee OS-level sandbox enforcement (e.g., App Sandbox or MAC policies)."
  ],
  "testing_gaps": [
    {
      "title": "Plan Substitution Attack Integration Test",
      "description": "Verify that if the plan steps are modified between the dry-run and execution phases, the system detects the discrepancy and rejects execution."
    },
    {
      "title": "Consent Replay Prevention Test",
      "description": "Test that using the exact same consent receipt multiple times within its validity window fails with the `.reusedConsentReceipt` error."
    },
    {
      "title": "Digest Character Validation Test",
      "description": "Test that digests containing invalid non-ASCII numbers (e.g., superscript digits or Roman numerals) fail the SHA-256 digest validation check."
    }
  ]
}