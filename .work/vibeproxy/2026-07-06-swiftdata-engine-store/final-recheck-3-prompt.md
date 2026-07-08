Final verification check for SwiftData Engine store blockers. Verify only: traceScopeKey fail-closed behavior, issue run provenance union across duplicate rows and partial upserts, and issueID project/fingerprint collision fail-closed behavior. Return VERDICT: PASS or BLOCK; if BLOCK, list only unresolved defects in those areas.

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
   927	    var winners: [CoreAgentEngineIssue] = []
   928	    let groupedIssues = Dictionary(grouping: issues, by: \.id)
   929	    for group in groupedIssues.values {
   930	      guard var winner = group.first,
   931	        group.allSatisfy({
   932	          $0.projectID == winner.projectID && $0.fingerprint == winner.fingerprint
   933	        })
   934	      else {
   935	        continue
   936	      }
   937	      for candidate in group.dropFirst() {
   938	        winner = winner.mergedEngineIssueDuplicate(with: candidate)
   939	      }
   940	      winners.append(winner)
   941	    }
   942	    return winners.sorted { lhs, rhs in
   943	      if lhs.firstSeenAt != rhs.firstSeenAt {
   944	        return lhs.firstSeenAt < rhs.firstSeenAt
   945	      }
   946	      return lhs.fingerprint < rhs.fingerprint
   947	    }
   948	  }
   949
   950	  private func validateIssueIdentity(
   951	    _ existingIssues: [CoreAgentEngineIssue],
   952	    incoming issue: CoreAgentEngineIssue
   953	  ) throws {
   954	    for existing in existingIssues {
   955	      guard existing.projectID == issue.projectID,
   956	        existing.fingerprint == issue.fingerprint
   957	      else {
   958	        throw CoreAgentEngineStoreError.issueIdentityMismatch(
   959	          issueID: issue.id,
   960	          existingProjectID: existing.projectID,
   961	          incomingProjectID: issue.projectID,
   962	          existingFingerprint: existing.fingerprint,
   963	          incomingFingerprint: issue.fingerprint
   964	        )
   965	      }
   966	    }
   967	  }
   968
   969	  private func validate(_ run: CoreAgentRun) throws {
   970	    guard run.events.contains(where: { $0.kind == .runCompleted || $0.kind == .runFailed })
   971	    else {
   972	      throw CoreAgentEngineStoreError.nonFinalizedRun(run.id)
   973	    }
   974	    for event in run.events where event.runID != run.id {
   975	      throw CoreAgentEngineStoreError.eventRunIDMismatch(
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
  1788	  @Test("SwiftData Engine store fails closed on valid issue identity collisions")
  1789	  func swiftDataEngineStoreFailsClosedOnValidIssueIdentityCollisions() async throws {
  1790	    let context = try Self.swiftDataEngineContext()
  1791	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
  1792	    let first = CoreAgentEngineIssue(
  1793	      id: "issue-read-collision",
  1794	      projectID: "coreagent",
  1795	      fingerprint: "fingerprint-a",
  1796	      title: "First issue",
  1797	      contributingRunIDs: [Self.uuid(753)],
  1798	      status: .open,
  1799	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1800	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1801	    )
  1802	    let second = CoreAgentEngineIssue(
  1803	      id: "issue-read-collision",
  1804	      projectID: "coreagent",
  1805	      fingerprint: "fingerprint-b",
  1806	      title: "Second issue",
  1807	      contributingRunIDs: [Self.uuid(754)],
  1808	      status: .resolved,
  1809	      firstSeenAt: Date(timeIntervalSince1970: 100),
  1810	      lastSeenAt: Date(timeIntervalSince1970: 200)
  1811	    )
  1812	    context.insert(try Self.engineIssueRecord(first))
  1813	    context.insert(try Self.engineIssueRecord(second))
  1814	    try context.save()
  1815
  1816	    #expect(await store.issues(projectID: "coreagent").isEmpty)
  1817	    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
  1818	    #expect(await store.issues(projectID: "coreagent", status: .resolved).isEmpty)
  1819	  }
  1820
  1821	  @MainActor
  1822	  @Test("SwiftData Engine issue records fail closed on corrupted sidecar fields")
  1823	  func swiftDataEngineIssueRecordsFailClosedOnCorruptedSidecarFields() async throws {
  1824	    let context = try Self.swiftDataEngineContext()
  1825	    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
