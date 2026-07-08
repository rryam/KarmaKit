{
  "verdict": "BLOCK",
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 727,
      "title": "Corrupted optimizer memory is silently reset on rejected-edit write",
      "description": "recordRejected uses readMemory(skillID:) ?? CoreAgentSkillOptimizerMemory(). If the existing optimizer-memory JSON exists but is corrupted or undecodable, readMemory returns nil and the method writes a fresh memory file, silently erasing persisted rejected edits/meta-observations. This violates the fail-closed persistence requirement for persisted optimizer memory.",
      "concrete_fix": "Distinguish missing memory files from decode failures. For recordRejected, check file existence first; if absent, start with empty memory; if present, decode with a throwing read and propagate decoding errors without writing. For example, add readMemoryForMutation(skillID:) throws -> CoreAgentSkillOptimizerMemory that returns empty only when the file does not exist."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 736,
      "title": "Corrupted optimizer memory is silently reset on meta-observation write",
      "description": "recordMetaObservation has the same fail-open behavior as recordRejected: an existing but corrupted optimizer-memory file is treated as missing and overwritten with a new memory object. This can silently erase durable optimizer memory after corruption.",
      "concrete_fix": "Use the same throwing memory-read path for recordMetaObservation. Only default to CoreAgentSkillOptimizerMemory() when the memory file is absent; if the file exists and decoding fails, throw and do not write."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 789,
      "title": "allCurrentSkills can accept structurally valid rows from the wrong skill directory",
      "description": "currentSkill(in:) decodes each JSON row but does not verify that the decoded skill belongs in the directory being scanned. A corrupted/tampered row placed under one skill directory with a different skill.id can be treated as a valid current skill by allCurrentSkills, even though currentSkill(id:) performs an id check. This leaves a corruption path where invalid storage layout is silently accepted.",
      "concrete_fix": "In currentSkill(in:), after decoding each skill, verify that skillDirectory(for: skill.id) resolves to the same standardized/resolved directory being scanned. If it does not, return nil for that directory. Also consider validating the filename against the decoded version, e.g. version-<skill.version>.json."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentSkills/CoreAgentSkills.swift",
      "line": 771,
      "title": "Skill row filename/version mismatch is not rejected",
      "description": "skillHistory(id:) and currentSkill(in:) trust the decoded skill.version regardless of the containing filename. A valid JSON row named version-1.json can contain version 99 and become the current skill. This weakens version-collision and corruption semantics after resume when files are manually corrupted or partially restored.",
      "concrete_fix": "When reading a skill row, validate that url.lastPathComponent == \"version-\\(skill.version).json\". Treat mismatches as corrupted rows and fail closed for that skill directory."
    }
  ],
  "testing_gaps": [
    "Add a file-backed test where an existing optimizer-memory JSON file is corrupted, then recordRejected is called; assert it throws and does not replace/truncate the corrupted file.",
    "Add the same corrupted optimizer-memory test for recordMetaObservation.",
    "Add a test where a valid CoreAgentSkill JSON with id B is placed inside skill A's directory; assert allCurrentSkills does not return it.",
    "Add a test where version-1.json contains a decoded CoreAgentSkill with version 99; assert currentSkill(id:) and allCurrentSkills fail closed for that skill rather than treating version 99 as current.",
    "Add a test for multiple JSON files in the same skill directory with duplicate decoded versions but different filenames, if filename/version validation is not otherwise enforced.",
    "Add a path-safety test covering more adversarial skill IDs than ../swift/planner, such as absolute-looking IDs, repeated separators, percent-encoded traversal strings, Unicode separators, empty components, and very long IDs.",
    "Add a test proving rejected-edit/meta-observation persistence failures propagate through CoreAgentSkillOptimizer.propose and CoreAgentSkillSleepOptimizer rather than being converted into successful rejected results.",
    "Add a file-backed curator test using FileCoreAgentSkillStore directly to confirm generic CoreAgentSkillCurator behavior over resumed persisted skills."
  ],
  "residual_risks": [
    "The file-backed store does not provide multi-process locking or cross-process atomic version allocation; this is future scope per review boundaries.",
    "best_skill.md export writes to the caller-provided directory and is not constrained to the store root; this appears intentional but should be documented.",
    "Optimizer rejection persistence is split across rejectedEdits and metaObservations writes, so a crash or second-write failure can leave partially recorded rejection memory.",
    "The protocol exposes optimizerMemory as non-throwing, which makes it difficult to surface memory decode corruption to callers without changing API semantics."
  ]
}