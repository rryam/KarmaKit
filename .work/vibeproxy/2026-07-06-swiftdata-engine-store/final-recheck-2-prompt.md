You are doing a final narrow recheck of a Swift 6.4 / Xcode 27 CoreAgent patch.

Verify only these areas: forged traceScopeKey rows, issue contributingRunIDs provenance across partial upserts and duplicate rows, and issueID project/fingerprint collision rejection. Return VERDICT: PASS or BLOCK. If BLOCK, list only unresolved correctness/security/data-integrity defects in those areas.

## CoreAgentEngine.swift relevant excerpts
    80	    projectID: String,
    81	    status: CoreAgentEngineIssueStatus?
    82	  ) async -> [CoreAgentEngineIssue]
    83	}
    84
    85	public enum CoreAgentEngineStoreError: Error, Equatable, Sendable {
    86	  case nonFinalizedRun(UUID)
    87	  case eventRunIDMismatch(eventRunID: UUID, runID: UUID)
    88	  case issueIdentityMismatch(
    89	    issueID: String,
    90	    existingProjectID: String,
    91	    incomingProjectID: String,
    92	    existingFingerprint: String,
    93	    incomingFingerprint: String
    94	  )
    95	}
    96
    97	public extension CoreAgentEngineStore {
    98	  @discardableResult
    99	  func ingest(
   100	    _ run: CoreAgentRun,
   101	    projectID: String,
   102	    threadID: String? = nil
   103	  ) async throws -> CoreAgentEngineTrace {
   104	    try await ingest(run, projectID: projectID, threadID: threadID)
   105	  }
   106
   107	  func traces(projectID: String) async -> [CoreAgentEngineTrace] {
   108	    await traces(projectID: projectID, threadID: nil)
   109	  }
   110
   111	  func issues(projectID: String) async -> [CoreAgentEngineIssue] {
   112	    await issues(projectID: projectID, status: nil)
   113	  }
   114	}
   115
   116	public struct CoreAgentEngineRedactionPolicy: Sendable {
   117	  public let identifier: String
   118	  private let redactor: @Sendable (String) -> String
   119
   120	  public init(
   121	    identifier: String = "custom",
   122	    _ redactor: @escaping @Sendable (String) -> String
   123	  ) {
   124	    self.identifier = identifier
   125	    self.redactor = redactor
   126	  }
   127
   128	  public func redact(_ value: String) -> String {
   129	    redactor(value)
   130	  }
   131
   132	  public func redacted(run: CoreAgentRun) -> CoreAgentRun {
   133	    CoreAgentRun(
   134	      id: run.id,
   135	      startedAt: run.startedAt,
   136	      endedAt: run.endedAt,
   137	      usage: run.usage,
   138	      events: run.events.map { event in
   139	        CoreAgentEvent(
   140	          id: event.id,
   141	          runID: event.runID,
   142	          timestamp: event.timestamp,
   143	          kind: event.kind,
   144	          message: redact(event.message),
   145	          attributes: redact(attributes: event.attributes)
   146	        )
   147	      }
   148	    )
   149	  }
   150
   151	  public static let standard = CoreAgentEngineRedactionPolicy(
   152	    identifier: "coreagent-engine-standard-redaction-v1"
   153	  ) { value in
   154	    var result = value
   155	    let patterns: [(String, String)] = [
   156	      (#"(?i)bearer\s+[a-z0-9._~+/=-]{1,256}"#, "Bearer [REDACTED]"),
   157	      (#"(?i)\bsk-[a-z0-9_-]{8,128}\b"#, "[REDACTED_API_KEY]"),
   158	      (
   159	        #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]{1,256}"#,
   160	        "$1=[REDACTED]"
   161	      ),
   162	    ]
   163	    for (pattern, replacement) in patterns {
   164	      result = result.replacingOccurrences(
   165	        of: pattern,
   166	        with: replacement,
   167	        options: .regularExpression
   168	      )
   169	    }
   170	    return result
   171	  }
   172
   173	  func redact(attributes: [String: String]) -> [String: String] {
   174	    let sensitiveMarkers = ["authorization", "api_key", "apikey", "token", "secret", "password"]
   175	    return attributes.reduce(into: [:]) { result, pair in
   176	      if sensitiveMarkers.contains(where: { pair.key.lowercased().contains($0) }) {
   177	        result[pair.key] = "[REDACTED]"
   178	      } else {
   179	        result[pair.key] = redactor(pair.value)
   180	      }
   181	    }
   182	  }
   183
   184	  func redact(run: CoreAgentRun) -> CoreAgentRun {
   185	    redacted(run: run)
   186	  }
   187	}
   188
   189	public actor InMemoryCoreAgentEngineStore: CoreAgentEngineStore {
   190	  private let redactionPolicy: CoreAgentEngineRedactionPolicy
   191	  private var tracesByKey: [TraceKey: StoredTrace] = [:]
   192	  private var issuesByID: [String: CoreAgentEngineIssue] = [:]
   193	  private var nextSequence = 0
   194
   195	  public init(redactionPolicy: CoreAgentEngineRedactionPolicy = .standard) {
   196	    self.redactionPolicy = redactionPolicy
   197	  }
   198
   199	  @discardableResult
   200	  public func ingest(
   201	    _ run: CoreAgentRun,
   202	    projectID: String,
   203	    threadID: String? = nil
   204	  ) async throws -> CoreAgentEngineTrace {
   205	    try validate(run)
   206	    let redactedRun = redactionPolicy.redact(run: run)
   207	    let trace = try CoreAgentEngineTrace(
   208	      projectID: projectID,
   209	      threadID: threadID,
   210	      run: redactedRun,
   211	      receipt: CoreAgentRunReceipt(run: redactedRun)
   212	    )
   213	    let sequence = nextSequence
   214	    nextSequence += 1
   215	    tracesByKey[TraceKey(projectID: projectID, runID: redactedRun.id)] = StoredTrace(
   216	      sequence: sequence,
   217	      trace: trace
   218	    )
   219	    return trace
   220	  }
   221
   222	  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
   223	    guard let trace = tracesByKey[TraceKey(projectID: projectID, runID: runID)]?.trace,
   224	      verified(trace)
   225	    else {
   226	      return nil
   227	    }
   228	    return trace
   229	  }
   230
   231	  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
   232	    tracesByKey.values
   233	      .filter {
   234	        $0.trace.projectID == projectID
   235	          && (threadID == nil || $0.trace.threadID == threadID)
   236	          && verified($0.trace)
   237	      }
   238	      .sorted { $0.sequence < $1.sequence }
   239	      .map(\.trace)
   240	  }
   241
   242	  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
   243	    if let existing = issuesByID[issue.id] {
   244	      guard existing.projectID == issue.projectID,
   245	        existing.fingerprint == issue.fingerprint
   246	      else {
   247	        throw CoreAgentEngineStoreError.issueIdentityMismatch(
   248	          issueID: issue.id,
   249	          existingProjectID: existing.projectID,
   250	          incomingProjectID: issue.projectID,
   251	          existingFingerprint: existing.fingerprint,
   252	          incomingFingerprint: issue.fingerprint
   253	        )
   254	      }
   255	      let existingRuns = Set(existing.contributingRunIDs)
   256	      let incomingRuns = Set(issue.contributingRunIDs)
   257	      let hasNewRuns = !incomingRuns.isSubset(of: existingRuns)
   258	      let mergedRunIDs = existing.contributingRunIDs
   259	        + issue.contributingRunIDs.filter { !existingRuns.contains($0) }
   260	      let nextStatus =
   261	        existing.status == .resolved && hasNewRuns
   262	        ? CoreAgentEngineIssueStatus.reopened
   263	        : existing.status
   264	      let merged = CoreAgentEngineIssue(
   265	        id: existing.id,
   266	        projectID: existing.projectID,
   267	        fingerprint: existing.fingerprint,
   268	        title: issue.title,
   269	        contributingRunIDs: mergedRunIDs,
   270	        status: nextStatus,

## CoreAgentApplePlatform.swift relevant excerpts
   430	        startedAt: trace.run.startedAt,
   431	        endedAt: trace.run.endedAt,
   432	        ingestedAt: trace.ingestedAt,
   433	        redactionPolicyIdentifier: redactionPolicyIdentifier,
   434	        encodedTrace: encodedTrace
   435	      )
   436	    )
   437	  }
   438
   439	  public init(
   440	    projectID: String,
   441	    threadID: String?,
   442	    runID: UUID,
   443	    startedAt: Date,
   444	    endedAt: Date,
   445	    ingestedAt: Date,
   446	    sequence: Int = 0,
   447	    traceScopeKey: String? = nil,
   448	    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier,
   449	    encodedTrace: Data,
   450	    traceDigest: String
   451	  ) {
   452	    self.traceScopeKey = traceScopeKey ?? Self.scopeKey(projectID: projectID, runID: runID)
   453	    self.projectID = projectID
   454	    self.threadID = threadID
   455	    self.runID = runID
   456	    self.startedAt = startedAt
   457	    self.endedAt = endedAt
   458	    self.ingestedAt = ingestedAt
   459	    self.sequence = sequence
   460	    self.redactionPolicyIdentifier = redactionPolicyIdentifier
   461	    self.encodedTrace = encodedTrace
   462	    self.traceDigest = traceDigest
   463	  }
   464
   465	  var trace: CoreAgentEngineTrace? {
   466	    guard traceScopeKey == Self.scopeKey(projectID: projectID, runID: runID) else {
   467	      return nil
   468	    }
   469	    guard traceDigest == Self.integrityDigest(
   470	      traceScopeKey: traceScopeKey,
   471	      projectID: projectID,
   472	      threadID: threadID,
   473	      runID: runID,
   474	      startedAt: startedAt,
   475	      endedAt: endedAt,
   476	      ingestedAt: ingestedAt,
   477	      redactionPolicyIdentifier: redactionPolicyIdentifier,
   478	      encodedTrace: encodedTrace
   479	    ) else {
   480	      return nil
   481	    }
   482	    guard let trace = try? CoreAgentSwiftDataEngineCodec.decode(
   483	      CoreAgentEngineTrace.self,
   484	      from: encodedTrace
   485	    ) else {
   486	      return nil
   487	    }
   488	    guard trace.projectID == projectID,
   489	      trace.threadID == threadID,
   490	      trace.run.id == runID,
   491	      trace.run.startedAt == startedAt,
   492	      trace.run.endedAt == endedAt,
   493	      trace.ingestedAt == ingestedAt,
   494	      trace.receipt.runID == trace.run.id,
   495	      trace.receipt.verify()
   496	    else {
   497	      return nil
   498	    }
   499	    return trace
   500	  }
   501
   502	  public static func scopeKey(projectID: String, runID: UUID) -> String {
   503	    let fields = [
   504	      projectID,
   505	      runID.uuidString.lowercased(),
   506	    ]
   507	    return "engine-trace-scope-sha256-v1:" + sha256Hex(framed(fields))
   508	  }
   509
   510	  static func integrityDigest(
   511	    traceScopeKey: String? = nil,
   512	    projectID: String,
   513	    threadID: String?,
   514	    runID: UUID,
   515	    startedAt: Date,
   516	    endedAt: Date,
   517	    ingestedAt: Date,
   518	    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier,
   519	    encodedTrace: Data
   520	  ) -> String {
   521	    let fields = [
   522	      traceScopeKey ?? Self.scopeKey(projectID: projectID, runID: runID),
   523	      projectID,
   524	      threadID ?? "nil",
   525	      runID.uuidString.lowercased(),
   526	      timeToken(startedAt),
   527	      timeToken(endedAt),
   528	      timeToken(ingestedAt),
   529	      redactionPolicyIdentifier,
   530	      sha256Hex(encodedTrace),
   531	    ]
   532	    return "sha256:" + sha256Hex(framed(fields))
   533	  }
   534	}
   535
   690	      }
   691	      modelContext.insert(record)
   692	      try modelContext.save()
   693	      return trace
   694	    } catch {
   695	      recoverAfterFailedMutation()
   696	      throw error
   697	    }
   698	  }
   699
   700	  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
   701	    guard let records = try? traceRecords(projectID: projectID, runID: runID) else {
   702	      return nil
   703	    }
   704	    return canonicalTraces(from: records).first
   705	  }
   706
   707	  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
   708	    guard let records = try? traceRecords(projectID: projectID, threadID: threadID) else {
   709	      return []
   710	    }
   711	    return canonicalTraces(from: records)
   712	  }
   713
   714	  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
   715	    let existingRecords = try issueRecords(issueID: issue.id)
   716	    let existingIssues = existingRecords.compactMap(\.issue)
   717	    try validateIssueIdentity(existingIssues, incoming: issue)
   718	    let storedIssue: CoreAgentEngineIssue
   719	    if let existing = canonicalIssues(from: existingIssues).first {
   720	      let existingRuns = Set(existing.contributingRunIDs)
   721	      let incomingRuns = Set(issue.contributingRunIDs)
   722	      let hasNewRuns = !incomingRuns.isSubset(of: existingRuns)
   723	      let mergedRunIDs = existing.contributingRunIDs
   724	        + issue.contributingRunIDs.filter { !existingRuns.contains($0) }
   725	      let nextStatus =
   726	        existing.status == .resolved && hasNewRuns
   727	        ? CoreAgentEngineIssueStatus.reopened
   728	        : existing.status
   729	      storedIssue = CoreAgentEngineIssue(
   730	        id: existing.id,
   731	        projectID: existing.projectID,
   732	        fingerprint: existing.fingerprint,
   733	        title: issue.title,
   734	        contributingRunIDs: mergedRunIDs,
   735	        status: nextStatus,
   736	        firstSeenAt: min(existing.firstSeenAt, issue.firstSeenAt),
   737	        lastSeenAt: max(existing.lastSeenAt, issue.lastSeenAt)
   738	      )
   739	    } else {
   740	      storedIssue = issue
   741	    }
   742	    let storedRecord = try CoreAgentSwiftDataEngineIssueRecord(issue: storedIssue)
   743	    do {
   744	      for record in existingRecords {
   745	        modelContext.delete(record)
   746	      }
   747	      modelContext.insert(storedRecord)
   748	      try modelContext.save()
   749	      return storedIssue
   750	    } catch {
   751	      recoverAfterFailedMutation()
   752	      throw error
   753	    }
   754	  }
   755
   756	  public func updateIssueStatus(
   757	    _ issueID: String,
   758	    status: CoreAgentEngineIssueStatus
   759	  ) async throws {
   760	    let existingRecords = try issueRecords(issueID: issueID)
   860	      sortBy: [
   861	        SortDescriptor(\.firstSeenAt),
   862	        SortDescriptor(\.fingerprint),
   863	      ]
   864	    )
   865	    return try modelContext.fetch(descriptor)
   866	  }
   867
   868	  private func nextTraceSequence() throws -> Int {
   869	    var descriptor = FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>(
   870	      sortBy: [SortDescriptor(\.sequence, order: .reverse)]
   871	    )
   872	    descriptor.fetchLimit = 1
   873	    return ((try modelContext.fetch(descriptor).first?.sequence) ?? -1) + 1
   874	  }
   875
   876	  private func verifiedTraceSnapshot(
   877	    from record: CoreAgentSwiftDataEngineTraceRecord
   878	  ) -> VerifiedTraceSnapshot? {
   879	    guard let trace = record.trace,
   880	      record.redactionPolicyIdentifier == redactionPolicy.identifier,
   881	      redactionPolicy.redacted(run: trace.run) == trace.run
   882	    else {
   883	      return nil
   884	    }
   885	    return VerifiedTraceSnapshot(
   886	      scopeKey: CoreAgentSwiftDataEngineTraceRecord.scopeKey(
   887	        projectID: trace.projectID,
   888	        runID: trace.run.id
   889	      ),
   890	      sequence: record.sequence,
   891	      ingestedAt: record.ingestedAt,
   892	      runID: record.runID,
   893	      trace: trace
   894	    )
   895	  }
   896
   897	  private func canonicalTraces(
   898	    from records: [CoreAgentSwiftDataEngineTraceRecord]
   899	  ) -> [CoreAgentEngineTrace] {
   900	    var winners: [String: VerifiedTraceSnapshot] = [:]
   901	    for record in records {
   902	      guard let candidate = verifiedTraceSnapshot(from: record) else {
   903	        continue
   904	      }
   905	      guard let existing = winners[candidate.scopeKey] else {
   906	        winners[candidate.scopeKey] = candidate
   907	        continue
   908	      }
   909	      if candidate.isNewer(than: existing) {
   910	        winners[candidate.scopeKey] = candidate
   911	      }
   912	    }
   913	    return winners.values
   914	      .sorted { lhs, rhs in
   915	        if lhs.sequence != rhs.sequence {
   916	          return lhs.sequence < rhs.sequence
   917	        }
   918	        if lhs.ingestedAt != rhs.ingestedAt {
   919	          return lhs.ingestedAt < rhs.ingestedAt
   920	        }
   921	        return lhs.runID.uuidString < rhs.runID.uuidString
   922	      }
   923	      .map(\.trace)
   924	  }
   925
   926	  private func canonicalIssues(from issues: [CoreAgentEngineIssue]) -> [CoreAgentEngineIssue] {
   927	    var winners: [String: CoreAgentEngineIssue] = [:]
   928	    for candidate in issues {
   929	      guard let existing = winners[candidate.id] else {
   930	        winners[candidate.id] = candidate
   931	        continue
   932	      }
   933	      winners[candidate.id] = existing.mergedEngineIssueDuplicate(with: candidate)
   934	    }
   935	    return winners.values.sorted { lhs, rhs in
   936	      if lhs.firstSeenAt != rhs.firstSeenAt {
   937	        return lhs.firstSeenAt < rhs.firstSeenAt
   938	      }
   939	      return lhs.fingerprint < rhs.fingerprint
   940	    }
   941	  }
   942
   943	  private func validateIssueIdentity(
   944	    _ existingIssues: [CoreAgentEngineIssue],
   945	    incoming issue: CoreAgentEngineIssue
   946	  ) throws {
   947	    for existing in existingIssues {
   948	      guard existing.projectID == issue.projectID,
   949	        existing.fingerprint == issue.fingerprint
   950	      else {
   951	        throw CoreAgentEngineStoreError.issueIdentityMismatch(
   952	          issueID: issue.id,
   953	          existingProjectID: existing.projectID,
   954	          incomingProjectID: issue.projectID,
   955	          existingFingerprint: existing.fingerprint,
   956	          incomingFingerprint: issue.fingerprint
   957	        )
   958	      }
   959	    }
   960	  }
   961
   962	  private func validate(_ run: CoreAgentRun) throws {
   963	    guard run.events.contains(where: { $0.kind == .runCompleted || $0.kind == .runFailed })
   964	    else {
   965	      throw CoreAgentEngineStoreError.nonFinalizedRun(run.id)
   966	    }
   967	    for event in run.events where event.runID != run.id {
   968	      throw CoreAgentEngineStoreError.eventRunIDMismatch(
   969	        eventRunID: event.runID,
   970	        runID: run.id
   971	      )
   972	    }
   973	  }
   974
   975	  private func recoverAfterFailedMutation() {
   976	    guard rollsBackOnFailure else {
   977	      return
   978	    }
   979	    modelContext.rollback()
   980	  }

## Tests relevant excerpts
   145	    let scanner = CoreAgentEngineIssueScanner(store: store)
   146	    let issues = try await scanner.scan(projectID: "coreagent")
   147
   148	    #expect(issues.map(\.contributingRunIDs) == [
   149	      [Self.uuid(401), Self.uuid(402)],
   150	      [Self.uuid(403)],
   151	    ])
   152	    #expect(issues.map(\.status) == [.open, .open])
   153	    #expect(issues.map(\.fingerprint) == [
   154	      "9:runFailed|13:authorization|10:write_file",
   155	      "9:runFailed|7:timeout|7:browser",
   156	    ])
   157	  }
   158
   159	  @Test("Resolved issues reopen when a new contributing run appears")
   160	  func resolvedIssuesReopenWhenNewContributingRunAppears() async throws {
   161	    let store = InMemoryCoreAgentEngineStore()
   162	    let scanner = CoreAgentEngineIssueScanner(store: store)
   163	    try await store.ingest(
   164	      Self.failedRun(id: Self.uuid(451), errorType: "authorization", tool: "write_file"),
   165	      projectID: "coreagent"
   166	    )
   167	    let first = try #require(try await scanner.scan(projectID: "coreagent").first)
   168	    try await store.updateIssueStatus(first.id, status: .resolved)
   169	    try await store.ingest(
   170	      Self.failedRun(id: Self.uuid(452), errorType: "authorization", tool: "write_file"),
   171	      projectID: "coreagent"
   172	    )
   173
   174	    let rescanned = try #require(try await scanner.scan(projectID: "coreagent").first)
   175
   176	    #expect(rescanned.status == .reopened)
   177	    #expect(rescanned.contributingRunIDs == [Self.uuid(451), Self.uuid(452)])
   178	  }
   179
   180	  @Test("Issue upserts merge contributing run provenance")
   181	  func issueUpsertsMergeContributingRunProvenance() async throws {
   182	    let store = InMemoryCoreAgentEngineStore()
   183	    let issue = CoreAgentEngineIssue(
   184	      id: "issue-partial",
   185	      projectID: "coreagent",
   186	      fingerprint: "fingerprint",
   187	      title: "First",
   188	      contributingRunIDs: [Self.uuid(461)],
   189	      status: .resolved,
   190	      firstSeenAt: Date(timeIntervalSince1970: 100),
   191	      lastSeenAt: Date(timeIntervalSince1970: 200)
   192	    )
   193	    _ = try await store.upsertIssue(issue)
   194
   195	    let merged = try await store.upsertIssue(CoreAgentEngineIssue(
   196	      id: "issue-partial",
   197	      projectID: "coreagent",
   198	      fingerprint: "fingerprint",
   199	      title: "Second",
   200	      contributingRunIDs: [Self.uuid(462)],
   201	      status: .open,
   202	      firstSeenAt: Date(timeIntervalSince1970: 150),
   203	      lastSeenAt: Date(timeIntervalSince1970: 300)
   204	    ))
   205
   206	    #expect(merged.status == .reopened)
   207	    #expect(merged.contributingRunIDs == [Self.uuid(461), Self.uuid(462)])
   208	    #expect(merged.firstSeenAt == Date(timeIntervalSince1970: 100))
   209	    #expect(merged.lastSeenAt == Date(timeIntervalSince1970: 300))
   210	  }
   211
   212	  @Test("Issue upserts reject project or fingerprint identity collisions")
   213	  func issueUpsertsRejectProjectOrFingerprintIdentityCollisions() async throws {
   214	    let store = InMemoryCoreAgentEngineStore()
   215	    _ = try await store.upsertIssue(CoreAgentEngineIssue(
   216	      id: "issue-collision",
   217	      projectID: "coreagent",
   218	      fingerprint: "fingerprint-a",
   219	      title: "First",
   220	      contributingRunIDs: [Self.uuid(471)],
   221	      status: .open,
   222	      firstSeenAt: Date(timeIntervalSince1970: 100),
   223	      lastSeenAt: Date(timeIntervalSince1970: 200)
   224	    ))
   225
   226	    await #expect(throws: CoreAgentEngineStoreError.issueIdentityMismatch(
   227	      issueID: "issue-collision",
   228	      existingProjectID: "coreagent",
   229	      incomingProjectID: "other",
   230	      existingFingerprint: "fingerprint-a",
   231	      incomingFingerprint: "fingerprint-b"
   232	    )) {
   233	      _ = try await store.upsertIssue(CoreAgentEngineIssue(
   234	        id: "issue-collision",
   235	        projectID: "other",
   236	        fingerprint: "fingerprint-b",
   237	        title: "Collision",
   238	        contributingRunIDs: [Self.uuid(472)],
   239	        status: .open,
   240	        firstSeenAt: Date(timeIntervalSince1970: 300),
  1340	      runID: unredactedRunID,
  1341	      startedAt: unredactedRun.startedAt,
  1342	      endedAt: unredactedRun.endedAt,
  1343	      ingestedAt: unredactedTrace.ingestedAt,
  1344	      encodedTrace: unredactedData,
  1345	      traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
  1346	        projectID: "coreagent",
  1347	        threadID: "thread-a",
  1348	        runID: unredactedRunID,
  1349	        startedAt: unredactedRun.startedAt,
  1350	        endedAt: unredactedRun.endedAt,
  1351	        ingestedAt: unredactedTrace.ingestedAt,
  1352	        encodedTrace: unredactedData
  1353	      )
  1354	    ))
  1355	    try context.save()
  1356
  1357	    #expect(await store.trace(projectID: "coreagent", runID: redactedRunID) == nil)
  1358	    #expect(await store.trace(projectID: "coreagent", runID: unredactedRunID) == nil)
  1359	    #expect(await store.traces(projectID: "coreagent").isEmpty)
  1360	  }
  1361
  1362	  @MainActor
  1363	  @Test("SwiftData Engine store rejects trace rows from a mismatched redaction policy")
  1364	  func swiftDataEngineStoreRejectsTraceRowsFromMismatchedRedactionPolicy() async throws {
  1365	    let context = try Self.swiftDataEngineContext()
  1366	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1367	    let runID = Self.uuid(744)
  1368	    let run = CoreAgentEngineRedactionPolicy.standard.redacted(run: Self.engineRun(
  1369	      id: runID,
  1370	      events: [
  1371	        Self.event(
  1372	          runID: runID,
  1373	          kind: .runFailed,
  1374	          message: "Failed with token=canary-not-a-token-regex",
  1375	          attributes: ["api_key": "canary-not-a-token-regex"]
  1376	        )
  1377	      ]
  1378	    ))
  1379	    let trace = try CoreAgentEngineTrace(
  1380	      projectID: "coreagent",
  1381	      threadID: "thread-a",
  1382	      run: run,
  1383	      receipt: CoreAgentRunReceipt(run: run),
  1384	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_022)
  1385	    )
  1386	    context.insert(try Self.engineTraceRecord(
  1387	      trace,
  1388	      redactionPolicyIdentifier: "custom-redaction-policy-v2"
  1389	    ))
  1390	    try context.save()
  1391
  1392	    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
  1393	    #expect(await store.traces(projectID: "coreagent").isEmpty)
  1394	  }
  1395
  1396	  @MainActor
  1397	  @Test("SwiftData Engine trace records bind indexed sidecar metadata into integrity")
  1398	  func swiftDataEngineTraceRecordsBindIndexedSidecarMetadataIntoIntegrity() async throws {
  1399	    let context = try Self.swiftDataEngineContext()
  1400	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1401	    let baseRunID = Self.uuid(734)
  1402	    let baseRun = Self.engineRun(id: baseRunID)
  1403	    let baseTrace = try CoreAgentEngineTrace(
  1404	      projectID: "encoded-project",
  1405	      threadID: "encoded-thread",
  1406	      run: baseRun,
  1407	      receipt: CoreAgentRunReceipt(run: baseRun),
  1408	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_030.123456)
  1409	    )
  1410	    let encodedTraceData = try Self.engineTraceData(baseTrace)
  1411	    let sidecarProjectID = "coreagent"
  1412	    let sidecarThreadID = "thread-a"
  1413	    let sidecarIngestedAt = Date(timeIntervalSince1970: 1_800_000_031.654321)
  1414
  1415	    context.insert(CoreAgentSwiftDataEngineTraceRecord(
  1416	      projectID: sidecarProjectID,
  1417	      threadID: sidecarThreadID,
  1418	      runID: baseRunID,
  1419	      startedAt: baseRun.startedAt,
  1420	      endedAt: baseRun.endedAt,
  1421	      ingestedAt: sidecarIngestedAt,
  1422	      encodedTrace: encodedTraceData,
  1423	      traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
  1424	        projectID: sidecarProjectID,
  1425	        threadID: sidecarThreadID,
  1426	        runID: baseRunID,
  1427	        startedAt: baseRun.startedAt,
  1428	        endedAt: baseRun.endedAt,
  1429	        ingestedAt: sidecarIngestedAt,
  1430	        encodedTrace: encodedTraceData
  1431	      )
  1432	    ))
  1433
  1434	    let digestRunID = Self.uuid(735)
  1435	    let digestRun = Self.engineRun(id: digestRunID)
  1436	    let digestTrace = try CoreAgentEngineTrace(
  1437	      projectID: sidecarProjectID,
  1438	      threadID: sidecarThreadID,
  1439	      run: digestRun,
  1440	      receipt: CoreAgentRunReceipt(run: digestRun),
  1441	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_032)
  1442	    )
  1443	    let digestData = try Self.engineTraceData(digestTrace)
  1444	    context.insert(CoreAgentSwiftDataEngineTraceRecord(
  1445	      projectID: sidecarProjectID,
  1446	      threadID: sidecarThreadID,
  1447	      runID: digestRunID,
  1448	      startedAt: digestRun.startedAt,
  1449	      endedAt: digestRun.endedAt,
  1450	      ingestedAt: digestTrace.ingestedAt,
  1451	      encodedTrace: digestData,
  1452	      traceDigest: "sha256:stale"
  1453	    ))
  1454	    try context.save()
  1455
  1456	    #expect(await store.trace(projectID: sidecarProjectID, runID: baseRunID) == nil)
  1457	    #expect(await store.trace(projectID: sidecarProjectID, runID: digestRunID) == nil)
  1458	    #expect(await store.traces(projectID: sidecarProjectID).isEmpty)
  1459	  }
  1460
  1461	  @MainActor
  1462	  @Test("SwiftData Engine trace records reject forged scope keys")
  1463	  func swiftDataEngineTraceRecordsRejectForgedScopeKeys() async throws {
  1464	    let context = try Self.swiftDataEngineContext()
  1465	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1466	    let runID = Self.uuid(749)
  1467	    let run = Self.engineRun(id: runID)
  1468	    let trace = try CoreAgentEngineTrace(
  1469	      projectID: "coreagent",
  1470	      threadID: "thread-a",
  1471	      run: run,
  1472	      receipt: CoreAgentRunReceipt(run: run),
  1473	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_043)
  1474	    )
  1475	    context.insert(try Self.engineTraceRecord(
  1476	      trace,
  1477	      sequence: 3,
  1478	      traceScopeKey: "engine-trace-scope-sha256-v1:forged"
  1479	    ))
  1480	    try context.save()
  1481
  1482	    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
  1483	    #expect(await store.traces(projectID: "coreagent").isEmpty)
  1484	  }
  1485
  1486	  @MainActor
  1487	  @Test("SwiftData Engine store collapses duplicate valid trace rows on readback")
  1488	  func swiftDataEngineStoreCollapsesDuplicateValidTraceRowsOnReadback() async throws {
  1489	    let context = try Self.swiftDataEngineContext()
  1490	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1491	    let runID = Self.uuid(745)
  1492	    let olderRun = Self.engineRun(
  1493	      id: runID,
  1494	      events: [
  1495	        Self.event(runID: runID, kind: .runCompleted, message: "older trace")
  1496	      ]
  1497	    )
  1498	    let newerRun = Self.engineRun(
  1499	      id: runID,
  1500	      events: [
  1501	        Self.event(runID: runID, kind: .runCompleted, message: "newer trace")
  1502	      ]
  1503	    )
  1504	    let olderTrace = try CoreAgentEngineTrace(
  1505	      projectID: "coreagent",
  1506	      threadID: "thread-a",
  1507	      run: olderRun,
  1508	      receipt: CoreAgentRunReceipt(run: olderRun),
  1509	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_040)
  1510	    )
  1511	    let newerTrace = try CoreAgentEngineTrace(
  1512	      projectID: "coreagent",
  1513	      threadID: "thread-a",
  1514	      run: newerRun,
  1515	      receipt: CoreAgentRunReceipt(run: newerRun),
  1516	      ingestedAt: Date(timeIntervalSince1970: 1_800_000_041)
  1517	    )
  1518	    context.insert(try Self.engineTraceRecord(olderTrace, sequence: 0))
  1519	    context.insert(try Self.engineTraceRecord(newerTrace, sequence: 5))
  1520	    try context.save()
  1521
  1522	    let exact = try #require(await store.trace(projectID: "coreagent", runID: runID))
  1523	    let projectTraces = await store.traces(projectID: "coreagent")
  1524
  1525	    #expect(exact.run.events.first?.message == "newer trace")
  1526	    #expect(projectTraces.map(\.run.id) == [runID])
  1527	    #expect(projectTraces.first?.run.events.first?.message == "newer trace")
  1528	  }
  1529
  1530	  @MainActor
  1531	  @Test("SwiftData Engine store scopes traces by project plus run ID")
  1532	  func swiftDataEngineStoreScopesTracesByProjectAndRunID() async throws {
  1533	    let context = try Self.swiftDataEngineContext()
  1534	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1535	    let runID = Self.uuid(736)
  1610	      contributingRunIDs: [firstRunID, secondRunID],
  1611	      status: .open,
  1612	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1613	      lastSeenAt: Date(timeIntervalSince1970: 400)
  1614	    )
  1615
  1616	    let stored = try await store.upsertIssue(incomingIssue)
  1617	    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())
  1618
  1619	    #expect(stored.status == .ignored)
  1620	    #expect(stored.title == "Latest title")
  1621	    #expect(stored.contributingRunIDs == [firstRunID, secondRunID])
  1622	    #expect(stored.firstSeenAt == Date(timeIntervalSince1970: 100))
  1623	    #expect(stored.lastSeenAt == Date(timeIntervalSince1970: 400))
  1624	    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
  1625	    #expect(await store.issues(projectID: "coreagent", status: .ignored).map(\.id) == [issueID])
  1626	  }
  1627
  1628	  @MainActor
  1629	  @Test("SwiftData Engine store merges issue run provenance and rejects identity collisions")
  1630	  func swiftDataEngineStoreMergesIssueRunProvenanceAndRejectsIdentityCollisions() async throws {
  1631	    let context = try Self.swiftDataEngineContext()
  1632	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1633	    let issue = CoreAgentEngineIssue(
  1634	      id: "issue-partial-swiftdata",
  1635	      projectID: "coreagent",
  1636	      fingerprint: "fingerprint",
  1637	      title: "First",
  1638	      contributingRunIDs: [Self.uuid(750)],
  1639	      status: .resolved,
  1640	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1641	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1642	    )
  1643	    _ = try await store.upsertIssue(issue)
  1644
  1645	    let merged = try await store.upsertIssue(CoreAgentEngineIssue(
  1646	      id: "issue-partial-swiftdata",
  1647	      projectID: "coreagent",
  1648	      fingerprint: "fingerprint",
  1649	      title: "Second",
  1650	      contributingRunIDs: [Self.uuid(751)],
  1651	      status: .open,
  1652	      firstSeenAt: Date(timeIntervalSince1970: 150),
  1653	      lastSeenAt: Date(timeIntervalSince1970: 300)
  1654	    ))
  1655
  1656	    #expect(merged.status == .reopened)
  1657	    #expect(merged.contributingRunIDs == [Self.uuid(750), Self.uuid(751)])
  1658
  1659	    await #expect(throws: CoreAgentEngineStoreError.issueIdentityMismatch(
  1660	      issueID: "issue-partial-swiftdata",
  1661	      existingProjectID: "coreagent",
  1662	      incomingProjectID: "other",
  1663	      existingFingerprint: "fingerprint",
  1664	      incomingFingerprint: "other-fingerprint"
  1665	    )) {
  1666	      _ = try await store.upsertIssue(CoreAgentEngineIssue(
  1667	        id: "issue-partial-swiftdata",
  1668	        projectID: "other",
  1669	        fingerprint: "other-fingerprint",
  1670	        title: "Collision",
  1671	        contributingRunIDs: [Self.uuid(752)],
  1672	        status: .open,
  1673	        firstSeenAt: Date(timeIntervalSince1970: 400),
  1674	        lastSeenAt: Date(timeIntervalSince1970: 500)
  1675	      ))
  1676	    }
  1677	  }
  1678
  1679	  @MainActor
  1680	  @Test("SwiftData Engine store ignores corrupt issue duplicates before lifecycle updates")
  1681	  func swiftDataEngineStoreIgnoresCorruptIssueDuplicatesBeforeLifecycleUpdates() async throws {
  1682	    let context = try Self.swiftDataEngineContext()
  1683	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1684	    let issueID = "issue-corrupt-shadow"
  1685	    let validIssue = CoreAgentEngineIssue(
  1686	      id: issueID,
  1687	      projectID: "coreagent",
  1688	      fingerprint: "fingerprint",
  1689	      title: "Valid issue",
  1690	      contributingRunIDs: [Self.uuid(746)],
  1691	      status: .resolved,
  1692	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1693	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1694	    )
  1695	    let corruptIssue = CoreAgentEngineIssue(
  1696	      id: issueID,
  1697	      projectID: "coreagent",
  1698	      fingerprint: "fingerprint",
  1699	      title: "Corrupt issue",
  1700	      contributingRunIDs: [Self.uuid(746), Self.uuid(747)],
  1701	      status: .open,
  1702	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1703	      lastSeenAt: Date(timeIntervalSince1970: 300)
  1704	    )
  1705	    context.insert(try Self.engineIssueRecord(validIssue))
  1706	    context.insert(try Self.engineIssueRecord(corruptIssue, issueDigest: "sha256:corrupt"))
  1707	    try context.save()
  1708
  1709	    let incoming = CoreAgentEngineIssue(
  1710	      id: issueID,
  1711	      projectID: "coreagent",
  1712	      fingerprint: "fingerprint",
  1713	      title: "Incoming issue",
  1714	      contributingRunIDs: [Self.uuid(746), Self.uuid(747)],
  1715	      status: .open,
  1716	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1717	      lastSeenAt: Date(timeIntervalSince1970: 300)
  1718	    )
  1719	    let reopened = try await store.upsertIssue(incoming)
  1720	    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())
  1721
  1722	    #expect(reopened.status == .reopened)
  1723	    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
  1724	    #expect(await store.issues(projectID: "coreagent", status: .reopened).map(\.id) == [
  1725	      issueID
  1726	    ])
  1727	  }
  1728
  1729	  @MainActor
  1730	  @Test("SwiftData Engine store collapses duplicate valid issues before status filtering")
  1731	  func swiftDataEngineStoreCollapsesDuplicateValidIssuesBeforeStatusFiltering() async throws {
  1732	    let context = try Self.swiftDataEngineContext()
  1733	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1734	    let issueID = "issue-valid-duplicate"
  1735	    let openIssue = CoreAgentEngineIssue(
  1736	      id: issueID,
  1737	      projectID: "coreagent",
  1738	      fingerprint: "fingerprint",
  1739	      title: "Open issue",
  1740	      contributingRunIDs: [Self.uuid(748)],
  1741	      status: .open,
  1742	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1743	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1744	    )
  1745	    let resolvedIssue = CoreAgentEngineIssue(
  1746	      id: issueID,
  1747	      projectID: "coreagent",
  1748	      fingerprint: "fingerprint",
  1749	      title: "Resolved issue",
  1750	      contributingRunIDs: [Self.uuid(749)],
  1751	      status: .resolved,
  1752	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1753	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1754	    )
  1755	    context.insert(try Self.engineIssueRecord(openIssue))
  1756	    context.insert(try Self.engineIssueRecord(resolvedIssue))
  1757	    try context.save()
  1758
  1759	    let issuesBeforeUpsert = await store.issues(projectID: "coreagent")
  1760	    #expect(issuesBeforeUpsert.map(\.status) == [.resolved])
  1761	    #expect(issuesBeforeUpsert.first?.contributingRunIDs == [
  1762	      Self.uuid(748),
  1763	      Self.uuid(749),
  1764	    ])
  1765	    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
  1766	    #expect(await store.issues(projectID: "coreagent", status: .resolved).map(\.id) == [
  1767	      issueID
  1768	    ])
  1769
  1770	    let collapsed = try await store.upsertIssue(CoreAgentEngineIssue(
  1771	      id: issueID,
  1772	      projectID: "coreagent",
  1773	      fingerprint: "fingerprint",
  1774	      title: "Reopened issue",
  1775	      contributingRunIDs: [Self.uuid(752)],
  1776	      status: .open,
  1777	      firstSeenAt: Date(timeIntervalSince1970: 150),
  1778	      lastSeenAt: Date(timeIntervalSince1970: 300)
  1779	    ))
  1780	    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())
  1781
  1782	    #expect(collapsed.status == .reopened)
  1783	    #expect(collapsed.contributingRunIDs == [Self.uuid(748), Self.uuid(749), Self.uuid(752)])
  1784	    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
  1785	  }
  1786
  1787	  @MainActor
  1788	  @Test("SwiftData Engine issue records fail closed on corrupted sidecar fields")
  1789	  func swiftDataEngineIssueRecordsFailClosedOnCorruptedSidecarFields() async throws {
  1790	    let context = try Self.swiftDataEngineContext()
  1791	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1792	    let issue = CoreAgentEngineIssue(
  1793	      id: "issue-corrupt",
  1794	      projectID: "coreagent",
  1795	      fingerprint: "fingerprint",
