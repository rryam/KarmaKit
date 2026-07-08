import Foundation

public actor CoreAgentDeepLocalFilesystem: CoreAgentDeepFilesystemBackend {
  private let resolvedRootDirectory: URL
  private let permissions: [CoreAgentDeepFilesystemPermissionRule]
  private var events: [CoreAgentDeepFilesystemAuditEvent] = []

  public init(
    rootDirectory: URL,
    permissions: [CoreAgentDeepFilesystemPermissionRule] = []
  ) {
    self.resolvedRootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    self.permissions = permissions
  }

  public func writeFile(_ contents: String, at path: String) async throws {
    let resolved = try resolve(path, operation: .write)
    try FileManager.default.createDirectory(
      at: resolved.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: resolved.fileURL, atomically: true, encoding: .utf8)
  }

  public func fileExists(at path: String) async throws -> Bool {
    let resolved = try resolve(path, operation: .write)
    return FileManager.default.fileExists(atPath: resolved.fileURL.path)
  }

  public func readFile(at path: String) async throws -> String {
    let resolved = try resolve(path, operation: .read)
    guard FileManager.default.fileExists(atPath: resolved.fileURL.path) else {
      throw CoreAgentDeepFilesystemError.notFound(path: resolved.virtualPath)
    }
    guard let contents = String(data: try Data(contentsOf: resolved.fileURL), encoding: .utf8)
    else {
      throw CoreAgentDeepFilesystemError.invalidTextEncoding(path: resolved.virtualPath)
    }
    return contents
  }

  public func editFile(
    at path: String,
    replacing oldString: String,
    with newString: String,
    replaceAll: Bool
  ) async throws -> CoreAgentDeepEditResult {
    let resolved = try resolve(path, operation: .edit)
    guard FileManager.default.fileExists(atPath: resolved.fileURL.path) else {
      throw CoreAgentDeepFilesystemError.notFound(path: resolved.virtualPath)
    }
    guard let contents = String(data: try Data(contentsOf: resolved.fileURL), encoding: .utf8)
    else {
      throw CoreAgentDeepFilesystemError.invalidTextEncoding(path: resolved.virtualPath)
    }
    let replacement = try replacement(
      in: contents,
      path: resolved.virtualPath,
      oldString: oldString,
      newString: newString,
      replaceAll: replaceAll
    )
    try replacement.contents.write(to: resolved.fileURL, atomically: true, encoding: .utf8)
    return CoreAgentDeepEditResult(
      path: resolved.virtualPath,
      occurrences: replacement.occurrences
    )
  }

  public func listDirectory(at path: String) async throws -> [CoreAgentDeepFileInfo] {
    let resolved = try resolve(path, operation: .list)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.fileURL.path, isDirectory: &isDirectory)
    else {
      throw CoreAgentDeepFilesystemError.notFound(path: resolved.virtualPath)
    }
    guard isDirectory.boolValue else {
      throw CoreAgentDeepFilesystemError.notDirectory(path: resolved.virtualPath)
    }
    let children = try FileManager.default.contentsOfDirectory(
      at: resolved.fileURL,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    )
    return try children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { url in
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
      ])
      return CoreAgentDeepFileInfo(
        path: joinVirtualPath(resolved.virtualPath, url.lastPathComponent),
        isDirectory: values.isDirectory ?? false,
        byteCount: values.fileSize,
        modifiedAt: values.contentModificationDate
      )
    }
  }

  public func glob(pattern: String, path: String?) async throws -> [String] {
    let resolved = try resolve(path ?? "/", operation: .glob)
    let candidatePaths = try recursiveFilePaths(from: resolved)
    return
      candidatePaths
      .filter { matchesSearchPattern(pattern, base: resolved.virtualPath, candidate: $0) }
      .filter { isPermitted(operation: .glob, path: $0) }
      .sorted()
  }

  public func grep(
    pattern: String,
    path: String?,
    glob: String?
  ) async throws -> [CoreAgentDeepGrepMatch] {
    let resolved = try resolve(path ?? "/", operation: .grep)
    let candidatePaths = try recursiveFilePaths(from: resolved)
      .filter { isPermitted(operation: .grep, path: $0) }
      .filter { candidate in
        guard let glob else { return true }
        return matchesGrepGlob(glob, base: resolved.virtualPath, candidate: candidate)
      }
      .sorted()
    var matches: [CoreAgentDeepGrepMatch] = []
    for candidatePath in candidatePaths {
      let fileURL = resolvedRootDirectory.appending(path: String(candidatePath.dropFirst()))
      guard let contents = String(data: try Data(contentsOf: fileURL), encoding: .utf8) else {
        continue
      }
      matches.append(contentsOf: grepMatches(in: contents, path: candidatePath, pattern: pattern))
    }
    return matches
  }

  public func deleteFile(at path: String) async throws {
    let resolved = try resolve(path, operation: .delete)
    guard FileManager.default.fileExists(atPath: resolved.fileURL.path) else {
      throw CoreAgentDeepFilesystemError.notFound(path: resolved.virtualPath)
    }
    try FileManager.default.removeItem(at: resolved.fileURL)
  }

  public func auditEvents() -> [CoreAgentDeepFilesystemAuditEvent] {
    events
  }

  private struct ResolvedPath {
    let virtualPath: String
    let fileURL: URL
  }

  private func resolve(
    _ rawPath: String,
    operation: CoreAgentDeepFilesystemOperation
  ) throws -> ResolvedPath {
    let virtualPath: String
    do {
      virtualPath = try normalizeVirtualPath(rawPath)
    } catch let error as CoreAgentDeepFilesystemError {
      if case .escapedRoot(let path) = error {
        recordAuditEvent(operation: operation, path: path, decision: .denied)
      }
      throw error
    }
    let fileURL = resolvedRootDirectory.appending(path: String(virtualPath.dropFirst()))
      .standardizedFileURL
    let resolvedURL = fileURL.resolvingSymlinksInPath()
    guard isContainedInRoot(resolvedURL) else {
      recordAuditEvent(operation: operation, path: virtualPath, decision: .denied)
      throw CoreAgentDeepFilesystemError.escapedRoot(path: virtualPath)
    }
    let permission = permissionDecision(for: operation, path: virtualPath)
    guard let permission, permission.rule.mode == .allow else {
      let ruleIndex = permission?.index
      recordAuditEvent(
        operation: operation,
        path: virtualPath,
        decision: .denied,
        ruleIndex: ruleIndex
      )
      throw CoreAgentDeepFilesystemError.denied(operation: operation, path: virtualPath)
    }
    recordAuditEvent(
      operation: operation,
      path: virtualPath,
      decision: .allowed,
      ruleIndex: permission.index
    )
    return ResolvedPath(virtualPath: virtualPath, fileURL: resolvedURL)
  }

  private func recursiveFilePaths(from resolved: ResolvedPath) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.fileURL.path, isDirectory: &isDirectory)
    else {
      throw CoreAgentDeepFilesystemError.notFound(path: resolved.virtualPath)
    }
    guard isDirectory.boolValue else {
      throw CoreAgentDeepFilesystemError.notDirectory(path: resolved.virtualPath)
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: resolved.fileURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
      )
    else {
      return []
    }
    var paths: [String] = []
    for case let url as URL in enumerator {
      let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
      guard isContainedInRoot(resolvedURL) else { continue }
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      guard values.isRegularFile == true, values.isDirectory != true else { continue }
      let relativePath = relativeFilePath(from: resolved.fileURL, to: url)
      paths.append(joinVirtualPath(resolved.virtualPath, relativePath))
    }
    return paths
  }

  private func relativeFilePath(from baseURL: URL, to childURL: URL) -> String {
    let basePath = trimTrailingSlash(baseURL.path(percentEncoded: false))
    let childPath = childURL.path(percentEncoded: false)
    guard childPath.hasPrefix(basePath + "/") else {
      return childURL.lastPathComponent
    }
    return String(childPath.dropFirst(basePath.count + 1))
  }

  private func permissionDecision(
    for operation: CoreAgentDeepFilesystemOperation,
    path: String
  ) -> (index: Int, rule: CoreAgentDeepFilesystemPermissionRule)? {
    for (index, rule) in permissions.enumerated()
    where rule.operations.contains(operation)
      && rule.paths.contains(where: { matches($0, path) })
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

  private func isContainedInRoot(_ url: URL) -> Bool {
    let rootPath = trimTrailingSlash(resolvedRootDirectory.path(percentEncoded: false))
    let candidatePath = trimTrailingSlash(url.path(percentEncoded: false))
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func trimTrailingSlash(_ path: String) -> String {
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }

  private func normalizeVirtualPath(_ path: String) throws -> String {
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

  private func canonicalDisplayPath(_ path: String) -> String {
    path.hasPrefix("/") ? path : "/" + path
  }

  private func matches(_ pattern: String, _ path: String) -> Bool {
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

  private func globRegex(for pattern: String) -> NSRegularExpression {
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

  private func joinVirtualPath(_ directory: String, _ child: String) -> String {
    directory == "/" ? "/" + child : directory + "/" + child
  }

  private func matchesSearchPattern(_ pattern: String, base: String, candidate: String) -> Bool {
    let matchPath = pattern.hasPrefix("/") ? candidate : relativePath(from: base, to: candidate)
    return globRegex(for: pattern).firstMatch(
      in: matchPath,
      range: NSRange(location: 0, length: matchPath.utf16.count)
    ) != nil
  }

  private func matchesGrepGlob(_ glob: String, base: String, candidate: String) -> Bool {
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

  private func relativePath(from base: String, to candidate: String) -> String {
    guard base != "/" else { return String(candidate.dropFirst()) }
    guard candidate.hasPrefix(base + "/") else { return candidate }
    return String(candidate.dropFirst(base.count + 1))
  }

  private func replacement(
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

  private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }

  private func grepMatches(
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
