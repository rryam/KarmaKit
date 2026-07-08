{
  "verdict": "BLOCK",
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 1803,
      "title": "Required-mean gating ignores minimize direction",
      "description": "For minimize objectives, the optimizer validates and computes normalizedMeanScore as 1 - meanScore, but passedRequiredMean is still computed as raw meanScore >= requiredMeanScore. That makes low raw scores, which are better for minimize objectives, fail thresholds that should be evaluated directionally/against the normalized score. Example: a latency minimize objective with meanScore 0.10 and requiredMeanScore 0.80 should pass if the normalized mean is 0.90, but this implementation fails it.",
      "concrete_fix": "Compute required-mean pass/fail using the direction-normalized value, e.g. `let passedRequiredMean = objective.requiredMeanScore.map { normalizedMeanScore >= $0 } ?? true`, or if the intended contract is raw thresholds, define and implement minimize as `meanScore <= requiredMeanScore` with explicit tests."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 1914,
      "title": "Duplicate objective-evaluation key can collide",
      "description": "Duplicate detection builds a string key by joining candidateID, heldoutSuiteID, and objectiveID with `:`. Because these IDs are not restricted from containing `:`, distinct evaluations can produce the same key and be rejected as duplicates, e.g. candidate `a:b` + suite `c` + objective `d` collides with candidate `a` + suite `b:c` + objective `d`.",
      "concrete_fix": "Replace the joined string key with a Hashable tuple-like struct, e.g. `struct ObjectiveEvaluationKey: Hashable { let candidateID: String; let heldoutSuiteID: String; let objectiveID: CoreAgentHarnessObjectiveID }`, and store `Set<ObjectiveEvaluationKey>`."
    }
  ],
  "testing_gaps": [
    "No test covers requiredMeanScore semantics for minimize objectives.",
    "No test covers deterministic candidateID tie-breaking when weighted scores are equal.",
    "No test covers duplicate objective IDs.",
    "No test covers duplicate candidate IDs in the multi-objective selectBest overload.",
    "No test covers empty objectives.",
    "No test covers invalid objective weights, including zero, negative, infinity, and NaN.",
    "No test covers invalid objective evaluation scores, including NaN, infinity, below 0, and above 1.",
    "No test covers unknown candidate IDs in objective evaluations.",
    "No test covers unknown objective IDs in objective evaluations.",
    "No test covers missing candidate/objective evaluation combinations across multiple candidates and objectives.",
    "No test covers objective-evaluation duplicate-key delimiter collisions in IDs containing `:`.",
    "No test asserts sorted heldoutSuiteIDs across multiple heldout suites per objective and across the result-level heldout suites."
  ],
  "residual_risks": [
    "The scalar selectBest path still does not validate scalar evaluation score finiteness/range or empty heldout suite IDs; this may be intentional compatibility preservation but remains a behavioral difference from the typed multi-objective path.",
    "The adapter returns only CoreAgentSkillValidationResult, so callers that need the objective audit must separately call the optimizer API.",
    "Error cases mostly reuse invalidOptimizationPolicy or missingHarnessEvaluation strings, so downstream consumers may rely on prose unless additional typed errors are added later."
  ]
}