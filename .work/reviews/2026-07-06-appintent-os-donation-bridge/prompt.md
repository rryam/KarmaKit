Review the current CoreAgent Swift package changes for the OS AppIntents donation-manager bridge slice.

Use a code-review stance: prioritize correctness, security/privacy, concurrency, API contract, Swift 6.4/Xcode 27/AppIntents issues, and missing tests. Do not edit files. Report P0/P1/P2 findings with exact file/line references. If a finding depends on an Apple API signature, verify against the installed SDK or current source before claiming it.

Scope:
- Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift
- Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift
- Tests/CoreAgentAppIntentsTests/CoreAgentAppIntentsTests.swift
- Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift
- Documentation/DeepAgents-Port-Task-Ledger.md only for stated slice scope

Contract to evaluate:
- This is a Swift-native CoreAgent port slice under the broader DeepAgents/LangGraph/SkillOpt/LangSmith goal.
- OS donation through AppIntents IntentDonationManager must not bypass CoreAgent app-intent donation policy, capability checks, consent checks, stable non-sensitive donation identity, run-ID validation, or invalidation semantics.
- The concrete OS backend must fail closed for non-donatable descriptors, invalid run IDs, mismatched donation records, and requests that were not authorized by the bridge.
- The bridge must bind run intent kind/runID to the donation subject before consent, store, or OS backend work.
- Donation receipts must carry enough authority to invalidate the OS donation later without out-of-band token plumbing, while rejecting/treating mismatched persisted token digest state as invalid.
- Invalidation must be action-gated, must not delete an OS donation before CoreAgent authorization, and when both donationIdentifier and scopeID are provided, both filters must match.
- SwiftData/SwiftUI/AppIntents must remain Apple-platform adapters and not become portable CoreAgent core truth.

Fresh local evidence before review:
- swift test --skip-update --filter CoreAgentAppIntentsTests passed 16 tests.
- swift test --skip-update --filter 'CoreAgentApplePlatformTests/appIntentDonation|CoreAgentAppIntentsTests' passed 5 ApplePlatform donation tests plus 16 AppIntents tests.

Tooling note:
- VibeProxy is not the formal review gate. This formal review should be independent of VibeProxy output.
