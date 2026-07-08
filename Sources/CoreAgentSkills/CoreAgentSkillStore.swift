import CryptoKit
import Darwin
import Foundation

public protocol CoreAgentSkillStore: Sendable {
  func save(_ skill: CoreAgentSkill) async throws
  func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill?
  func allCurrentSkills() async -> [CoreAgentSkill]
  func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory
  func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID)
    async throws
  func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws
  func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws
  func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws
}

public actor InMemoryCoreAgentSkillStore: CoreAgentSkillStore {
  private var historyByID: [CoreAgentSkillID: [CoreAgentSkill]] = [:]
  private var memoryByID: [CoreAgentSkillID: CoreAgentSkillOptimizerMemory] = [:]

  public init() {}

  public func save(_ skill: CoreAgentSkill) async throws {
    if historyByID[skill.id, default: []].contains(where: { $0.version == skill.version }) {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    historyByID[id]?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    historyByID.values
      .compactMap { $0.max { $0.version < $1.version } }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  }

  public func recordRejected(
    _ rejected: CoreAgentRejectedSkillEdit,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.rejectedEdits.append(rejected)
    memoryByID[skillID] = memory
  }

  public func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.metaObservations.append(observation)
    memoryByID[skillID] = memory
  }

  public func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    try appendMetaSkillSnapshot(snapshot, to: &memory)
    memoryByID[skillID] = memory
  }

  public func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    try appendMetaSkillEvolution(record, to: &memory)
    memoryByID[skillID] = memory
  }
}

public actor FileCoreAgentSkillStore: CoreAgentSkillStore {
  private let rootDirectory: URL

  public init(rootDirectory: URL) throws {
    self.rootDirectory = rootDirectory
    try FileManager.default.createDirectory(
      at: Self.skillsDirectory(rootDirectory: rootDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: Self.memoryDirectory(rootDirectory: rootDirectory),
      withIntermediateDirectories: true
    )
  }

  public func save(_ skill: CoreAgentSkill) async throws {
    let directory = skillDirectory(for: skill.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = skillURL(id: skill.id, version: skill.version)
    let data = try encoded(skill)
    do {
      try writeNewFile(data, to: url)
    } catch FileCoreAgentSkillStoreError.fileAlreadyExists {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    skillHistory(id: id)?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: Self.skillsDirectory(rootDirectory: rootDirectory),
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else {
      return []
    }
    return
      directories
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      .compactMap { currentSkill(in: $0) }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    readMemory(skillID: skillID) ?? CoreAgentSkillOptimizerMemory()
  }

  public func recordRejected(
    _ rejected: CoreAgentRejectedSkillEdit,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    memory.rejectedEdits.append(rejected)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    memory.metaObservations.append(observation)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    try appendMetaSkillSnapshot(snapshot, to: &memory)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    try appendMetaSkillEvolution(record, to: &memory)
    try write(memory, to: memoryURL(for: skillID))
  }

  @discardableResult
  public func exportBestSkillMarkdown(
    id: CoreAgentSkillID,
    to directory: URL,
    filename: String = "best_skill.md"
  ) async throws -> URL {
    guard let skill = await currentSkill(id: id) else {
      throw CoreAgentSkillOptimizationError.missingSkill(id)
    }
    try validateExportFilename(filename)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: filename)
    try CoreAgentSkillExporter.bestSkillMarkdown(skill).write(
      to: url,
      atomically: true,
      encoding: .utf8
    )
    return url
  }

  private func skillHistory(id: CoreAgentSkillID) -> [CoreAgentSkill]? {
    let directory = skillDirectory(for: id)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    var skills: [CoreAgentSkill] = []
    for url in urls where url.pathExtension == "json" {
      guard let skill: CoreAgentSkill = read(url),
        skill.id == id,
        rowFilenameMatches(url: url, skill: skill)
      else {
        return nil
      }
      skills.append(skill)
    }
    return skills.sorted { $0.version < $1.version }
  }

  private func currentSkill(in directory: URL) -> CoreAgentSkill? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    var skills: [CoreAgentSkill] = []
    for url in urls where url.pathExtension == "json" {
      guard let skill: CoreAgentSkill = read(url),
        rowFilenameMatches(url: url, skill: skill),
        skillDirectory(for: skill.id).standardizedFileURL == directory.standardizedFileURL
      else {
        return nil
      }
      skills.append(skill)
    }
    return skills.max { $0.version < $1.version }
  }

  private func readMemory(skillID: CoreAgentSkillID) -> CoreAgentSkillOptimizerMemory? {
    read(memoryURL(for: skillID))
  }

  private func readMemoryForMutation(
    skillID: CoreAgentSkillID
  ) throws -> CoreAgentSkillOptimizerMemory {
    let url = memoryURL(for: skillID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return CoreAgentSkillOptimizerMemory()
    }
    guard let memory: CoreAgentSkillOptimizerMemory = read(url) else {
      throw CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for \(skillID.rawValue)"
      )
    }
    return memory
  }

  private func skillDirectory(for id: CoreAgentSkillID) -> URL {
    Self.skillsDirectory(rootDirectory: rootDirectory)
      .appending(
        path: Self.pathComponent(prefix: "skill", value: id.rawValue), directoryHint: .isDirectory)
  }

  private func skillURL(id: CoreAgentSkillID, version: Int) -> URL {
    skillDirectory(for: id).appending(path: "version-\(version).json")
  }

  private func memoryURL(for id: CoreAgentSkillID) -> URL {
    Self.memoryDirectory(rootDirectory: rootDirectory)
      .appending(
        path: "\(Self.pathComponent(prefix: "skill", value: id.rawValue))-optimizer-memory.json")
  }

  private func rowFilenameMatches(url: URL, skill: CoreAgentSkill) -> Bool {
    url.lastPathComponent == "version-\(skill.version).json"
  }

  private func validateExportFilename(_ filename: String) throws {
    guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      !filename.contains("/"),
      !filename.contains("\\")
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "export filename must be a plain file name"
      )
    }
  }

  private static func skillsDirectory(rootDirectory: URL) -> URL {
    rootDirectory.appending(path: "skills", directoryHint: .isDirectory)
  }

  private static func memoryDirectory(rootDirectory: URL) -> URL {
    rootDirectory.appending(path: "optimizer-memory", directoryHint: .isDirectory)
  }

  private static func pathComponent(prefix: String, value: String) -> String {
    "\(prefix)-\(sha256Hex(Data(value.utf8)))"
  }

  private func read<Value: Decodable>(_ url: URL) -> Value? {
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(Value.self, from: data)
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    try encoded(value).write(to: url, options: [.atomic])
  }

  private func writeNewFile(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw FileCoreAgentSkillStoreError.fileAlreadyExists
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }
}

private enum FileCoreAgentSkillStoreError: Error {
  case fileAlreadyExists
}

private func appendMetaSkillSnapshot(
  _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
  to memory: inout CoreAgentSkillOptimizerMemory
) throws {
  try validateMetaSkillSnapshot(snapshot)
  guard
    !memory.metaSkillSnapshots.contains(where: {
      $0.branchID == snapshot.branchID && $0.epoch == snapshot.epoch
    })
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill snapshot branch epoch already recorded"
    )
  }
  memory.metaSkillSnapshots.append(snapshot)
}

private func appendMetaSkillEvolution(
  _ record: CoreAgentSkillMetaSkillEvolutionRecord,
  to memory: inout CoreAgentSkillOptimizerMemory
) throws {
  try validateMetaSkillEvolutionRecord(record)
  guard
    !memory.metaSkillEvolutionRecords.contains(where: {
      $0.runID == record.runID
        && $0.branchID == record.branchID
        && $0.nextEpoch == record.nextEpoch
    })
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution record already exists"
    )
  }
  memory.metaSkillEvolutionRecords.append(record)
}

private func validateMetaSkillSnapshot(
  _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot
) throws {
  guard isSafeProposalIdentifier(snapshot.branchID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill branch ID is invalid"
    )
  }
  if let parentBranchID = snapshot.parentBranchID {
    guard isSafeProposalIdentifier(parentBranchID) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill parent branch ID is invalid"
      )
    }
  }
  guard snapshot.epoch >= 0 else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill epoch must be non-negative"
    )
  }
  try validateMetaSkillComponent(snapshot.analyzer)
  try validateMetaSkillComponent(snapshot.retriever)
  try validateMetaSkillComponent(snapshot.allocator)
  try validateMetaSkillComponent(snapshot.proposer)
  try validateMetaSkillComponent(snapshot.evolver)
  guard isSHA256Digest(snapshot.objectiveDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill objective digest must be lowercase sha256"
    )
  }
}

private func validateMetaSkillComponent(
  _ component: CoreAgentSkillMetaSkillComponent
) throws {
  guard isSHA256Digest(component.componentDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill component digest must be lowercase sha256"
    )
  }
  let policyVersion = component.policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !policyVersion.isEmpty,
    policyVersion.count <= 128,
    !policyVersion.contains("\n"),
    !policyVersion.contains("\r")
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill component policy version is invalid"
    )
  }
}

private func validateMetaSkillEvolutionRecord(
  _ record: CoreAgentSkillMetaSkillEvolutionRecord
) throws {
  guard isSafeProposalIdentifier(record.runID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution run ID is invalid"
    )
  }
  guard isSafeProposalIdentifier(record.branchID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill branch ID is invalid"
    )
  }
  guard record.previousEpoch >= 0 else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution previous epoch must be non-negative"
    )
  }
  guard record.nextEpoch > record.previousEpoch else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution epoch must advance"
    )
  }
  guard isSHA256Digest(record.evidenceDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution evidence digest must be lowercase sha256"
    )
  }
  try validateMetaSkillProposalIDs(record.acceptedProposalIDs)
  try validateMetaSkillProposalIDs(record.rejectedProposalIDs)
  try validateMetaSkillProposalIDs(record.frontierRejectedProposalIDs)
  try validateMetaSkillProposalIDs(record.sleepAcceptedProposalIDs)
  try validateMetaSkillProposalIDs(record.sleepRejectedProposalIDs)
  guard Set(record.acceptedProposalIDs).isDisjoint(with: Set(record.rejectedProposalIDs)) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill accepted and rejected proposals must not overlap"
    )
  }
  guard record.acceptedProposalIDs == record.sleepAcceptedProposalIDs else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill accepted proposals must match sleep accepted proposals"
    )
  }
  guard
    record.rejectedProposalIDs
      == orderedUnique(
        record.frontierRejectedProposalIDs + record.sleepRejectedProposalIDs
      )
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill rejected proposals must match frontier plus sleep rejected proposals"
    )
  }
}

private func validateMetaSkillProposalIDs(_ proposalIDs: [String]) throws {
  var seen: Set<String> = []
  for proposalID in proposalIDs {
    guard isSafeProposalIdentifier(proposalID) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill proposal ID is invalid"
      )
    }
    guard seen.insert(proposalID).inserted else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill proposal IDs must be unique"
      )
    }
  }
}

private func orderedUnique(_ values: [String]) -> [String] {
  var seen: Set<String> = []
  var result: [String] = []
  for value in values where seen.insert(value).inserted {
    result.append(value)
  }
  return result
}

public enum CoreAgentSkillExporter {
  public static func bestSkillMarkdown(_ skill: CoreAgentSkill) -> String {
    var lines: [String] = [
      "# \(skill.title)",
      "",
      "Version: \(skill.version)",
      "Tags: \(skill.tags.joined(separator: ", "))",
      "",
      skill.body,
    ]
    if let latest = skill.provenance.last {
      lines.append("")
      lines.append("Heldout Suite: \(latest.heldoutSuiteID)")
      lines.append("Validation Score: \(latest.validationScore)")
    }
    return lines.joined(separator: "\n")
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256Digest(_ value: String) -> Bool {
  guard value.hasPrefix("sha256:") else { return false }
  let hex = value.dropFirst("sha256:".count)
  guard hex.count == 64 else { return false }
  return hex.unicodeScalars.allSatisfy { scalar in
    (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
  }
}

private func isSafeProposalIdentifier(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard !scalars.isEmpty, scalars.count <= 128 else { return false }
  guard isASCIIIdentifierHead(scalars[0]) else { return false }
  return scalars.allSatisfy { scalar in
    let value = Int(scalar.value)
    return isASCIIIdentifierHead(scalar) || (48...57).contains(value)
      || value == 45 || value == 46 || value == 58 || value == 95
  }
}

private func isASCIIIdentifierHead(_ scalar: Unicode.Scalar) -> Bool {
  (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
}
