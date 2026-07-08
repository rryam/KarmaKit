import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentAppleCodeValue:
  Codable, Equatable, Sendable, CustomStringConvertible
{
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public var description: String {
    switch self {
    case .string(let value):
      value
    case .number(let value):
      if value.isFinite && value.rounded() == value
        && value >= Double(Int64.min) && value <= Double(Int64.max)
      {
        String(Int64(value))
      } else {
        String(value)
      }
    case .bool(let value):
      value ? "true" : "false"
    case .null:
      "null"
    }
  }
}

public enum CoreAgentAppleCodeOperand: Codable, Equatable, Sendable {
  case literal(CoreAgentAppleCodeValue)
  case variable(String)
  case input(String)
}

public enum CoreAgentAppleDeterministicInstruction: Codable, Equatable, Sendable {
  case set(String, CoreAgentAppleCodeValue)
  case add(String, CoreAgentAppleCodeOperand, CoreAgentAppleCodeOperand)
  case concatenate(String, [CoreAgentAppleCodeOperand])
  case emit(CoreAgentAppleCodeOperand)
  case output(String, CoreAgentAppleCodeOperand)
}

public struct CoreAgentAppleDeterministicProgram: Codable, Equatable, Sendable {
  public let instructions: [CoreAgentAppleDeterministicInstruction]

  public init(instructions: [CoreAgentAppleDeterministicInstruction]) {
    self.instructions = instructions
  }
}

public struct CoreAgentAppleDeterministicCodeLimits: Codable, Equatable, Sendable {
  public let maxInstructionCount: Int
  public let maxOutputBytes: Int
  public let maxInputBytes: Int
  public let maxStateBytes: Int
  public let maxValueBytes: Int
  public let maxOperandCount: Int
  public let maxVariableCount: Int
  public let maxIdentifierLength: Int

  public init(
    maxInstructionCount: Int = 64,
    maxOutputBytes: Int = 64 * 1024,
    maxInputBytes: Int = 64 * 1024,
    maxStateBytes: Int = 64 * 1024,
    maxValueBytes: Int = 16 * 1024,
    maxOperandCount: Int = 32,
    maxVariableCount: Int = 128,
    maxIdentifierLength: Int = 128
  ) {
    self.maxInstructionCount = maxInstructionCount
    self.maxOutputBytes = maxOutputBytes
    self.maxInputBytes = maxInputBytes
    self.maxStateBytes = maxStateBytes
    self.maxValueBytes = maxValueBytes
    self.maxOperandCount = maxOperandCount
    self.maxVariableCount = maxVariableCount
    self.maxIdentifierLength = maxIdentifierLength
  }
}

public struct CoreAgentAppleDeterministicCodeRequest: Codable, Equatable, Sendable {
  public let id: String
  public let program: CoreAgentAppleDeterministicProgram
  public let inputs: [String: CoreAgentAppleCodeValue]
  public let limits: CoreAgentAppleDeterministicCodeLimits

  public init(
    id: String,
    program: CoreAgentAppleDeterministicProgram,
    inputs: [String: CoreAgentAppleCodeValue] = [:],
    limits: CoreAgentAppleDeterministicCodeLimits = .init()
  ) {
    self.id = id
    self.program = program
    self.inputs = inputs
    self.limits = limits
  }
}

public enum CoreAgentAppleHelperCodeInterpreterNetworkAccess:
  String, Codable, Equatable, Sendable
{
  case none
  case localOnly
  case remote
}

public enum CoreAgentAppleCodeInterpreterFailure: Equatable, Sendable {
  case cancelled
  case backendFailed
  case instructionLimitExceeded(max: Int, actual: Int)
  case outputLimitExceeded(max: Int, actual: Int)
  case inputLimitExceeded(max: Int, actual: Int)
  case stateLimitExceeded(max: Int, actual: Int)
  case valueLimitExceeded(max: Int, actual: Int)
  case operandLimitExceeded(max: Int, actual: Int)
  case variableLimitExceeded(max: Int, actual: Int)
  case undefinedValue(String)
  case typeMismatch(operation: String)
  case invalidIdentifier(String)
  case invalidOutputName(String)
  case duplicateOutputName(String)
  case nonFiniteNumber(String)
  case invalidRequest(String)
  case executableNotAllowed(String)
  case blockedExecutableName(String)
  case workingDirectoryOutsideWorkspace(String)
  case networkAccessDenied(
    requested: CoreAgentAppleHelperCodeInterpreterNetworkAccess,
    policy: CoreAgentAppleNetworkPolicy
  )
  case stdoutLimitExceeded(max: Int, actual: Int)
  case stderrLimitExceeded(max: Int, actual: Int)
  case nonZeroExitStatus(Int32)
}

public enum CoreAgentAppleCodeInterpreterStatus: Equatable, Sendable {
  case succeeded
  case denied(CoreAgentAppleActionGateDenial)
  case failed(CoreAgentAppleCodeInterpreterFailure)
}

public struct CoreAgentAppleCodeInterpreterAudit: Equatable, Sendable {
  public let requestID: String
  public let tier: CoreAgentAppleInterpreterTier
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let startedAt: Date
  public let endedAt: Date
  public let programDigest: String
  public let inputDigest: String
  public let status: CoreAgentAppleCodeInterpreterStatus
}

public struct CoreAgentAppleCodeInterpreterResult: Equatable, Sendable {
  public let status: CoreAgentAppleCodeInterpreterStatus
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]
  public let audit: CoreAgentAppleCodeInterpreterAudit
}
