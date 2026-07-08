Review this Swift CoreAgentSkills FoundationModels-backed SkillOpt proposal backend slice. Return STRICT JSON only:
{
  "verdict": "PASS" | "BLOCK",
  "findings": [
    {"severity":"P0|P1|P2|P3", "file":"path", "line":123, "title":"short", "description":"specific", "concrete_fix":"specific"}
  ],
  "testing_gaps": ["..."],
  "residual_risks": ["..."]
}

Scope: only the new concrete FoundationModels SkillOpt proposal backend and tests.
Do not review unrelated Graph, Deep, ApplePlatform, AppIntents, SwiftData, file-backed store, replay executor, or prior L26 model-proposal boundary unless this backend directly weakens them.

Expected contract:
- CoreAgentSkillFoundationModelsProposalBackend wraps CoreAgentSession.respond(generating:) with FoundationModels @Generable structured output, not raw string parsing.
- Backend sanitizes direct CoreAgentSkillModelProposalRequest input before prompting: strips skill provenance, allowlists evidence metadata, rejects empty IDs, invalid scores, invalid lowercase sha256 digests, duplicate evidence IDs, invalid policy, invalid maxProposals, and invalid baseline.
- Backend prompt contains enough sanitized skill/evidence/policy context and edit operation literals for model generation, without verifierFeedback, raw_prompt, or old provenance notes.
- Model drafts are untrusted. Backend only maps supported edit operation literals (replace, append) into typed CoreAgentSkillEdit; unknown operations fail closed.
- Existing CoreAgentSkillModelProposalGenerator remains the final trust boundary for proposal IDs, duplicate candidates, matching skill/baseline, candidate edit applicability, validation scores/suites, training split leakage, evidence references, and deterministic validation notes.
- Tests should assert durable contracts, not incidental model prose.

Latest local verification before this review:
- swift test --skip-update --filter CoreAgentSkillsTests/foundationModelsProposalBackend: PASS, 2 tests.
- swift test --skip-update --filter CoreAgentSkillsTests: PASS, 38 tests.
- swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests': PASS, 38 Skills + 11 Engine tests.

=== Package.swift CoreAgentSkillsTests dependency ===
   150	      name: "CoreAgentMemoryTests",
   151	      dependencies: ["CoreAgent", "CoreAgentMemory"]
   152	    ),
   153	    .testTarget(
   154	      name: "CoreAgentMemoryIntegrationTests",
   155	      dependencies: ["CoreAgent", "CoreAgentMemory", "CoreAgentTestSupport"]
   156	    ),
   157	    .testTarget(
   158	      name: "CoreAgentGraphTests",
   159	      dependencies: ["CoreAgentGraph"]
   160	    ),
   161	    .testTarget(
   162	      name: "CoreAgentDeepTests",

=== Sources/CoreAgentSkills/CoreAgentSkills.swift backend lines 726-920 ===
   726	public protocol CoreAgentSkillModelProposalBackend: Sendable {
   727	  func generate(
   728	    _ request: CoreAgentSkillModelProposalRequest
   729	  ) async throws -> [CoreAgentSkillModelProposalCandidate]
   730	}
   731	
   732	@Generable
   733	private struct CoreAgentSkillFoundationModelsProposalEnvelope: Sendable {
   734	  let proposals: [CoreAgentSkillFoundationModelsProposalDraft]
   735	}
   736	
   737	@Generable
   738	private struct CoreAgentSkillFoundationModelsProposalDraft: Sendable {
   739	  let id: String
   740	  let skillID: String
   741	  let baselineScore: Double
   742	  let edits: [CoreAgentSkillFoundationModelsEditDraft]
   743	  let validationScore: Double
   744	  let validationHeldoutSuiteID: String
   745	  let validationPassed: Bool
   746	  let validationNotes: String
   747	  let evidenceIDs: [String]
   748	}
   749	
   750	@Generable
   751	private struct CoreAgentSkillFoundationModelsEditDraft: Sendable {
   752	  let operation: String
   753	  let target: String
   754	  let replacement: String
   755	  let appendText: String
   756	}
   757	
   758	public struct CoreAgentSkillFoundationModelsProposalBackend:
   759	  CoreAgentSkillModelProposalBackend
   760	{
   761	  private let session: CoreAgentSession
   762	
   763	  public init(session: CoreAgentSession) {
   764	    self.session = session
   765	  }
   766	
   767	  public func generate(
   768	    _ request: CoreAgentSkillModelProposalRequest
   769	  ) async throws -> [CoreAgentSkillModelProposalCandidate] {
   770	    let sanitizedRequest = try Self.sanitized(request)
   771	    let response = try await session.respond(
   772	      to: try Self.prompt(for: sanitizedRequest),
   773	      generating: CoreAgentSkillFoundationModelsProposalEnvelope.self
   774	    )
   775	    return try Self.candidates(from: response.content, request: sanitizedRequest)
   776	  }
   777	
   778	  private static func sanitized(
   779	    _ request: CoreAgentSkillModelProposalRequest
   780	  ) throws -> CoreAgentSkillModelProposalRequest {
   781	    try request.policy.validate()
   782	    guard !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
   783	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   784	        "proposal run ID must be non-empty"
   785	      )
   786	    }
   787	    guard request.maxProposals > 0 else {
   788	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   789	        "proposal maxProposals must be positive"
   790	      )
   791	    }
   792	    guard request.baselineScore.isFinite,
   793	      request.baselineScore >= 0,
   794	      request.baselineScore <= 1
   795	    else {
   796	      throw CoreAgentSkillOptimizationError.invalidValidationScore(request.baselineScore)
   797	    }
   798	    guard !request.skill.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
   799	    else {
   800	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   801	        "proposal skill ID must be non-empty"
   802	      )
   803	    }
   804	    var seenEvidenceIDs: Set<String> = []
   805	    let evidence = try request.evidence.map { reference in
   806	      guard !reference.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
   807	        !reference.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
   808	      else {
   809	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   810	          "proposal evidence identity fields must be non-empty"
   811	        )
   812	      }
   813	      guard seenEvidenceIDs.insert(reference.id).inserted else {
   814	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   815	          "proposal evidence IDs must be unique"
   816	        )
   817	      }
   818	      guard isSHA256Digest(reference.transcriptDigest),
   819	        isSHA256Digest(reference.toolEventDigest)
   820	      else {
   821	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   822	          "proposal evidence digests must be sha256"
   823	        )
   824	      }
   825	      guard reference.score.isFinite, reference.score >= 0, reference.score <= 1
   826	      else {
   827	        throw CoreAgentSkillOptimizationError.invalidValidationScore(reference.score)
   828	      }
   829	      return CoreAgentSkillModelProposalEvidenceReference(
   830	        id: reference.id,
   831	        taskID: reference.taskID,
   832	        transcriptDigest: reference.transcriptDigest,
   833	        toolEventDigest: reference.toolEventDigest,
   834	        score: reference.score,
   835	        metadata: sanitizedModelProposalEvidenceMetadata(reference.metadata)
   836	      )
   837	    }
   838	    return CoreAgentSkillModelProposalRequest(
   839	      runID: request.runID,
   840	      skill: CoreAgentSkill(
   841	        id: request.skill.id,
   842	        version: request.skill.version,
   843	        title: request.skill.title,
   844	        body: request.skill.body,
   845	        tags: request.skill.tags,
   846	        priority: request.skill.priority,
   847	        provenance: []
   848	      ),
   849	      baselineScore: request.baselineScore,
   850	      evidence: evidence,
   851	      policy: request.policy,
   852	      maxProposals: request.maxProposals
   853	    )
   854	  }
   855	
   856	  private static func prompt(
   857	    for request: CoreAgentSkillModelProposalRequest
   858	  ) throws -> String {
   859	    let encoder = JSONEncoder()
   860	    encoder.outputFormatting = [.sortedKeys]
   861	    let requestData = try encoder.encode(request)
   862	    guard let requestJSON = String(data: requestData, encoding: .utf8) else {
   863	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   864	        "proposal request JSON must be UTF-8"
   865	      )
   866	    }
   867	    return """
   868	      Generate CoreAgent SkillOpt model proposal candidates from the sanitized request.
   869	      Use FoundationModels structured generation only; do not return prose outside the schema.
   870	      Return at most maxProposals candidates. Every candidate must reference supplied evidenceIDs.
   871	      Supported edit operation literals:
   872	      - replace: set operation to "replace", target to exact current skill text, and replacement to the new text.
   873	      - append: set operation to "append" and appendText to the text to add.
   874	      Validate against held-out suites only; never use trainingSuiteIDs as validationHeldoutSuiteID.
   875	      Sanitized CoreAgentSkillModelProposalRequest JSON:
   876	      \(requestJSON)
   877	      """
   878	  }
   879	
   880	  private static func candidates(
   881	    from envelope: CoreAgentSkillFoundationModelsProposalEnvelope,
   882	    request: CoreAgentSkillModelProposalRequest
   883	  ) throws -> [CoreAgentSkillModelProposalCandidate] {
   884	    guard envelope.proposals.count <= request.maxProposals else {
   885	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   886	        "proposal backend exceeded maxProposals"
   887	      )
   888	    }
   889	    return try envelope.proposals.map { proposal in
   890	      CoreAgentSkillModelProposalCandidate(
   891	        id: proposal.id,
   892	        skillID: CoreAgentSkillID(proposal.skillID),
   893	        baselineScore: proposal.baselineScore,
   894	        candidateEdits: try proposal.edits.map(edit),
   895	        validation: CoreAgentSkillValidationResult(
   896	          score: proposal.validationScore,
   897	          heldoutSuiteID: proposal.validationHeldoutSuiteID,
   898	          passed: proposal.validationPassed,
   899	          notes: proposal.validationNotes
   900	        ),
   901	        evidenceIDs: proposal.evidenceIDs
   902	      )
   903	    }
   904	  }
   905	
   906	  private static func edit(
   907	    from draft: CoreAgentSkillFoundationModelsEditDraft
   908	  ) throws -> CoreAgentSkillEdit {
   909	    switch draft.operation.trimmingCharacters(in: .whitespacesAndNewlines) {
   910	    case "replace":
   911	      return .replace(target: draft.target, replacement: draft.replacement)
   912	    case "append":
   913	      return .append(draft.appendText)
   914	    default:
   915	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   916	        "model proposal edit operation is unsupported"
   917	      )
   918	    }
   919	  }
   920	}

=== Sources/CoreAgentSkills/CoreAgentSkills.swift generator validation lines 922-1040 ===
   922	public struct CoreAgentSkillModelProposalGenerator: Sendable {
   923	  private let backend: any CoreAgentSkillModelProposalBackend
   924	
   925	  public init(backend: any CoreAgentSkillModelProposalBackend) {
   926	    self.backend = backend
   927	  }
   928	
   929	  public func generate(
   930	    runID: String,
   931	    skill: CoreAgentSkill,
   932	    baselineScore: Double,
   933	    evidence: [CoreAgentSkillRolloutEvidence],
   934	    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(),
   935	    maxProposals: Int = 3
   936	  ) async throws -> [CoreAgentSkillSleepOptimizationProposal] {
   937	    let request = try Self.request(
   938	      runID: runID,
   939	      skill: skill,
   940	      baselineScore: baselineScore,
   941	      evidence: evidence,
   942	      policy: policy,
   943	      maxProposals: maxProposals
   944	    )
   945	    let candidates = try await backend.generate(request)
   946	    return try Self.proposals(from: candidates, request: request)
   947	  }
   948	
   949	  private static func request(
   950	    runID: String,
   951	    skill: CoreAgentSkill,
   952	    baselineScore: Double,
   953	    evidence: [CoreAgentSkillRolloutEvidence],
   954	    policy: CoreAgentSkillOptimizationPolicy,
   955	    maxProposals: Int
   956	  ) throws -> CoreAgentSkillModelProposalRequest {
   957	    try policy.validate()
   958	    guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
   959	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   960	        "proposal run ID must be non-empty"
   961	      )
   962	    }
   963	    guard maxProposals > 0 else {
   964	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   965	        "proposal maxProposals must be positive"
   966	      )
   967	    }
   968	    guard baselineScore.isFinite, baselineScore >= 0, baselineScore <= 1 else {
   969	      throw CoreAgentSkillOptimizationError.invalidValidationScore(baselineScore)
   970	    }
   971	    guard !skill.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
   972	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
   973	        "proposal skill ID must be non-empty"
   974	      )
   975	    }
   976	    let references = try evidence.map(sanitizedEvidenceReference)
   977	    try validateUniqueEvidenceIDs(references)
   978	    return CoreAgentSkillModelProposalRequest(
   979	      runID: runID,
   980	      skill: CoreAgentSkill(
   981	        id: skill.id,
   982	        version: skill.version,
   983	        title: skill.title,
   984	        body: skill.body,
   985	        tags: skill.tags,
   986	        priority: skill.priority,
   987	        provenance: []
   988	      ),
   989	      baselineScore: baselineScore,
   990	      evidence: references,
   991	      policy: policy,
   992	      maxProposals: maxProposals
   993	    )
   994	  }
   995	
   996	  private static func proposals(
   997	    from candidates: [CoreAgentSkillModelProposalCandidate],
   998	    request: CoreAgentSkillModelProposalRequest
   999	  ) throws -> [CoreAgentSkillSleepOptimizationProposal] {
  1000	    guard candidates.count <= request.maxProposals else {
  1001	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1002	        "proposal backend exceeded maxProposals"
  1003	      )
  1004	    }
  1005	    var seen: Set<String> = []
  1006	    let evidenceByID = Dictionary(uniqueKeysWithValues: request.evidence.map { ($0.id, $0) })
  1007	    return try candidates.map { candidate in
  1008	      guard isSafeProposalIdentifier(candidate.id) else {
  1009	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1010	          "proposal candidate ID is invalid"
  1011	        )
  1012	      }
  1013	      guard seen.insert(candidate.id).inserted else {
  1014	        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(candidate.id)
  1015	      }
  1016	      guard candidate.skillID == request.skill.id else {
  1017	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1018	          "proposal candidate skill must match request skill"
  1019	        )
  1020	      }
  1021	      guard candidate.baselineScore == request.baselineScore else {
  1022	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1023	          "proposal candidate baseline must match request baseline"
  1024	        )
  1025	      }
  1026	      guard !candidate.candidateEdits.isEmpty else {
  1027	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1028	          "proposal candidate edits must be non-empty"
  1029	        )
  1030	      }
  1031	      guard candidate.candidateEdits.count <= request.policy.maxEditsPerProposal else {
  1032	        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  1033	          "proposal candidate exceeds maxEditsPerProposal"
  1034	        )
  1035	      }
  1036	      try validateSkillOptimizationScores(
  1037	        candidate.validation,
  1038	        baselineScore: candidate.baselineScore
  1039	      )
  1040	      if request.policy.trainingSuiteIDs.contains(candidate.validation.heldoutSuiteID) {

=== Sources/CoreAgentSkills/CoreAgentSkills.swift shared metadata/digest helpers lines 2670-2725 ===
  2670	    let evaluationSuiteIDs = Set(evaluations.map(\.heldoutSuiteID))
  2671	    if !evaluationSuiteIDs.isEmpty, evaluationSuiteIDs != Set([heldoutSuiteID]) {
  2672	      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  2673	        "adapter heldoutSuiteID must match objective evaluation suites"
  2674	      )
  2675	    }
  2676	    let result = try optimizer.selectBest(
  2677	      candidates: [CoreAgentHarnessCandidate(id: candidateID, parameters: [:])],
  2678	      objectiveEvaluations: evaluations,
  2679	      objectives: objectives
  2680	    )
  2681	    guard let entry = result.auditTrail.first else {
  2682	      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidateID)
  2683	    }
  2684	    return CoreAgentSkillValidationResult(
  2685	      score: entry.weightedScore,
  2686	      heldoutSuiteID: heldoutSuiteID,
  2687	      passed: entry.eligible && entry.weightedScore >= passingScore,
  2688	      notes: notes
  2689	    )
  2690	  }
  2691	}
  2692	
  2693	private func sha256Hex(_ data: Data) -> String {
  2694	  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  2695	}
  2696	
  2697	private func sanitizedModelProposalEvidenceMetadata(
  2698	  _ metadata: [String: String]
  2699	) -> [String: String] {
  2700	  metadata.reduce(into: [:]) { result, pair in
  2701	    if modelProposalAllowedEvidenceMetadataKeys.contains(pair.key) {
  2702	      result[pair.key] = pair.key == "source_suite_id"
  2703	        ? pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
  2704	        : pair.value
  2705	    }
  2706	  }
  2707	}
  2708	
  2709	private let modelProposalAllowedEvidenceMetadataKeys: Set<String> = [
  2710	  "source",
  2711	  "project_id",
  2712	  "thread_id",
  2713	  "run_id",
  2714	  "run_status",
  2715	  "event_count",
  2716	  "tool_event_count",
  2717	  "receipt_root_hash",
  2718	  "input_tokens",
  2719	  "cached_input_tokens",
  2720	  "output_tokens",
  2721	  "reasoning_tokens",
  2722	  "issue_id_digest",
  2723	  "issue_status",
  2724	  "suite_id",
  2725	  "replay_request_id",

=== Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift backend tests lines 1870-2012 ===
  1870	
  1871	  @Test("FoundationModels proposal backend generates typed SkillOpt candidates")
  1872	  func foundationModelsProposalBackendGeneratesTypedSkillOptCandidates() async throws {
  1873	    let model = RecordedLanguageModel(steps: [.response(text: """
  1874	      {
  1875	        "proposals": [
  1876	          {
  1877	            "id": "proposal-fm-1",
  1878	            "skillID": "swift",
  1879	            "baselineScore": 0.4,
  1880	            "edits": [
  1881	              {
  1882	                "operation": "replace",
  1883	                "target": "Use XCTest for all new tests.",
  1884	                "replacement": "Use Swift Testing with typed assertions for all new tests.",
  1885	                "appendText": ""
  1886	              }
  1887	            ],
  1888	            "validationScore": 0.76,
  1889	            "validationHeldoutSuiteID": "heldout-swift",
  1890	            "validationPassed": true,
  1891	            "validationNotes": "raw model notes should not become stored validation prose",
  1892	            "evidenceIDs": ["evidence-typed"]
  1893	          }
  1894	        ]
  1895	      }
  1896	      """)])
  1897	    let session = try CoreAgentSession(model: model)
  1898	    let backend = CoreAgentSkillFoundationModelsProposalBackend(session: session)
  1899	    let generator = CoreAgentSkillModelProposalGenerator(backend: backend)
  1900	    let skill = CoreAgentSkill(
  1901	      id: CoreAgentSkillID("swift"),
  1902	      version: 3,
  1903	      title: "Swift testing skill",
  1904	      body: "Use XCTest for all new tests.",
  1905	      tags: ["swift"],
  1906	      provenance: [
  1907	        CoreAgentSkillProvenance(
  1908	          heldoutSuiteID: "old-heldout",
  1909	          validationScore: 0.5,
  1910	          notes: "foundation-secret provenance"
  1911	        )
  1912	      ]
  1913	    )
  1914	    let evidence = CoreAgentSkillRolloutEvidence(
  1915	      id: "evidence-typed",
  1916	      taskID: "task-typed",
  1917	      transcriptDigest: Self.digest(1_100),
  1918	      toolEventDigest: Self.digest(1_101),
  1919	      verifierFeedback: "foundation-secret verifier feedback",
  1920	      score: 0.4,
  1921	      metadata: [
  1922	        "source": "coreagent-engine",
  1923	        "run_status": "failed",
  1924	        "raw_prompt": "foundation-secret raw prompt",
  1925	      ]
  1926	    )
  1927	
  1928	    let proposals = try await generator.generate(
  1929	      runID: "foundation-run-1",
  1930	      skill: skill,
  1931	      baselineScore: 0.4,
  1932	      evidence: [evidence],
  1933	      maxProposals: 2
  1934	    )
  1935	
  1936	    let proposal = try #require(proposals.first)
  1937	    #expect(proposals.count == 1)
  1938	    #expect(proposal.id == "proposal-fm-1")
  1939	    #expect(proposal.proposal.skillID == skill.id)
  1940	    #expect(proposal.proposal.candidateEdits == [
  1941	      .replace(
  1942	        target: "Use XCTest for all new tests.",
  1943	        replacement: "Use Swift Testing with typed assertions for all new tests."
  1944	      )
  1945	    ])
  1946	    #expect(proposal.proposal.validation.score == 0.76)
  1947	    #expect(proposal.proposal.validation.heldoutSuiteID == "heldout-swift")
  1948	    #expect(proposal.proposal.validation.notes == "model proposal proposal-fm-1 validation")
  1949	    #expect(proposal.evidence.map(\.id) == ["evidence-typed"])
  1950	    #expect(proposal.evidence.first?.verifierFeedback == "proposal evidence reference")
  1951	
  1952	    let transcript = try #require(model.recorder.capturedTranscripts().first)
  1953	    #expect(transcript.containsText("foundation-run-1"))
  1954	    #expect(transcript.containsText("Use XCTest for all new tests."))
  1955	    #expect(transcript.containsText("evidence-typed"))
  1956	    #expect(transcript.containsText("replace"))
  1957	    #expect(transcript.containsText("append"))
  1958	    #expect(!transcript.containsText("foundation-secret"))
  1959	    #expect(!transcript.containsText("raw_prompt"))
  1960	  }
  1961	
  1962	  @Test("FoundationModels proposal backend rejects unsupported model edit operations")
  1963	  func foundationModelsProposalBackendRejectsUnsupportedModelEditOperations() async throws {
  1964	    let model = RecordedLanguageModel(steps: [.response(text: """
  1965	      {
  1966	        "proposals": [
  1967	          {
  1968	            "id": "proposal-fm-1",
  1969	            "skillID": "swift",
  1970	            "baselineScore": 0.4,
  1971	            "edits": [
  1972	              {
  1973	                "operation": "delete",
  1974	                "target": "Use XCTest.",
  1975	                "replacement": "",
  1976	                "appendText": ""
  1977	              }
  1978	            ],
  1979	            "validationScore": 0.76,
  1980	            "validationHeldoutSuiteID": "heldout-swift",
  1981	            "validationPassed": true,
  1982	            "validationNotes": "candidate",
  1983	            "evidenceIDs": ["evidence-typed"]
  1984	          }
  1985	        ]
  1986	      }
  1987	      """)])
  1988	    let session = try CoreAgentSession(model: model)
  1989	    let backend = CoreAgentSkillFoundationModelsProposalBackend(session: session)
  1990	    let request = CoreAgentSkillModelProposalRequest(
  1991	      runID: "foundation-run-1",
  1992	      skill: Self.skill(id: "swift", body: "Use XCTest."),
  1993	      baselineScore: 0.4,
  1994	      evidence: [
  1995	        CoreAgentSkillModelProposalEvidenceReference(
  1996	          id: "evidence-typed",
  1997	          taskID: "task-typed",
  1998	          transcriptDigest: Self.digest(1_120),
  1999	          toolEventDigest: Self.digest(1_121),
  2000	          score: 0.4,
  2001	          metadata: ["source": "coreagent-engine"]
  2002	        )
  2003	      ],
  2004	      maxProposals: 1
  2005	    )
  2006	
  2007	    await #expect(throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
  2008	      "model proposal edit operation is unsupported"
  2009	    )) {
  2010	      _ = try await backend.generate(request)
  2011	    }
  2012	  }

=== Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift transcript helper lines 2283-2315 ===
  2283	private extension Transcript {
  2284	  func containsText(_ expected: String) -> Bool {
  2285	    contains { entry in
  2286	      switch entry {
  2287	      case .instructions(let instructions):
  2288	        instructions.segments.containsText(expected)
  2289	      case .prompt(let prompt):
  2290	        prompt.segments.containsText(expected)
  2291	      case .toolOutput(let output):
  2292	        output.segments.containsText(expected)
  2293	      case .response(let response):
  2294	        response.segments.containsText(expected)
  2295	      case .reasoning(let reasoning):
  2296	        reasoning.segments.containsText(expected)
  2297	      case .toolCalls(let calls):
  2298	        calls.contains { $0.arguments.jsonString.contains(expected) }
  2299	      @unknown default:
  2300	        false
  2301	      }
  2302	    }
  2303	  }
  2304	}
  2305	
  2306	private extension [Transcript.Segment] {
  2307	  func containsText(_ expected: String) -> Bool {
  2308	    contains { segment in
  2309	      if case .text(let text) = segment {
  2310	        return text.content.contains(expected)
  2311	      }
  2312	      return false
  2313	    }
  2314	  }
  2315	}
