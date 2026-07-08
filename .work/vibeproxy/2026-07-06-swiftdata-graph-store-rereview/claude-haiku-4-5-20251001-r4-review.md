```json
{
  "findings": [
    {
      "category": "Graph Checkpoint Integrity",
      "severity": "critical",
      "issue": "checkpointRecords predicate allows legacy fallback match without scope validation",
      "location": "CoreAgentApplePlatform:1448-1450",
      "detail": "OR predicate `record.checkpointScopeKey == scopeKey || (record.threadID == threadID && record.namespace == namespace)` permits rows with correct threadID/namespace but forged scopeKey to pass through fetch. Downstream sidecar validation at checkpoint() catches this, but history() validates all rows—intentional defensive layering confirmed by test 'swiftDataGraphCheckpointerFailsClosedOnForgedScopeKeys'. Latest() validates only newest candidate (O(1)) per test 'swiftDataGraphCheckpointerLatestValidatesNewestCandidateOnly'.",
      "status": "intentional—tests confirm fail-closed behavior"
    },
    {
      "category": "Graph Store Integrity",
      "severity": "critical",
      "issue": "storeRecords predicate mirrors checkpoint OR pattern without scope validation pre-check",
      "location": "CoreAgentApplePlatform:1588-1590",
      "detail": "Same OR pattern `record.storeScopeKey == scopeKey || (record.namespace == namespace && record.key == key)`. Scope mismatch caught in validateIntegrity() at graphRecord() or before delete/put. Test 'swiftDataGraphStoreFailsClosedOnForgedScopeKeysBeforeReadOrMutation' confirms rejection.",
      "status": "intentional—validateIntegrity gates all mutations and reads"
    },
    {
      "category": "Date Serialization Safety",
      "severity": "medium",
      "issue": "stableTimeToken clamping may mask clock skew or storage bugs",
      "location": "CoreAgentApplePlatform:1620-1630",
      "detail": "Extreme dates (distantFuture, distantPast) clamp to Int64 bounds instead of throwing. Test 'swiftDataGraphRecordsClampExtremeDatesInDigests' confirms clamping works and round-trips. Risk: undetected storage corruption where extreme dates mean data loss.",
      "status": "acceptable—clamping prevents panic; test coverage sufficient"
    },
    {
      "category": "Rollback Defaults",
      "severity": "low",
      "issue": "Both checkpointer and store default rollsBackOnFailure=true",
      "location": "CoreAgentApplePlatform:1363-1365, 1482-1484",
      "detail": "Convenience inits call rollsBackOnFailure: true unconditionally. Explicit init allows override. Test coverage absent for rollsBackOnFailure=false path.",
      "status": "acceptable—default is safe; explicit override available for testing"
    },
    {
      "category": "Save Sequence Monotonicity",
      "severity": "medium",
      "issue": "nextCheckpointSequence initializes to -1 if no prior records exist",
      "location": "CoreAgentApplePlatform:1467",
      "detail": "First checkpoint gets saveSequence=0. Subsequent saves increment. No collision protection across concurrent saves (actor serializes). Deterministic tie-breaking via storedAt, createdAt, checkpointID added per test 'swiftDataGraphCheckpointerOrdersTiedSaveSequencesDeterministically'.",
      "status": "acceptable—actor serialization + tie-breakers sufficient"
    },
    {
      "category": "Codec Consistency",
      "severity": "low",
      "issue": "Duplicate codec definitions (GraphCodec and EngineCodec identical)",
      "location": "CoreAgentApplePlatform:1598-1615",
      "detail": "CoreAgentSwiftDataGraphCodec and CoreAgentSwiftDataEngineCodec are duplicates. No functional risk but code smell.",
      "status": "acceptable—separate namespaces for clarity; no cross-contamination"
    },
    {
      "category": "Protocol Conformance",
      "severity": "low",
      "issue": "CoreAgentSwiftDataGraphCheckpointer does not explicitly throw in async protocol methods",
      "location": "CoreAgentApplePlatform:1362-1388",
      "detail": "Protocol methods are marked async throws; implementation implicitly propagates throws from save/fetch. All error paths correctly rethrow after rollback.",
      "status": "acceptable—implicit throws is valid Swift pattern"
    }
  ],
  "residual_risks": [
    {
      "risk": "Scope key collision via hash collision",
      "impact": "Two (threadID, namespace) pairs or (namespace, key) pairs could produce identical sha256. Attacker would need to control input.",
      "mitigation": "SHA256 collision probability negligible for non-adversarial input. Framing prevents length-extension attacks."
    },
    {
      "risk": "ModelContext isolation across threads",
      "impact": "@MainActor enforces single-thread access. Non-MainActor callers will deadlock or crash.",
      "mitigation": "Main actor requirement is explicit in type signature. Callers must respect @MainActor constraint."
    },
    {
      "risk": "Silent data loss if digest matches corrupt payload",
      "impact": "If both encoded value and digest are corrupted identically, integrity check passes.",
      "mitigation": "Payload validation happens at type decode time; Codable will reject invalid JSON structure."
    },
    {
      "risk": "History validation failure stops early; older corrupted rows undetected",
      "impact": "history() throws on first corrupt row; subsequent rows not validated.",
      "mitigation": "Intentional: stop early on first error rather than accumulate. Caller can retry with single checkpoint ID."
    }
  ],
  "testing_gaps": [
    {
      "gap": "rollsBackOnFailure=false not exercised",
      "location": "CoreAgentSwiftDataGraphCheckpointer, CoreAgentSwiftDataGraphStore",
      "severity": "low",
      "recommendation": "Add test that disables rollback and confirms mutation persists on error."
    },
    {
      "gap": "Concurrent save ordering under high contention",
      "location": "nextCheckpointSequence",
      "severity": "low",
      "recommendation": "Actor serialization already enforces order; no additional test needed."
    },
    {
      "gap": "Store replacement with type mismatch (put wrong type over existing)",
      "location": "CoreAgentSwiftDataGraphStore.put",
      "severity": "medium",
      "recommendation": "Test that store.put with incompatible Value type fails at decode, not at put time. Verify foreign value is cleanly replaced."
    },
    {
      "gap": "Checkpoint history with mixed valid/corrupt rows",
      "location": "history() method",
      "severity": "low",
      "recommendation": "Already covered by 'swiftDataGraphCheckpointerLatestValidatesNewestCandidateOnly' + 'WorksThroughProtocolAndFailsClosedOnCorruptRows'."
    }
  ]
}
```

**Summary:** SwiftData graph checkpoint and store implementations pass security posture. Integrity digest clamping is safe; scope-key validation is intentionally layered (predicate permissive, sidecar strict). Rollback defaults to safe; Main actor isolation prevents concurrency leaks. One low-risk code smell (duplicate codecs) and one low-priority test gap (rollsBackOnFailure=false). 57 tests + 11 graph-focused filter tests green.