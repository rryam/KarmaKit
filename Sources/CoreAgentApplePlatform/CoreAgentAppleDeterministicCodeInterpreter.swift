import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public struct CoreAgentAppleDeterministicCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.clock = clock
  }

  public func run(
    _ request: CoreAgentAppleDeterministicCodeRequest
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let programDigest = Self.digest(request.program)
    let inputDigest = Self.digest(request.inputs)
    let gateDecision = actionGate.evaluate(
      .codeInterpreter(tier: .deterministicInProcess),
      consent: .notRequired
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }
    if Task.isCancelled {
      return failed(
        .cancelled,
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        stdout: "",
        outputs: [:]
      )
    }
    guard request.program.instructions.count <= request.limits.maxInstructionCount else {
      return result(
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: .failed(
          .instructionLimitExceeded(
            max: request.limits.maxInstructionCount,
            actual: request.program.instructions.count
          )),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }
    if let failure = Self.validateRequest(request) {
      return failed(
        failure,
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        stdout: "",
        outputs: [:]
      )
    }

    var variables: [String: CoreAgentAppleCodeValue] = [:]
    var stdout = ""
    var outputs: [String: CoreAgentAppleCodeValue] = [:]
    for instruction in request.program.instructions {
      if Task.isCancelled {
        return failed(
          .cancelled,
          request: request,
          startedAt: startedAt,
          programDigest: programDigest,
          inputDigest: inputDigest,
          stdout: stdout,
          outputs: outputs
        )
      }
      switch instruction {
      case .set(let name, let value):
        if let failure = Self.assignmentFailure(
          name: name,
          value: value,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = value
      case .add(let name, let lhs, let rhs):
        guard case .number(let lhsValue) = resolve(lhs, variables: variables, request: request),
          case .number(let rhsValue) = resolve(rhs, variables: variables, request: request)
        else {
          return failed(
            .typeMismatch(operation: "add"),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let value = lhsValue + rhsValue
        guard value.isFinite else {
          return failed(
            .nonFiniteNumber(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let codeValue = CoreAgentAppleCodeValue.number(value)
        if let failure = Self.assignmentFailure(
          name: name,
          value: codeValue,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = codeValue
      case .concatenate(let name, let operands):
        var combined = ""
        for operand in operands {
          guard let value = resolve(operand, variables: variables, request: request) else {
            return failed(
              .undefinedValue(name),
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          if let failure = Self.valueFailure(value, label: name, limits: request.limits) {
            return failed(
              failure,
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          let actualBytes = combined.utf8.count + value.description.utf8.count
          guard actualBytes <= request.limits.maxValueBytes else {
            return failed(
              .valueLimitExceeded(max: request.limits.maxValueBytes, actual: actualBytes),
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          combined += value.description
        }
        let value = CoreAgentAppleCodeValue.string(combined)
        if let failure = Self.assignmentFailure(
          name: name,
          value: value,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = value
      case .emit(let operand):
        guard let value = resolve(operand, variables: variables, request: request) else {
          return failed(
            .undefinedValue(String(describing: operand)),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        if let failure = Self.valueFailure(value, label: "emit", limits: request.limits) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let candidate = stdout + value.description + "\n"
        let actualOutputBytes = Self.outputByteCount(stdout: candidate, outputs: outputs)
        guard actualOutputBytes <= request.limits.maxOutputBytes else {
          return failed(
            .outputLimitExceeded(max: request.limits.maxOutputBytes, actual: actualOutputBytes),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        stdout = candidate
      case .output(let name, let operand):
        guard Self.isValidOutputName(name, maxLength: request.limits.maxIdentifierLength) else {
          return failed(
            .invalidOutputName(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        guard outputs[name] == nil else {
          return failed(
            .duplicateOutputName(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        guard let value = resolve(operand, variables: variables, request: request) else {
          return failed(
            .undefinedValue(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        if let failure = Self.valueFailure(value, label: name, limits: request.limits) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        var candidateOutputs = outputs
        candidateOutputs[name] = value
        let actualOutputBytes = Self.outputByteCount(stdout: stdout, outputs: candidateOutputs)
        guard actualOutputBytes <= request.limits.maxOutputBytes else {
          return failed(
            .outputLimitExceeded(max: request.limits.maxOutputBytes, actual: actualOutputBytes),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        outputs = candidateOutputs
      }
    }
    return result(
      request: request,
      startedAt: startedAt,
      programDigest: programDigest,
      inputDigest: inputDigest,
      status: .succeeded,
      stdout: stdout,
      stderr: "",
      outputs: outputs
    )
  }

  private func resolve(
    _ operand: CoreAgentAppleCodeOperand,
    variables: [String: CoreAgentAppleCodeValue],
    request: CoreAgentAppleDeterministicCodeRequest
  ) -> CoreAgentAppleCodeValue? {
    switch operand {
    case .literal(let value):
      value
    case .variable(let name):
      variables[name]
    case .input(let name):
      request.inputs[name]
    }
  }

  private func failed(
    _ failure: CoreAgentAppleCodeInterpreterFailure,
    request: CoreAgentAppleDeterministicCodeRequest,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    stdout: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    result(
      request: request,
      startedAt: startedAt,
      programDigest: programDigest,
      inputDigest: inputDigest,
      status: .failed(failure),
      stdout: stdout,
      stderr: failure.description,
      outputs: outputs
    )
  }

  private func result(
    request: CoreAgentAppleDeterministicCodeRequest,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    let endedAt = clock()
    return CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: request.id,
        tier: .deterministicInProcess,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: endedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func validateRequest(
    _ request: CoreAgentAppleDeterministicCodeRequest
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    for (name, value) in request.inputs {
      guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
        return .invalidIdentifier("input:\(name)")
      }
      if let failure = valueFailure(value, label: "input:\(name)", limits: request.limits) {
        return failure
      }
    }
    let actualInputBytes = inputByteCount(request.inputs)
    guard actualInputBytes <= request.limits.maxInputBytes else {
      return .inputLimitExceeded(max: request.limits.maxInputBytes, actual: actualInputBytes)
    }

    for instruction in request.program.instructions {
      switch instruction {
      case .set(let name, let value):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        if let failure = valueFailure(value, label: name, limits: request.limits) {
          return failure
        }
      case .add(let name, let lhs, let rhs):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        if let failure = validateOperand(lhs, limits: request.limits) {
          return failure
        }
        if let failure = validateOperand(rhs, limits: request.limits) {
          return failure
        }
      case .concatenate(let name, let operands):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        guard operands.count <= request.limits.maxOperandCount else {
          return .operandLimitExceeded(
            max: request.limits.maxOperandCount,
            actual: operands.count
          )
        }
        for operand in operands {
          if let failure = validateOperand(operand, limits: request.limits) {
            return failure
          }
        }
      case .emit(let operand):
        if let failure = validateOperand(operand, limits: request.limits) {
          return failure
        }
      case .output(let name, let operand):
        guard isValidOutputName(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidOutputName(name)
        }
        if let failure = validateOperand(operand, limits: request.limits) {
          return failure
        }
      }
    }
    return nil
  }

  private static func validateOperand(
    _ operand: CoreAgentAppleCodeOperand,
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    switch operand {
    case .literal(let value):
      valueFailure(value, label: "literal", limits: limits)
    case .variable(let name):
      isValidIdentifier(name, maxLength: limits.maxIdentifierLength)
        ? nil
        : .invalidIdentifier("variable:\(name)")
    case .input(let name):
      isValidIdentifier(name, maxLength: limits.maxIdentifierLength)
        ? nil
        : .invalidIdentifier("input:\(name)")
    }
  }

  private static func assignmentFailure(
    name: String,
    value: CoreAgentAppleCodeValue,
    variables: [String: CoreAgentAppleCodeValue],
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    if let failure = valueFailure(value, label: name, limits: limits) {
      return failure
    }
    let actualVariableCount = variables[name] == nil ? variables.count + 1 : variables.count
    guard actualVariableCount <= limits.maxVariableCount else {
      return .variableLimitExceeded(max: limits.maxVariableCount, actual: actualVariableCount)
    }
    var candidateVariables = variables
    candidateVariables[name] = value
    let actualStateBytes = stateByteCount(candidateVariables)
    guard actualStateBytes <= limits.maxStateBytes else {
      return .stateLimitExceeded(max: limits.maxStateBytes, actual: actualStateBytes)
    }
    return nil
  }

  private static func valueFailure(
    _ value: CoreAgentAppleCodeValue,
    label: String,
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !value.isNonFiniteNumber else {
      return .nonFiniteNumber(label)
    }
    let actualValueBytes = valueByteCount(value)
    guard actualValueBytes <= limits.maxValueBytes else {
      return .valueLimitExceeded(max: limits.maxValueBytes, actual: actualValueBytes)
    }
    return nil
  }

  private static func inputByteCount(_ inputs: [String: CoreAgentAppleCodeValue]) -> Int {
    inputs.reduce(0) { total, entry in
      total + entry.key.utf8.count + valueByteCount(entry.value)
    }
  }

  private static func stateByteCount(_ variables: [String: CoreAgentAppleCodeValue]) -> Int {
    variables.reduce(0) { total, entry in
      total + entry.key.utf8.count + valueByteCount(entry.value)
    }
  }

  private static func valueByteCount(_ value: CoreAgentAppleCodeValue) -> Int {
    value.description.utf8.count
  }

  private static func outputByteCount(
    stdout: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> Int {
    stdout.utf8.count
      + outputs.reduce(0) { total, entry in
        total + entry.key.utf8.count + entry.value.description.utf8.count
      }
  }

  private static func isValidIdentifier(_ name: String, maxLength: Int) -> Bool {
    guard !name.isEmpty, name.utf8.count <= maxLength else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || ("a"..."z").contains(scalar)
        || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
  }

  private static func isValidOutputName(_ name: String, maxLength: Int) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == name, !name.isEmpty, name.utf8.count <= maxLength,
      name != ".", name != ".."
    else {
      return false
    }
    guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || scalar == "-" || scalar == "."
        || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar)
    }
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension CoreAgentAppleCodeValue {
  fileprivate var isNonFiniteNumber: Bool {
    if case .number(let value) = self {
      return !value.isFinite
    }
    return false
  }
}

extension CoreAgentAppleCodeInterpreterFailure {
  fileprivate var description: String {
    switch self {
    case .cancelled:
      "cancelled"
    case .backendFailed:
      "backend failed"
    case .instructionLimitExceeded(let max, let actual):
      "instruction limit exceeded: max=\(max) actual=\(actual)"
    case .outputLimitExceeded(let max, let actual):
      "output limit exceeded: max=\(max) actual=\(actual)"
    case .inputLimitExceeded(let max, let actual):
      "input limit exceeded: max=\(max) actual=\(actual)"
    case .stateLimitExceeded(let max, let actual):
      "state limit exceeded: max=\(max) actual=\(actual)"
    case .valueLimitExceeded(let max, let actual):
      "value limit exceeded: max=\(max) actual=\(actual)"
    case .operandLimitExceeded(let max, let actual):
      "operand limit exceeded: max=\(max) actual=\(actual)"
    case .variableLimitExceeded(let max, let actual):
      "variable limit exceeded: max=\(max) actual=\(actual)"
    case .undefinedValue(let name):
      "undefined value: \(name)"
    case .typeMismatch(let operation):
      "type mismatch for operation: \(operation)"
    case .invalidIdentifier(let name):
      "invalid identifier: \(name)"
    case .invalidOutputName(let name):
      "invalid output name: \(name)"
    case .duplicateOutputName(let name):
      "duplicate output name: \(name)"
    case .nonFiniteNumber(let name):
      "non-finite number: \(name)"
    case .invalidRequest(let reason):
      "invalid request: \(reason)"
    case .executableNotAllowed(let path):
      "executable not allowed: \(path)"
    case .blockedExecutableName(let name):
      "blocked executable name: \(name)"
    case .workingDirectoryOutsideWorkspace(let path):
      "working directory outside workspace: \(path)"
    case .networkAccessDenied(let requested, let policy):
      "network access denied: requested=\(requested.rawValue) policy=\(policy.rawValue)"
    case .stdoutLimitExceeded(let max, let actual):
      "stdout limit exceeded: max=\(max) actual=\(actual)"
    case .stderrLimitExceeded(let max, let actual):
      "stderr limit exceeded: max=\(max) actual=\(actual)"
    case .nonZeroExitStatus(let exitCode):
      "non-zero exit status: \(exitCode)"
    }
  }
}
