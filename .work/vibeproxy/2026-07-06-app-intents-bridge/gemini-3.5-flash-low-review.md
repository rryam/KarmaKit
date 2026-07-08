{
  "verdict": "BLOCK",
  "findings": [
    {
      "severity": "P0",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 288,
      "title": "AppIntent perform bypasses ActionGate and Consent checks",
      "description": "The AppIntent concrete implementations (CoreAgentOpenRunIntent, CoreAgentPauseRunIntent, CoreAgentContinueRunIntent) invoke CoreAgentRunAppIntentRuntime.shared.perform(_:) directly. This runtime method delegates immediately to the registered handler without validating the operation via CoreAgentAppIntentBridge or verifying consent requirements with CoreAgentAppleActionGate. Consequently, host work can be triggered externally via Siri/Shortcuts bypassing security boundaries.",
      "concrete_fix": "Refactor CoreAgentRunAppIntentRuntime to require reference to the action gate or bridge, or include the CoreAgentAppleConsent receipt in the runtime request, and ensure CoreAgentAppIntentBridge.perform is executed before the host handler callback is invoked."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 172,
      "title": "Bridge permits host side-effects on cancelled requests",
      "description": "In CoreAgentAppIntentBridge.perform(_:operation:), if request.checkpointKey is nil, the bridge transitions directly from evaluating the action gate to executing the operation callback. There is no cancellation check immediately before calling the operation. If a request or Task is cancelled after evaluation but before the operation starts, the host work will still be executed, causing unwanted side effects.",
      "concrete_fix": "Add an explicit guard check 'if request.isCancelled() { return result(for: request, status: .cancelled) }' immediately before invoking 'try await operation(request)' inside CoreAgentAppIntentBridge.perform."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 79,
      "title": "OS Policy Mapper default supportedModes drifts from concrete intents",
      "description": "CoreAgentAppIntentOSPolicyMapper.supportedModes(for:) maps all .readOnly descriptors to .foreground(.deferred). However, CoreAgentOpenRunIntent (which is a read-only intent) defines its OS policy supported modes as .foreground(.immediate). This mismatch creates a drift between catalog policy mapping expectations and concrete wrapper runtime declarations.",
      "concrete_fix": "Align the policy mapper helper to return .foreground(.immediate) for descriptors matching read-only intents that demand immediate foreground presentation, or validate that catalog entries don't conflict with mapper defaults."
    }
  ],
  "testing_gaps": [
    "No integration tests covering the end-to-end flow from AppIntent.perform() through the ActionGate check to the final host execution.",
    "Lack of concurrency/race condition testing when modifying the runtime handler concurrently with active intent execution tasks."
  ],
  "residual_risks": [
    "If the host application registers a custom handler that bypasses the bridge's verification, security boundaries will be entirely compromised.",
    "OS-level execution target differences (e.g., background launches when foreground is required) are not enforced at the AppIntent entry point before delegation."
  ]
}
