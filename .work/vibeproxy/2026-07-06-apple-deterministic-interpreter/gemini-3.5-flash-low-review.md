{
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1988,
      "title": "Action Gate Statelessness Allows Consent Receipt Replay Attacks",
      "description": "CoreAgentAppleActionGate is completely stateless and lacks a replay cache or tracking mechanism for spent/consumed receipt IDs (receipt.id). An agent or attacker can reuse a single granted consent receipt multiple times for unauthorized duplicate actions until the receipt reaches its expiration window (expiresAt).",
      "evidence": "In evaluate(_:consent:), the gate validates the receipt using validate(consent:requirement:) but does not record the receipt ID or check it against a list of already-consumed receipt identifiers.",
      "concrete_fix": "Introduce a stateful consent tracking store or delegate (backed by SwiftData or Keychain) to record consumed receipt IDs, and reject evaluations presenting a receipt ID that has already been marked as spent."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 2210,
      "title": "Lack of Minimum Key Size Enforcement on Consent Signing Key",
      "description": "The initializer for CoreAgentAppleConsentSigningKey accepts arbitrary Data without verifying its length. If a developer configures the gate with a weak or empty key, the HMAC-SHA256 signature verification will succeed with low entropy, exposing the action-gate to signature forgery.",
      "evidence": "public init(_ material: Data) { self.material = material } does not perform any size validation on the key data.",
      "concrete_fix": "Enforce a minimum length of 32 bytes (256 bits) for the signing key in the initializer, returning nil or throwing an error if the requirement is not met."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 2325,
      "title": "In-Memory Only Audit Records Bypassed by Untrusted Caller",
      "description": "CoreAgentAppleCodeInterpreterAudit records are returned in-memory to the caller as part of the execution result rather than being securely written directly to an append-only log or system logging facility. A compromised agent runtime or untrusted caller can modify, delete, or ignore the audit structure, breaking the security audit trail.",
      "evidence": "The run(_:) method constructs CoreAgentAppleCodeInterpreterAudit and packages it inside the returned CoreAgentAppleCodeInterpreterResult, leaving persistence to the discretion of the caller.",
      "concrete_fix": "Define a secure, thread-safe audit logging protocol and pass a conforming logger to CoreAgentAppleDeterministicCodeInterpreter. Write audit records directly to this logger (e.g., using OSLog or write-only file handles) inside the run loop before returning."
    },
    {
      "severity": "P3",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 2325,
      "title": "Missing Non-Finite Number Checks on Interpreter Inputs and Math Operations",
      "description": "The deterministic interpreter only screens for non-finite numbers during the execution of .set instructions. It does not validate inputs provided in CoreAgentAppleDeterministicCodeRequest, nor does it check the results of mathematical operations like .add. This allows NaN or Infinity values to propagate into the environment and pollute execution outputs.",
      "evidence": "The check !value.isNonFiniteNumber is localized to the .set case in the instruction interpreter loop. No similar checks exist for program inputs or arithmetic result assignments.",
      "concrete_fix": "Perform a preflight validation on request.inputs to reject non-finite numbers, and wrap arithmetic operations (like add) in checks that fail the program if a non-finite result is produced."
    }
  ],
  "residual_risks": [
    "The sandbox profile relies entirely on the OS environment enforcing directory boundaries; the Swift code itself does not perform sandboxed path containment validation beyond rejecting output names containing path traversal sequences.",
    "Potential loss of sub-microsecond precision during stableTimeToken generation because timeIntervalSinceReferenceDate (Double) is multiplied by 1,000,000,000, which can result in rounding collisions for dates that are extremely close together."
  ],
  "testing_gaps": [
    "No integration tests verifying that mutating App Intents are denied execution when the host application is running in the background.",
    "No test coverage verifying that empty or zero-length SymmetricKey values in CoreAgentAppleConsentSigningKey fail verification or trigger initialization errors.",
    "No tests feeding NaN or Infinity values as input arguments to check for execution failures in CoreAgentAppleDeterministicCodeInterpreter."
  ]
}