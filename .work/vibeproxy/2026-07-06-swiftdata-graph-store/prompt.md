You are reviewing a Swift 6.4 / Xcode 27 CoreAgent package slice.

Scope: L16 live Apple SwiftData graph checkpoint and graph key/value stores. The code adds SwiftData @Model records for CoreAgentGraph checkpoints and store records, plus generic ModelContext-backed CoreAgentSwiftDataGraphCheckpointer<State: Codable & Sendable> and CoreAgentSwiftDataGraphStore<Value: Codable & Sendable>.

Review priorities:
- SwiftData ModelContext actor isolation and generic Sendable/Codable API shape.
- Checkpoint parity with InMemoryCoreAgentGraphCheckpointer: save, checkpoint(id), latest, history, thread/namespace isolation, parent lineage, duplicate checkpoint ID behavior.
- Graph store parity with InMemoryCoreAgentGraphStore: namespace/key isolation, replacement, removal, stable keys.
- Digest/readback integrity: sidecar metadata binding, corrupt rows fail closed, canonical encoded payload remains authoritative.
- Swift Testing coverage quality; identify realistic missing regressions.

Return:
VERDICT: PASS or BLOCK
FINDINGS: only actionable correctness/security/data-integrity issues with severity P1/P2/P3 and concrete fix.
TEST GAPS: only gaps that would catch realistic regressions in this slice.

# SwiftData Graph Store Review Context

## Package.swift target dependency excerpt
    50	      exact: "0.1.2"
    51	    ),
    52	    .package(
    53	      url: "https://github.com/firebase/firebase-ios-sdk.git",
    54	      revision: "eb640a7bd9f8f4e4843e61c12a24c0abe4044443"
    55	    ),
    56	  ],
    57	  targets: [
    58	    .target(name: "CoreAgent"),
    59	    .target(
    60	      name: "CoreAgentApplePlatform",
    61	      dependencies: ["CoreAgent", "CoreAgentEngine", "CoreAgentGraph"]
    62	    ),
    63	    .target(
    64	      name: "CoreAgentDeep",
    65	      dependencies: ["CoreAgent", "CoreAgentGraph"]
    66	    ),
    67	    .target(
    68	      name: "CoreAgentEngine",
    69	      dependencies: ["CoreAgent"]
    70	    ),
    71	    .target(
    72	      name: "CoreAgentGraph",
    73	      dependencies: ["CoreAgent"]
    74	    ),
    75	    .target(
    76	      name: "CoreAgentMemory",
    77	      dependencies: ["CoreAgent"],
    78	      linkerSettings: [.linkedLibrary("sqlite3")]
    79	    ),
    80	    .target(
    81	      name: "CoreAgentSkills",
    82	      dependencies: ["CoreAgent"]
    83	    ),
    84	    .target(
    85	      name: "CoreAgentTestSupport",
    86	      dependencies: ["CoreAgent"]
    87	    ),
    88	    .target(
    89	      name: "CoreAgentProviders",
    90	      dependencies: [
    91	        "CoreAgent",
    92	        .product(
    93	          name: "FoundationModelsUtilities",
    94	          package: "foundation-models-utilities",
    95	          condition: .when(traits: ["AppleUtilities"])
    96	        ),
    97	        .product(
    98	          name: "ClaudeForFoundationModels",
    99	          package: "ClaudeForFoundationModels",
   100	          condition: .when(traits: ["Claude"])
   101	        ),
   102	        .product(
   103	          name: "FirebaseAILogic",
   104	          package: "firebase-ios-sdk",
   105	          condition: .when(traits: ["Gemini"])
   106	        ),
   107	      ],
   108	      swiftSettings: [
   109	        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
   110	        .define("COREAGENT_CLAUDE", .when(traits: ["Claude"])),
   111	        .define("COREAGENT_GEMINI", .when(traits: ["Gemini"])),
   112	      ]
   113	    ),
   114	    .testTarget(
   115	      name: "CoreAgentTests",
   116	      dependencies: ["CoreAgent", "CoreAgentTestSupport"]
   117	    ),
   118	    .testTarget(
   119	      name: "CoreAgentApplePlatformTests",
   120	      dependencies: [
   121	        "CoreAgent",
   122	        "CoreAgentApplePlatform",
   123	        "CoreAgentEngine",
   124	        "CoreAgentGraph",
   125	        "CoreAgentTestSupport",
   126	      ]
   127	    ),
   128	    .testTarget(
   129	      name: "CoreAgentProviderTests",
   130	      dependencies: ["CoreAgent", "CoreAgentProviders"],

## Sources/CoreAgentGraph/CoreAgentGraphCheckpoints.swift
    70	    CoreAgentGraphCheckpointID(UUID().uuidString.lowercased())
    71	  }
    72	}
    73
    74	public struct CoreAgentGraphPendingWrite<State: Sendable>: Sendable {
    75	  public let nodeID: CoreAgentGraphNodeID
    76	  public let step: Int
    77	  public let update: State
    78
    79	  public init(
    80	    nodeID: CoreAgentGraphNodeID,
    81	    step: Int,
    82	    update: State
    83	  ) {
    84	    self.nodeID = nodeID
    85	    self.step = step
    86	    self.update = update
    87	  }
    88	}
    89
    90	extension CoreAgentGraphPendingWrite: Equatable where State: Equatable {}
    91	extension CoreAgentGraphPendingWrite: Codable where State: Codable {}
    92
    93	public struct CoreAgentGraphCheckpoint<State: Sendable>: Sendable {
    94	  public let id: CoreAgentGraphCheckpointID
    95	  public let threadID: CoreAgentGraphThreadID
    96	  public let namespace: CoreAgentGraphCheckpointNamespace
    97	  public let parentCheckpointID: CoreAgentGraphCheckpointID?
    98	  public let step: Int
    99	  public let state: State
   100	  public let nextNodeIDs: [CoreAgentGraphNodeID]
   101	  public let pendingWrites: [CoreAgentGraphPendingWrite<State>]
   102	  public let createdAt: Date
   103
   104	  public init(
   105	    id: CoreAgentGraphCheckpointID = .make(),
   106	    threadID: CoreAgentGraphThreadID,
   107	    namespace: CoreAgentGraphCheckpointNamespace = .default,
   108	    parentCheckpointID: CoreAgentGraphCheckpointID? = nil,
   109	    step: Int,
   110	    state: State,
   111	    nextNodeIDs: [CoreAgentGraphNodeID],
   112	    pendingWrites: [CoreAgentGraphPendingWrite<State>] = [],
   113	    createdAt: Date = Date()
   114	  ) {
   115	    self.id = id
   116	    self.threadID = threadID
   117	    self.namespace = namespace
   118	    self.parentCheckpointID = parentCheckpointID
   119	    self.step = step
   120	    self.state = state
   121	    self.nextNodeIDs = nextNodeIDs
   122	    self.pendingWrites = pendingWrites
   123	    self.createdAt = createdAt
   124	  }
   125	}
   126
   127	extension CoreAgentGraphCheckpoint: Equatable where State: Equatable {}
   128	extension CoreAgentGraphCheckpoint: Codable where State: Codable {}
   129
   130	public protocol CoreAgentGraphCheckpointer<State>: Sendable {
   131	  associatedtype State: Sendable
   132
   133	  func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) async throws
   134	  func checkpoint(id: CoreAgentGraphCheckpointID) async throws -> CoreAgentGraphCheckpoint<State>?
   135	  func latest(
   136	    threadID: CoreAgentGraphThreadID,
   137	    namespace: CoreAgentGraphCheckpointNamespace
   138	  ) async throws -> CoreAgentGraphCheckpoint<State>?
   139	  func history(
   140	    threadID: CoreAgentGraphThreadID,
   141	    namespace: CoreAgentGraphCheckpointNamespace
   142	  ) async throws -> [CoreAgentGraphCheckpoint<State>]
   143	}
   144
   145	public actor InMemoryCoreAgentGraphCheckpointer<State: Sendable>:
   146	  CoreAgentGraphCheckpointer
   147	{
   148	  private struct Scope: Hashable {
   149	    let threadID: CoreAgentGraphThreadID
   150	    let namespace: CoreAgentGraphCheckpointNamespace
   151	  }
   152
   153	  private var checkpointsByID: [CoreAgentGraphCheckpointID: [CoreAgentGraphCheckpoint<State>]] = [:]
   154	  private var checkpointsByScope: [Scope: [CoreAgentGraphCheckpoint<State>]] = [:]
   155
   156	  public init() {}
   157
   158	  public func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) {
   159	    checkpointsByID[checkpoint.id, default: []].append(checkpoint)
   160	    let scope = Scope(threadID: checkpoint.threadID, namespace: checkpoint.namespace)
   161	    checkpointsByScope[scope, default: []].append(checkpoint)
   162	  }
   163
   164	  public func checkpoint(id: CoreAgentGraphCheckpointID) -> CoreAgentGraphCheckpoint<State>? {
   165	    checkpointsByID[id]?.last
   166	  }
   167
   168	  public func latest(
   169	    threadID: CoreAgentGraphThreadID,
   170	    namespace: CoreAgentGraphCheckpointNamespace = .default
   171	  ) -> CoreAgentGraphCheckpoint<State>? {
   172	    history(threadID: threadID, namespace: namespace).first
   173	  }
   174
   175	  public func history(
   176	    threadID: CoreAgentGraphThreadID,
   177	    namespace: CoreAgentGraphCheckpointNamespace = .default
   178	  ) -> [CoreAgentGraphCheckpoint<State>] {
   179	    let scope = Scope(threadID: threadID, namespace: namespace)
   180	    return checkpointsByScope[scope, default: []].reversed()
   181	  }
   182	}

## Sources/CoreAgentGraph/CoreAgentGraphStore.swift
    45
    46	  public static func < (lhs: Self, rhs: Self) -> Bool {
    47	    lhs.rawValue < rhs.rawValue
    48	  }
    49	}
    50
    51	public struct CoreAgentGraphStoreRecord<Value: Sendable>: Sendable {
    52	  public let namespace: CoreAgentGraphStoreNamespace
    53	  public let key: CoreAgentGraphStoreKey
    54	  public let value: Value
    55	  public let updatedAt: Date
    56
    57	  public init(
    58	    namespace: CoreAgentGraphStoreNamespace = .default,
    59	    key: CoreAgentGraphStoreKey,
    60	    value: Value,
    61	    updatedAt: Date = Date()
    62	  ) {
    63	    self.namespace = namespace
    64	    self.key = key
    65	    self.value = value
    66	    self.updatedAt = updatedAt
    67	  }
    68	}
    69
    70	extension CoreAgentGraphStoreRecord: Equatable where Value: Equatable {}
    71
    72	public protocol CoreAgentGraphStore<Value>: Sendable {
    73	  associatedtype Value: Sendable
    74
    75	  func put(
    76	    _ value: Value,
    77	    forKey key: CoreAgentGraphStoreKey,
    78	    namespace: CoreAgentGraphStoreNamespace
    79	  ) async throws
    80
    81	  func value(
    82	    forKey key: CoreAgentGraphStoreKey,
    83	    namespace: CoreAgentGraphStoreNamespace
    84	  ) async throws -> Value?
    85
    86	  func record(
    87	    forKey key: CoreAgentGraphStoreKey,
    88	    namespace: CoreAgentGraphStoreNamespace
    89	  ) async throws -> CoreAgentGraphStoreRecord<Value>?
    90
    91	  func removeValue(
    92	    forKey key: CoreAgentGraphStoreKey,
    93	    namespace: CoreAgentGraphStoreNamespace
    94	  ) async throws
    95
    96	  func keys(namespace: CoreAgentGraphStoreNamespace) async throws -> [CoreAgentGraphStoreKey]
    97	}
    98
    99	public actor InMemoryCoreAgentGraphStore<Value: Sendable>: CoreAgentGraphStore {
   100	  private struct Scope: Hashable {
   101	    let namespace: CoreAgentGraphStoreNamespace
   102	    let key: CoreAgentGraphStoreKey
   103	  }
   104
   105	  private var records: [Scope: CoreAgentGraphStoreRecord<Value>] = [:]
   106
   107	  public init() {}
   108
   109	  public func put(
   110	    _ value: Value,
   111	    forKey key: CoreAgentGraphStoreKey,
   112	    namespace: CoreAgentGraphStoreNamespace = .default
   113	  ) {
   114	    let scope = Scope(namespace: namespace, key: key)
   115	    records[scope] = CoreAgentGraphStoreRecord(namespace: namespace, key: key, value: value)
   116	  }
   117
   118	  public func value(
   119	    forKey key: CoreAgentGraphStoreKey,
   120	    namespace: CoreAgentGraphStoreNamespace = .default
   121	  ) -> Value? {
   122	    record(forKey: key, namespace: namespace)?.value
   123	  }
   124
   125	  public func record(
   126	    forKey key: CoreAgentGraphStoreKey,
   127	    namespace: CoreAgentGraphStoreNamespace = .default
   128	  ) -> CoreAgentGraphStoreRecord<Value>? {
   129	    records[Scope(namespace: namespace, key: key)]
   130	  }
   131
   132	  public func removeValue(
   133	    forKey key: CoreAgentGraphStoreKey,
   134	    namespace: CoreAgentGraphStoreNamespace = .default
   135	  ) {
   136	    records.removeValue(forKey: Scope(namespace: namespace, key: key))
   137	  }
   138
   139	  public func keys(
   140	    namespace: CoreAgentGraphStoreNamespace = .default
   141	  ) -> [CoreAgentGraphStoreKey] {
   142	    records.keys.compactMap { scope in
   143	      scope.namespace == namespace ? scope.key : nil
   144	    }.sorted()
   145	  }
   146	}

## Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift graph persistence excerpt
   985	      return
   986	    }
   987	    modelContext.rollback()
   988	  }
   989
   990	  private struct VerifiedTraceSnapshot {
   991	    let scopeKey: String
   992	    let sequence: Int
   993	    let ingestedAt: Date
   994	    let runID: UUID
   995	    let trace: CoreAgentEngineTrace
   996
   997	    func isNewer(than other: VerifiedTraceSnapshot) -> Bool {
   998	      if sequence != other.sequence {
   999	        return sequence > other.sequence
  1000	      }
  1001	      if ingestedAt != other.ingestedAt {
  1002	        return ingestedAt > other.ingestedAt
  1003	      }
  1004	      return runID.uuidString < other.runID.uuidString
  1005	    }
  1006	  }
  1007	}
  1008
  1009	private extension CoreAgentEngineIssue {
  1010	  func mergedEngineIssueDuplicate(with other: CoreAgentEngineIssue) -> CoreAgentEngineIssue {
  1011	    let preferred = other.isNewerEngineIssue(than: self) ? other : self
  1012	    let existingRunIDs = Set(contributingRunIDs)
  1013	    let mergedRunIDs = contributingRunIDs
  1014	      + other.contributingRunIDs.filter { !existingRunIDs.contains($0) }
  1015	    let sortedRunIDs = mergedRunIDs.sorted { $0.uuidString < $1.uuidString }
  1016	    return CoreAgentEngineIssue(
  1017	      id: preferred.id,
  1018	      projectID: preferred.projectID,
  1019	      fingerprint: preferred.fingerprint,
  1020	      title: preferred.title,
  1021	      contributingRunIDs: sortedRunIDs,
  1022	      status: preferred.status,
  1023	      firstSeenAt: min(firstSeenAt, other.firstSeenAt),
  1024	      lastSeenAt: max(lastSeenAt, other.lastSeenAt)
  1025	    )
  1026	  }
  1027
  1028	  func isNewerEngineIssue(than other: CoreAgentEngineIssue) -> Bool {
  1029	    if lastSeenAt != other.lastSeenAt {
  1030	      return lastSeenAt > other.lastSeenAt
  1031	    }
  1032	    if firstSeenAt != other.firstSeenAt {
  1033	      return firstSeenAt < other.firstSeenAt
  1034	    }
  1035	    if status.enginePersistencePriority != other.status.enginePersistencePriority {
  1036	      return status.enginePersistencePriority > other.status.enginePersistencePriority
  1037	    }
  1038	    if contributingRunIDs.count != other.contributingRunIDs.count {
  1039	      return contributingRunIDs.count > other.contributingRunIDs.count
  1040	    }
  1041	    return fingerprint < other.fingerprint
  1042	  }
  1043	}
  1044
  1045	private extension CoreAgentEngineIssueStatus {
  1046	  var enginePersistencePriority: Int {
  1047	    switch self {
  1048	    case .ignored:
  1049	      return 3
  1050	    case .reopened:
  1051	      return 2
  1052	    case .resolved:
  1053	      return 1
  1054	    case .open:
  1055	      return 0
  1056	    }
  1057	  }
  1058	}
  1059
  1060	@Model
  1061	public final class CoreAgentSwiftDataGraphCheckpointRecord {
  1062	  public private(set) var checkpointScopeKey: String
  1063	  public private(set) var checkpointID: String
  1064	  public private(set) var threadID: String
  1065	  public private(set) var namespace: String
  1066	  public private(set) var parentCheckpointID: String?
  1067	  public private(set) var step: Int
  1068	  public private(set) var createdAt: Date
  1069	  public private(set) var storedAt: Date
  1070	  public private(set) var encodedCheckpoint: Data
  1071	  public private(set) var checkpointDigest: String
  1072
  1073	  public convenience init<State: Codable & Sendable>(
  1074	    checkpoint: CoreAgentGraphCheckpoint<State>,
  1075	    storedAt: Date = Date()
  1076	  ) throws {
  1077	    let encodedCheckpoint = try CoreAgentSwiftDataGraphCodec.encode(checkpoint)
  1078	    self.init(
  1079	      checkpointID: checkpoint.id.rawValue,
  1080	      threadID: checkpoint.threadID.rawValue,
  1081	      namespace: checkpoint.namespace.rawValue,
  1082	      parentCheckpointID: checkpoint.parentCheckpointID?.rawValue,
  1083	      step: checkpoint.step,
  1084	      createdAt: checkpoint.createdAt,
  1085	      storedAt: storedAt,
  1086	      encodedCheckpoint: encodedCheckpoint,
  1087	      checkpointDigest: Self.integrityDigest(
  1088	        checkpointScopeKey: Self.scopeKey(
  1089	          threadID: checkpoint.threadID.rawValue,
  1090	          namespace: checkpoint.namespace.rawValue
  1091	        ),
  1092	        checkpointID: checkpoint.id.rawValue,
  1093	        threadID: checkpoint.threadID.rawValue,
  1094	        namespace: checkpoint.namespace.rawValue,
  1095	        parentCheckpointID: checkpoint.parentCheckpointID?.rawValue,
  1096	        step: checkpoint.step,
  1097	        createdAt: checkpoint.createdAt,
  1098	        storedAt: storedAt,
  1099	        encodedCheckpoint: encodedCheckpoint
  1100	      )
  1101	    )
  1102	  }
  1103
  1104	  public init(
  1105	    checkpointID: String,
  1106	    threadID: String,
  1107	    namespace: String,
  1108	    parentCheckpointID: String?,
  1109	    step: Int,
  1110	    createdAt: Date,
  1111	    storedAt: Date,
  1112	    checkpointScopeKey: String? = nil,
  1113	    encodedCheckpoint: Data,
  1114	    checkpointDigest: String
  1115	  ) {
  1116	    self.checkpointScopeKey = checkpointScopeKey ?? Self.scopeKey(
  1117	      threadID: threadID,
  1118	      namespace: namespace
  1119	    )
  1120	    self.checkpointID = checkpointID
  1121	    self.threadID = threadID
  1122	    self.namespace = namespace
  1123	    self.parentCheckpointID = parentCheckpointID
  1124	    self.step = step
  1125	    self.createdAt = createdAt
  1126	    self.storedAt = storedAt
  1127	    self.encodedCheckpoint = encodedCheckpoint
  1128	    self.checkpointDigest = checkpointDigest
  1129	  }
  1130
  1131	  func checkpoint<State: Codable & Sendable>(
  1132	    as type: State.Type
  1133	  ) -> CoreAgentGraphCheckpoint<State>? {
  1134	    guard checkpointScopeKey == Self.scopeKey(threadID: threadID, namespace: namespace) else {
  1135	      return nil
  1136	    }
  1137	    guard checkpointDigest == Self.integrityDigest(
  1138	      checkpointScopeKey: checkpointScopeKey,
  1139	      checkpointID: checkpointID,
  1140	      threadID: threadID,
  1141	      namespace: namespace,
  1142	      parentCheckpointID: parentCheckpointID,
  1143	      step: step,
  1144	      createdAt: createdAt,
  1145	      storedAt: storedAt,
  1146	      encodedCheckpoint: encodedCheckpoint
  1147	    ) else {
  1148	      return nil
  1149	    }
  1150	    guard let checkpoint = try? CoreAgentSwiftDataGraphCodec.decode(
  1151	      CoreAgentGraphCheckpoint<State>.self,
  1152	      from: encodedCheckpoint
  1153	    ) else {
  1154	      return nil
  1155	    }
  1156	    guard checkpoint.id.rawValue == checkpointID,
  1157	      checkpoint.threadID.rawValue == threadID,
  1158	      checkpoint.namespace.rawValue == namespace,
  1159	      checkpoint.parentCheckpointID?.rawValue == parentCheckpointID,
  1160	      checkpoint.step == step,
  1161	      checkpoint.createdAt == createdAt
  1162	    else {
  1163	      return nil
  1164	    }
  1165	    return checkpoint
  1166	  }
  1167
  1168	  public static func scopeKey(threadID: String, namespace: String) -> String {
  1169	    "graph-checkpoint-scope-sha256-v1:" + sha256Hex(framed([threadID, namespace]))
  1170	  }
  1171
  1172	  static func integrityDigest(
  1173	    checkpointScopeKey: String? = nil,
  1174	    checkpointID: String,
  1175	    threadID: String,
  1176	    namespace: String,
  1177	    parentCheckpointID: String?,
  1178	    step: Int,
  1179	    createdAt: Date,
  1180	    storedAt: Date,
  1181	    encodedCheckpoint: Data
  1182	  ) -> String {
  1183	    let fields = [
  1184	      checkpointScopeKey ?? Self.scopeKey(threadID: threadID, namespace: namespace),
  1185	      checkpointID,
  1186	      threadID,
  1187	      namespace,
  1188	      parentCheckpointID ?? "nil",
  1189	      String(step),
  1190	      timeToken(createdAt),
  1191	      timeToken(storedAt),
  1192	      sha256Hex(encodedCheckpoint),
  1193	    ]
  1194	    return "sha256:" + sha256Hex(framed(fields))
  1195	  }
  1196	}
  1197
  1198	@Model
  1199	public final class CoreAgentSwiftDataGraphStoreRecord {
  1200	  public private(set) var storeScopeKey: String
  1201	  public private(set) var namespace: String
  1202	  public private(set) var key: String
  1203	  public private(set) var updatedAt: Date
  1204	  public private(set) var encodedValue: Data
  1205	  public private(set) var valueDigest: String
  1206
  1207	  public convenience init<Value: Codable & Sendable>(
  1208	    record: CoreAgentGraphStoreRecord<Value>
  1209	  ) throws {
  1210	    let encodedValue = try CoreAgentSwiftDataGraphCodec.encode(record.value)
  1211	    self.init(
  1212	      namespace: record.namespace.rawValue,
  1213	      key: record.key.rawValue,
  1214	      updatedAt: record.updatedAt,
  1215	      encodedValue: encodedValue,
  1216	      valueDigest: Self.integrityDigest(
  1217	        storeScopeKey: Self.scopeKey(
  1218	          namespace: record.namespace.rawValue,
  1219	          key: record.key.rawValue
  1220	        ),
  1221	        namespace: record.namespace.rawValue,
  1222	        key: record.key.rawValue,
  1223	        updatedAt: record.updatedAt,
  1224	        encodedValue: encodedValue
  1225	      )
  1226	    )
  1227	  }
  1228
  1229	  public init(
  1230	    namespace: String,
  1231	    key: String,
  1232	    updatedAt: Date,
  1233	    storeScopeKey: String? = nil,
  1234	    encodedValue: Data,
  1235	    valueDigest: String
  1236	  ) {
  1237	    self.storeScopeKey = storeScopeKey ?? Self.scopeKey(namespace: namespace, key: key)
  1238	    self.namespace = namespace
  1239	    self.key = key
  1240	    self.updatedAt = updatedAt
  1241	    self.encodedValue = encodedValue
  1242	    self.valueDigest = valueDigest
  1243	  }
  1244
  1245	  func graphRecord<Value: Codable & Sendable>(
  1246	    as type: Value.Type
  1247	  ) -> CoreAgentGraphStoreRecord<Value>? {
  1248	    guard storeScopeKey == Self.scopeKey(namespace: namespace, key: key) else {
  1249	      return nil
  1250	    }
  1251	    guard valueDigest == Self.integrityDigest(
  1252	      storeScopeKey: storeScopeKey,
  1253	      namespace: namespace,
  1254	      key: key,
  1255	      updatedAt: updatedAt,
  1256	      encodedValue: encodedValue
  1257	    ) else {
  1258	      return nil
  1259	    }
  1260	    guard let value = try? CoreAgentSwiftDataGraphCodec.decode(Value.self, from: encodedValue)
  1261	    else {
  1262	      return nil
  1263	    }
  1264	    return CoreAgentGraphStoreRecord(
  1265	      namespace: CoreAgentGraphStoreNamespace(namespace),
  1266	      key: CoreAgentGraphStoreKey(key),
  1267	      value: value,
  1268	      updatedAt: updatedAt
  1269	    )
  1270	  }
  1271
  1272	  public static func scopeKey(namespace: String, key: String) -> String {
  1273	    "graph-store-scope-sha256-v1:" + sha256Hex(framed([namespace, key]))
  1274	  }
  1275
  1276	  static func integrityDigest(
  1277	    storeScopeKey: String? = nil,
  1278	    namespace: String,
  1279	    key: String,
  1280	    updatedAt: Date,
  1281	    encodedValue: Data
  1282	  ) -> String {
  1283	    let fields = [
  1284	      storeScopeKey ?? Self.scopeKey(namespace: namespace, key: key),
  1285	      namespace,
  1286	      key,
  1287	      timeToken(updatedAt),
  1288	      sha256Hex(encodedValue),
  1289	    ]
  1290	    return "sha256:" + sha256Hex(framed(fields))
  1291	  }
  1292	}
  1293
  1294	@MainActor
  1295	public final class CoreAgentSwiftDataGraphCheckpointer<State: Codable & Sendable>:
  1296	  CoreAgentGraphCheckpointer
  1297	{
  1298	  private let modelContext: ModelContext
  1299	  private let rollsBackOnFailure: Bool
  1300
  1301	  public init(modelContext: ModelContext, rollsBackOnFailure: Bool = false) {
  1302	    self.modelContext = modelContext
  1303	    self.rollsBackOnFailure = rollsBackOnFailure
  1304	  }
  1305
  1306	  public convenience init(modelContainer: ModelContainer) {
  1307	    self.init(modelContext: ModelContext(modelContainer), rollsBackOnFailure: true)
  1308	  }
  1309
  1310	  public func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) async throws {
  1311	    let record = try CoreAgentSwiftDataGraphCheckpointRecord(checkpoint: checkpoint)
  1312	    do {
  1313	      modelContext.insert(record)
  1314	      try modelContext.save()
  1315	    } catch {
  1316	      recoverAfterFailedMutation()
  1317	      throw error
  1318	    }
  1319	  }
  1320
  1321	  public func checkpoint(
  1322	    id: CoreAgentGraphCheckpointID
  1323	  ) async throws -> CoreAgentGraphCheckpoint<State>? {
  1324	    let checkpointID = id.rawValue
  1325	    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
  1326	      predicate: #Predicate<CoreAgentSwiftDataGraphCheckpointRecord> { record in
  1327	        record.checkpointID == checkpointID
  1328	      },
  1329	      sortBy: [
  1330	        SortDescriptor(\.storedAt, order: .reverse),
  1331	        SortDescriptor(\.createdAt, order: .reverse),
  1332	      ]
  1333	    )
  1334	    return try modelContext.fetch(descriptor)
  1335	      .compactMap { $0.checkpoint(as: State.self) }
  1336	      .first
  1337	  }
  1338
  1339	  public func latest(
  1340	    threadID: CoreAgentGraphThreadID,
  1341	    namespace: CoreAgentGraphCheckpointNamespace = .default
  1342	  ) async throws -> CoreAgentGraphCheckpoint<State>? {
  1343	    try await history(threadID: threadID, namespace: namespace).first
  1344	  }
  1345
  1346	  public func history(
  1347	    threadID: CoreAgentGraphThreadID,
  1348	    namespace: CoreAgentGraphCheckpointNamespace = .default
  1349	  ) async throws -> [CoreAgentGraphCheckpoint<State>] {
  1350	    let records = try checkpointRecords(threadID: threadID, namespace: namespace)
  1351	    return records.compactMap { $0.checkpoint(as: State.self) }
  1352	  }
  1353
  1354	  private func checkpointRecords(
  1355	    threadID: CoreAgentGraphThreadID,
  1356	    namespace: CoreAgentGraphCheckpointNamespace
  1357	  ) throws -> [CoreAgentSwiftDataGraphCheckpointRecord] {
  1358	    let threadID = threadID.rawValue
  1359	    let namespace = namespace.rawValue
  1360	    let scopeKey = CoreAgentSwiftDataGraphCheckpointRecord.scopeKey(
  1361	      threadID: threadID,
  1362	      namespace: namespace
  1363	    )
  1364	    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
  1365	      predicate: #Predicate<CoreAgentSwiftDataGraphCheckpointRecord> { record in
  1366	        record.checkpointScopeKey == scopeKey
  1367	          && record.threadID == threadID
  1368	          && record.namespace == namespace
  1369	      },
  1370	      sortBy: [
  1371	        SortDescriptor(\.step, order: .reverse),
  1372	        SortDescriptor(\.createdAt, order: .reverse),
  1373	        SortDescriptor(\.storedAt, order: .reverse),
  1374	      ]
  1375	    )

## Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift graph tests excerpt
  1940	      ]),
  1941	      plugins: [plugin]
  1942	    )
  1943
  1944	    let response = try await session.respond(to: "hello")
  1945	    let trace = try #require(await store.trace(projectID: "coreagent", runID: response.run.id))
  1946
  1947	    #expect(trace.threadID == "session-thread")
  1948	    #expect(trace.run == response.run)
  1949	    #expect(trace.receipt.verify())
  1950	    #expect(trace.run.events.contains { $0.kind == .runCompleted })
  1951	    #expect(trace.run.usage == response.usage)
  1952	  }
  1953
  1954	  @MainActor
  1955	  @Test("SwiftData graph checkpointer saves latest history and scoped lookup")
  1956	  func swiftDataGraphCheckpointerSavesLatestHistoryAndScopedLookup() async throws {
  1957	    let context = try Self.swiftDataGraphContext()
  1958	    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
  1959	    let first = CoreAgentGraphCheckpoint(
  1960	      id: "checkpoint-1",
  1961	      threadID: "thread-a",
  1962	      namespace: "alpha",
  1963	      step: 0,
  1964	      state: GraphState(log: ["start"]),
  1965	      nextNodeIDs: ["plan"],
  1966	      createdAt: Date(timeIntervalSince1970: 100)
  1967	    )
  1968	    let second = CoreAgentGraphCheckpoint(
  1969	      id: "checkpoint-2",
  1970	      threadID: "thread-a",
  1971	      namespace: "alpha",
  1972	      parentCheckpointID: first.id,
  1973	      step: 1,
  1974	      state: GraphState(log: ["start", "plan"]),
  1975	      nextNodeIDs: ["act"],
  1976	      pendingWrites: [
  1977	        CoreAgentGraphPendingWrite(nodeID: "plan", step: 1, update: GraphState(log: ["pending"]))
  1978	      ],
  1979	      createdAt: Date(timeIntervalSince1970: 101)
  1980	    )
  1981	    let otherNamespace = CoreAgentGraphCheckpoint(
  1982	      id: "checkpoint-3",
  1983	      threadID: "thread-a",
  1984	      namespace: "beta",
  1985	      step: 1,
  1986	      state: GraphState(log: ["beta"]),
  1987	      nextNodeIDs: [],
  1988	      createdAt: Date(timeIntervalSince1970: 102)
  1989	    )
  1990
  1991	    try await checkpointer.save(first)
  1992	    try await checkpointer.save(second)
  1993	    try await checkpointer.save(otherNamespace)
  1994
  1995	    #expect(try await checkpointer.latest(threadID: "thread-a", namespace: "alpha") == second)
  1996	    #expect(try await checkpointer.checkpoint(id: "checkpoint-1") == first)
  1997	    #expect(try await checkpointer.history(threadID: "thread-a", namespace: "alpha") == [
  1998	      second,
  1999	      first,
  2000	    ])
  2001	    #expect(try await checkpointer.latest(threadID: "thread-a", namespace: "beta") == otherNamespace)
  2002	  }
  2003
  2004	  @MainActor
  2005	  @Test("SwiftData graph checkpointer works through protocol and fails closed on corrupt rows")
  2006	  func swiftDataGraphCheckpointerWorksThroughProtocolAndFailsClosedOnCorruptRows() async throws {
  2007	    let context = try Self.swiftDataGraphContext()
  2008	    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
  2009	    let portable: any CoreAgentGraphCheckpointer<GraphState> = checkpointer
  2010	    let checkpoint = CoreAgentGraphCheckpoint(
  2011	      id: "checkpoint-portable",
  2012	      threadID: "thread-b",
  2013	      namespace: "alpha",
  2014	      step: 2,
  2015	      state: GraphState(log: ["portable"]),
  2016	      nextNodeIDs: []
  2017	    )
  2018
  2019	    try await portable.save(checkpoint)
  2020	    context.insert(CoreAgentSwiftDataGraphCheckpointRecord(
  2021	      checkpointID: "checkpoint-corrupt",
  2022	      threadID: "thread-b",
  2023	      namespace: "alpha",
  2024	      parentCheckpointID: nil,
  2025	      step: 3,
  2026	      createdAt: Date(timeIntervalSince1970: 200),
  2027	      storedAt: Date(timeIntervalSince1970: 201),
  2028	      encodedCheckpoint: Data("not-json".utf8),
  2029	      checkpointDigest: "sha256:corrupt"
  2030	    ))
  2031	    try context.save()
  2032
  2033	    #expect(try await portable.checkpoint(id: "checkpoint-portable") == checkpoint)
  2034	    #expect(try await portable.checkpoint(id: "checkpoint-corrupt") == nil)
  2035	    #expect(try await portable.latest(threadID: "thread-b", namespace: "alpha") == checkpoint)
  2036	  }
  2037
  2038	  @MainActor
  2039	  @Test("SwiftData graph store persists values by namespace and key")
  2040	  func swiftDataGraphStorePersistsValuesByNamespaceAndKey() async throws {
  2041	    let context = try Self.swiftDataGraphContext()
  2042	    let store: any CoreAgentGraphStore<GraphValue> =
  2043	      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)
  2044
  2045	    try await store.put(GraphValue(label: "alpha"), forKey: "profile", namespace: "alpha")
  2046	    try await store.put(GraphValue(label: "beta"), forKey: "profile", namespace: "beta")
  2047	    try await store.put(GraphValue(label: "first"), forKey: "a", namespace: "alpha")
  2048
  2049	    #expect(try await store.value(forKey: "profile", namespace: "alpha") == GraphValue(label: "alpha"))
  2050	    #expect(try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
  2051	    #expect(try await store.keys(namespace: "alpha") == ["a", "profile"])
  2052
  2053	    try await store.removeValue(forKey: "profile", namespace: "alpha")
  2054
  2055	    #expect(try await store.value(forKey: "profile", namespace: "alpha") == nil)
  2056	    #expect(try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
  2057	  }
  2058
  2059	  @MainActor
  2060	  @Test("SwiftUI projection store summarizes run state without raw event payloads")
  2061	  func swiftUIProjectionStoreSummarizesRunStateWithoutRawEventPayloads() throws {
  2062	    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
  2063	    let run = CoreAgentRun(
  2064	      id: runID,
  2065	      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
  2066	      endedAt: Date(timeIntervalSince1970: 1_800_000_003),
  2067	      usage: nil,
  2068	      events: [
  2069	        Self.event(runID: runID, kind: .runStarted, message: "contains token=secret"),
  2070	        Self.event(
  2071	          runID: runID,
  2072	          kind: .runFailed,
  2073	          message: "failed with token=secret",
  2074	          attributes: ["api_key": "secret", "tool": "write_file"]
  2075	        ),
  2290
  2291	  private struct GraphState: Codable, Equatable, Sendable {
  2292	    var log: [String] = []
  2293	  }
  2294
  2295	  private struct GraphValue: Codable, Equatable, Sendable {
  2296	    var label: String
  2297	  }
  2298
  2299	  @MainActor
  2300	  private static func swiftDataContext() throws -> ModelContext {
  2301	    let container = try ModelContainer(
  2302	      for: CoreAgentSwiftDataCheckpointRecord.self,
  2303	      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  2304	    )
  2305	    return ModelContext(container)
  2306	  }
  2307
  2308	  @MainActor
  2309	  private static func swiftDataEngineContext() throws -> ModelContext {
  2310	    let container = try ModelContainer(
  2311	      for: CoreAgentSwiftDataEngineTraceRecord.self,
  2312	      CoreAgentSwiftDataEngineIssueRecord.self,
  2313	      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  2314	    )
  2315	    return ModelContext(container)
  2316	  }
  2317
  2318	  @MainActor
  2319	  private static func swiftDataGraphContext() throws -> ModelContext {
  2320	    let container = try ModelContainer(
  2321	      for: CoreAgentSwiftDataGraphCheckpointRecord.self,
  2322	      CoreAgentSwiftDataGraphStoreRecord.self,
  2323	      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  2324	    )
  2325	    return ModelContext(container)
  2326	  }
  2327
  2328	  private static func receipt(
  2329	    id: String,
  2330	    requirement: CoreAgentAppleConsentRequirement,
  2331	    expiresAt: Date? = nil
  2332	  ) -> CoreAgentAppleConsentReceipt {
  2333	    CoreAgentAppleConsentReceipt.issue(
  2334	      id: id,
  2335	      issuerID: Self.issuerID,
  2336	      requirement: requirement,
  2337	      signingKey: Self.signingKey,
  2338	      grantedAt: Self.grantedAt,
  2339	      expiresAt: expiresAt ?? Self.grantedAt.addingTimeInterval(300)
  2340	    )
  2341	  }
  2342
  2343	  private static let issuerID = "coreagent.test.consent"
  2344	  private static let signingKey = CoreAgentAppleConsentSigningKey(
  2345	    Data("coreagent-apple-platform-test-signing-key".utf8)
