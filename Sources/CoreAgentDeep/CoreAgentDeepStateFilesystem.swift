import Foundation

public actor CoreAgentDeepStateFilesystem: CoreAgentDeepFilesystemBackend {
  private let permissions: [CoreAgentDeepFilesystemPermissionRule]
  private var files: [String: String]
  private var events: [CoreAgentDeepFilesystemAuditEvent] = []

  public init(
    files: [String: String] = [:],
    permissions: [CoreAgentDeepFilesystemPermissionRule] = []
  ) {
    self.permissions = permissions
    self.files = files.reduce(into: [:]) { result, pair in
      if let path = try? Self.normalizeVirtualPath(pair.key) {
        result[path] = pair.value
      }
    }
  }

  public func writeFile(_ contents: String, at path: String) async throws {
    let path = try authorize(path: path, operation: .write)
    files[path] = contents
  }

  public func fileExists(at path: String) async throws -> Bool {
    let path = try authorize(path: path, operation: .write)
    return files[path] != nil
  }

  public func readFile(at path: String) async throws -> String {
    let path = try authorize(path: path, operation: .read)
    guard let contents = files[path] else {
      throw CoreAgentDeepFilesystemError.notFound(path: path)
    }
    return contents
  }

  public func editFile(
    at path: String,
    replacing oldString: String,
    with newString: String,
    replaceAll: Bool
  ) async throws -> CoreAgentDeepEditResult {
    let path = try authorize(path: path, operation: .edit)
    guard let contents = files[path] else {
      throw CoreAgentDeepFilesystemError.notFound(path: path)
    }
    let replacement = try Self.replacement(
      in: contents,
      path: path,
      oldString: oldString,
      newString: newString,
      replaceAll: replaceAll
    )
    files[path] = replacement.contents
    return CoreAgentDeepEditResult(path: path, occurrences: replacement.occurrences)
  }

  public func listDirectory(at path: String) async throws -> [CoreAgentDeepFileInfo] {
    let path = try authorize(path: path, operation: .list)
    let prefix = path == "/" ? "/" : path + "/"
    let children = Set(
      files.keys.compactMap { filePath -> String? in
        guard filePath.hasPrefix(prefix) else { return nil }
        let remainder = filePath.dropFirst(prefix.count)
        guard let first = remainder.split(separator: "/", maxSplits: 1).first else {
          return nil
        }
        return prefix + first
      }
    )
    guard !children.isEmpty || path == "/" else {
      throw CoreAgentDeepFilesystemError.notFound(path: path)
    }
    return children.sorted().map { childPath in
      let isDirectory = files.keys.contains { $0.hasPrefix(childPath + "/") }
      return CoreAgentDeepFileInfo(
        path: childPath,
        isDirectory: isDirectory,
        byteCount: isDirectory ? nil : files[childPath]?.utf8.count,
        modifiedAt: nil
      )
    }
  }

  public func glob(pattern: String, path: String?) async throws -> [String] {
    let base = try authorize(path: path ?? "/", operation: .glob)
    return files.keys
      .filter { isDescendantOrEqual($0, base: base) }
      .filter { Self.matchesSearchPattern(pattern, base: base, candidate: $0) }
      .filter { isPermitted(operation: .glob, path: $0) }
      .sorted()
  }

  public func grep(
    pattern: String,
    path: String?,
    glob: String?
  ) async throws -> [CoreAgentDeepGrepMatch] {
    let base = try authorize(path: path ?? "/", operation: .grep)
    var matches: [CoreAgentDeepGrepMatch] = []
    for filePath in files.keys.sorted()
    where isDescendantOrEqual(filePath, base: base)
      && isPermitted(operation: .grep, path: filePath)
      && Self.matchesOptionalGrepGlob(glob, base: base, candidate: filePath)
    {
      guard let contents = files[filePath] else { continue }
      matches.append(contentsOf: Self.grepMatches(in: contents, path: filePath, pattern: pattern))
    }
    return matches
  }

  public func deleteFile(at path: String) async throws {
    let path = try authorize(path: path, operation: .delete)
    guard files.removeValue(forKey: path) != nil else {
      throw CoreAgentDeepFilesystemError.notFound(path: path)
    }
  }

  public func auditEvents() -> [CoreAgentDeepFilesystemAuditEvent] {
    events
  }

  public func snapshot() -> [String: String] {
    files
  }

  private func authorize(
    path rawPath: String,
    operation: CoreAgentDeepFilesystemOperation
  ) throws -> String {
    let path: String
    do {
      path = try Self.normalizeVirtualPath(rawPath)
    } catch let error as CoreAgentDeepFilesystemError {
      if case .escapedRoot(let path) = error {
        recordAuditEvent(operation: operation, path: path, decision: .denied)
      }
      throw error
    }
    let permission = permissionDecision(for: operation, path: path)
    guard let permission, permission.rule.mode == .allow else {
      recordAuditEvent(
        operation: operation,
        path: path,
        decision: .denied,
        ruleIndex: permission?.index
      )
      throw CoreAgentDeepFilesystemError.denied(operation: operation, path: path)
    }
    recordAuditEvent(
      operation: operation,
      path: path,
      decision: .allowed,
      ruleIndex: permission.index
    )
    return path
  }

  private func permissionDecision(
    for operation: CoreAgentDeepFilesystemOperation,
    path: String
  ) -> (index: Int, rule: CoreAgentDeepFilesystemPermissionRule)? {
    for (index, rule) in permissions.enumerated()
    where rule.operations.contains(operation)
      && rule.paths.contains(where: { Self.matches($0, path) })
    {
      return (index, rule)
    }
    return nil
  }

  private func isPermitted(operation: CoreAgentDeepFilesystemOperation, path: String) -> Bool {
    guard let permission = permissionDecision(for: operation, path: path) else {
      return false
    }
    return permission.rule.mode == .allow
  }

  private func isDescendantOrEqual(_ path: String, base: String) -> Bool {
    base == "/" || path == base || path.hasPrefix(base + "/")
  }

  private func recordAuditEvent(
    operation: CoreAgentDeepFilesystemOperation,
    path: String,
    decision: CoreAgentDeepFilesystemAuditDecision,
    ruleIndex: Int? = nil
  ) {
    events.append(
      CoreAgentDeepFilesystemAuditEvent(
        operation: operation,
        path: path,
        decision: decision,
        ruleIndex: ruleIndex
      )
    )
  }

  private static func normalizeVirtualPath(_ path: String) throws -> String {
    if path == "~" || path.hasPrefix("~/") {
      throw CoreAgentDeepFilesystemError.escapedRoot(path: canonicalDisplayPath(path))
    }
    let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
    var components: [String] = []
    for component in rawComponents {
      switch component {
      case ".":
        continue
      case "..":
        guard !components.isEmpty else {
          throw CoreAgentDeepFilesystemError.escapedRoot(path: canonicalDisplayPath(path))
        }
        components.removeLast()
      default:
        components.append(String(component))
      }
    }
    return "/" + components.joined(separator: "/")
  }

  private static func canonicalDisplayPath(_ path: String) -> String {
    path.hasPrefix("/") ? path : "/" + path
  }

  private static func matches(_ pattern: String, _ path: String) -> Bool {
    let normalizedPattern = canonicalDisplayPath(pattern)
    if normalizedPattern.hasSuffix("/**") {
      let base = String(normalizedPattern.dropLast(3))
      return path == base || path.hasPrefix(base + "/")
    }
    return globRegex(for: normalizedPattern).firstMatch(
      in: path,
      range: NSRange(location: 0, length: path.utf16.count)
    ) != nil
  }

  private static func globRegex(for pattern: String) -> NSRegularExpression {
    var regex = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      if character == "*" {
        let next = pattern.index(after: index)
        if next < pattern.endIndex, pattern[next] == "*" {
          let afterGlobstar = pattern.index(after: next)
          if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
            regex += "(?:.*/)?"
            index = pattern.index(after: afterGlobstar)
          } else {
            regex += ".*"
            index = afterGlobstar
          }
        } else {
          regex += #"[^/]*"#
          index = next
        }
      } else if character == "?" {
        regex += #"[^/]"#
        index = pattern.index(after: index)
      } else {
        regex += NSRegularExpression.escapedPattern(for: String(character))
        index = pattern.index(after: index)
      }
    }
    regex += "$"
    return try! NSRegularExpression(pattern: regex)
  }

  private static func matchesSearchPattern(
    _ pattern: String,
    base: String,
    candidate: String
  ) -> Bool {
    let matchPath = pattern.hasPrefix("/") ? candidate : relativePath(from: base, to: candidate)
    return globRegex(for: pattern).firstMatch(
      in: matchPath,
      range: NSRange(location: 0, length: matchPath.utf16.count)
    ) != nil
  }

  private static func matchesOptionalGrepGlob(
    _ glob: String?,
    base: String,
    candidate: String
  ) -> Bool {
    guard let glob else { return true }
    let matchPath: String
    if glob.hasPrefix("/") {
      matchPath = candidate
    } else if glob.contains("/") {
      matchPath = relativePath(from: base, to: candidate)
    } else {
      matchPath = String(candidate.split(separator: "/").last ?? "")
    }
    return globRegex(for: glob).firstMatch(
      in: matchPath,
      range: NSRange(location: 0, length: matchPath.utf16.count)
    ) != nil
  }

  private static func relativePath(from base: String, to candidate: String) -> String {
    guard base != "/" else { return String(candidate.dropFirst()) }
    guard candidate.hasPrefix(base + "/") else { return candidate }
    return String(candidate.dropFirst(base.count + 1))
  }

  private static func replacement(
    in contents: String,
    path: String,
    oldString: String,
    newString: String,
    replaceAll: Bool
  ) throws -> (contents: String, occurrences: Int) {
    guard oldString != newString else {
      throw CoreAgentDeepFilesystemError.editReplacementUnchanged(path: path)
    }
    let occurrences = countOccurrences(of: oldString, in: contents)
    guard occurrences > 0 else {
      throw CoreAgentDeepFilesystemError.editTargetNotFound(path: path)
    }
    guard replaceAll || occurrences == 1 else {
      throw CoreAgentDeepFilesystemError.editTargetNotUnique(path: path, occurrences: occurrences)
    }
    return (
      contents.replacingOccurrences(of: oldString, with: newString),
      replaceAll ? occurrences : 1
    )
  }

  private static func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }

  private static func grepMatches(
    in contents: String,
    path: String,
    pattern: String
  ) -> [CoreAgentDeepGrepMatch] {
    contents
      .split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .compactMap { index, line in
        guard line.contains(pattern) else { return nil }
        return CoreAgentDeepGrepMatch(path: path, lineNumber: index + 1, line: String(line))
      }
  }
}
