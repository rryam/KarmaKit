import CryptoKit
import Foundation
import FoundationModels

public enum CoreAgentArgumentAudit {
  private static let sensitiveKeyMarkers = [
    "authorization",
    "api_key",
    "apikey",
    "token",
    "secret",
    "password",
    "credential",
  ]

  public static func digest(_ content: GeneratedContent) -> String {
    SHA256.hash(data: Data(canonicalJSONString(content).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  public static func redactedJSONString(_ content: GeneratedContent) -> String {
    let source = content.jsonString
    guard let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      )
    else {
      return source
    }

    let redacted = redactJSONObject(object)
    guard JSONSerialization.isValidJSONObject(redacted),
      let encoded = try? JSONSerialization.data(
        withJSONObject: redacted,
        options: [.sortedKeys]
      )
    else {
      return source
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  private static func redactJSONObject(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]:
      return dictionary.reduce(into: [String: Any]()) { result, element in
        if isSensitiveKey(element.key) {
          result[element.key] = "[REDACTED]"
        } else {
          result[element.key] = redactJSONObject(element.value)
        }
      }
    case let array as [Any]:
      return array.map(redactJSONObject)
    default:
      return value
    }
  }

  private static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.lowercased()
    return sensitiveKeyMarkers.contains { normalized.contains($0) }
  }

  private static func canonicalJSONString(_ content: GeneratedContent) -> String {
    let source = content.jsonString
    guard let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      ),
      let encoded = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .fragmentsAllowed]
      )
    else {
      return source
    }
    return String(decoding: encoded, as: UTF8.self)
  }
}
