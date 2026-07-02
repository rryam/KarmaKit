// Vendored from rudrankriyam/Core-AI-Framework-Lab (MIT), revision
// 02d7502b1e631f0773189fa2f044b52ade039aa7: NDArray helpers, the seeded
// sampler, the text normalizer, and the WAV writer.

#if canImport(CoreAI)
import CoreAI
#endif
import Foundation

#if canImport(CoreAI)
enum ChatterboxNDArray {
  static func zerosFloat16(shape: [Int]) -> NDArray {
    var array = NDArray(shape: shape, scalarType: .float16)
    var view = array.mutableView(as: Float16.self)
    view.withUnsafeMutablePointer { pointer, shape, _ in
      let count = product(shape)
      for index in 0..<count {
        pointer[index] = 0
      }
    }
    return array
  }

  static func floats(from array: NDArray) throws -> [Float] {
    switch array.scalarType {
    case .float16:
      return readFloatingPoint(array, as: Float16.self)
    case .float32:
      return readFloatingPoint(array, as: Float.self)
    default:
      throw ChatterboxEngineError.unsupportedScalarType(
        String(describing: array.scalarType)
      )
    }
  }

  static func lastLogits(from array: NDArray) throws -> [Float] {
    guard array.shape.count == 3, let sequenceLength = array.shape.dropFirst().first,
      let vocabularySize = array.shape.last, sequenceLength > 0
    else {
      throw ChatterboxEngineError.invalidOutputShape(
        "Expected logits shaped [1, sequence, vocabulary], got \(array.shape)."
      )
    }

    switch array.scalarType {
    case .float16:
      return readLastLogits(
        array,
        as: Float16.self,
        sequenceLength: sequenceLength,
        vocabularySize: vocabularySize
      )
    case .float32:
      return readLastLogits(
        array,
        as: Float.self,
        sequenceLength: sequenceLength,
        vocabularySize: vocabularySize
      )
    default:
      throw ChatterboxEngineError.unsupportedScalarType(
        String(describing: array.scalarType)
      )
    }
  }

  static func patchCache(
    _ cache: inout NDArray,
    with updates: NDArray,
    at sequenceOffset: Int
  ) throws {
    guard cache.scalarType == .float16, updates.scalarType == .float16,
      cache.shape.count == 5, updates.shape.count == 5,
      cache.shape[0] == updates.shape[0],
      cache.shape[1] == updates.shape[1],
      cache.shape[2] == updates.shape[2],
      cache.shape[4] == updates.shape[4],
      sequenceOffset >= 0,
      sequenceOffset + updates.shape[3] <= cache.shape[3]
    else {
      throw ChatterboxEngineError.invalidOutputShape(
        "The T3 key/value cache update did not match the persistent cache."
      )
    }

    var destinationView = cache.mutableView(as: Float16.self)
    updates.view(as: Float16.self).withUnsafePointer {
      source, sourceShape, sourceStrides in
      destinationView.withUnsafeMutablePointer {
        destination, _, destinationStrides in
        for layer in 0..<sourceShape[0] {
          for batch in 0..<sourceShape[1] {
            for head in 0..<sourceShape[2] {
              for position in 0..<sourceShape[3] {
                for channel in 0..<sourceShape[4] {
                  let sourceIndex =
                    layer * sourceStrides[0]
                    + batch * sourceStrides[1]
                    + head * sourceStrides[2]
                    + position * sourceStrides[3]
                    + channel * sourceStrides[4]
                  let destinationIndex =
                    layer * destinationStrides[0]
                    + batch * destinationStrides[1]
                    + head * destinationStrides[2]
                    + (sequenceOffset + position) * destinationStrides[3]
                    + channel * destinationStrides[4]
                  destination[destinationIndex] = source[sourceIndex]
                }
              }
            }
          }
        }
      }
    }
  }

  private static func readFloatingPoint<T>(
    _ array: NDArray,
    as type: T.Type
  ) -> [Float] where T: BinaryFloatingPoint & BitwiseCopyable {
    array.view(as: type).withUnsafePointer { pointer, shape, strides in
      let dimensions = (0..<shape.count).map { shape[$0] }
      let totalCount = dimensions.reduce(1, *)
      var values = [Float](repeating: 0, count: totalCount)
      for flatIndex in 0..<totalCount {
        var remaining = flatIndex
        var sourceIndex = 0
        for dimension in dimensions.indices.reversed() {
          let coordinate = remaining % dimensions[dimension]
          remaining /= dimensions[dimension]
          sourceIndex += coordinate * strides[dimension]
        }
        values[flatIndex] = Float(pointer[sourceIndex])
      }
      return values
    }
  }

  private static func readLastLogits<T>(
    _ array: NDArray,
    as type: T.Type,
    sequenceLength: Int,
    vocabularySize: Int
  ) -> [Float] where T: BinaryFloatingPoint & BitwiseCopyable {
    array.view(as: type).withUnsafePointer { pointer, _, strides in
      let sequenceOffset = (sequenceLength - 1) * strides[1]
      return (0..<vocabularySize).map {
        Float(pointer[sequenceOffset + $0 * strides[2]])
      }
    }
  }

  private static func product(_ shape: Span<Int>) -> Int {
    var result = 1
    for index in 0..<shape.count {
      result *= shape[index]
    }
    return result
  }
}
#endif

final class ChatterboxRandomGenerator: @unchecked Sendable, RandomNumberGenerator {
  private var state: UInt64
  private var spareNormal: Double?

  init(seed: UInt64) {
    state = seed
  }

  func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  func nextUnitDouble() -> Double {
    Double(next() >> 11) * 0x1.0p-53
  }

  func nextNormal() -> Double {
    if let spareNormal {
      self.spareNormal = nil
      return spareNormal
    }

    let first = max(nextUnitDouble(), Double.leastNonzeroMagnitude)
    let second = nextUnitDouble()
    let magnitude = (-2 * Foundation.log(first)).squareRoot()
    let angle = 2 * Double.pi * second
    spareNormal = magnitude * Foundation.sin(angle)
    return magnitude * Foundation.cos(angle)
  }
}

enum ChatterboxSampler {
  static func sample(
    logits: [Float],
    generatedTokens: [Int],
    random: ChatterboxRandomGenerator,
    temperature: Float = 0.8,
    topK: Int = 1_000,
    topP: Double = 0.95,
    repetitionPenalty: Float = 1.2
  ) throws -> Int {
    guard !logits.isEmpty else {
      throw ChatterboxEngineError.invalidOutputShape("The T3 logits were empty.")
    }

    let safeTemperature = max(temperature, 0.0001)
    var adjusted = logits.map { value in
      value.isFinite ? value / safeTemperature : -.infinity
    }

    for token in Set(generatedTokens) where adjusted.indices.contains(token) {
      if adjusted[token] < 0 {
        adjusted[token] *= repetitionPenalty
      } else {
        adjusted[token] /= repetitionPenalty
      }
    }

    let candidateCount = min(max(topK, 1), adjusted.count)
    let sortedIndices = adjusted.indices
      .sorted { adjusted[$0] > adjusted[$1] }
      .prefix(candidateCount)
    guard let maximum = sortedIndices.first.map({ adjusted[$0] }), maximum.isFinite else {
      throw ChatterboxEngineError.invalidOutputShape("The T3 logits were not finite.")
    }

    var candidates = [(token: Int, weight: Double)]()
    candidates.reserveCapacity(candidateCount)
    for token in sortedIndices {
      candidates.append(
        (token, Foundation.exp(Double(adjusted[token] - maximum)))
      )
    }

    let totalWeight = candidates.reduce(0) { $0 + $1.weight }
    let nucleusTarget = totalWeight * min(max(topP, 0), 1)
    var nucleus = [(token: Int, weight: Double)]()
    nucleus.reserveCapacity(candidates.count)
    var cumulativeWeight = 0.0
    for candidate in candidates {
      nucleus.append(candidate)
      cumulativeWeight += candidate.weight
      if cumulativeWeight >= nucleusTarget {
        break
      }
    }

    let draw = random.nextUnitDouble() * cumulativeWeight
    var runningWeight = 0.0
    for candidate in nucleus {
      runningWeight += candidate.weight
      if draw <= runningWeight {
        return candidate.token
      }
    }
    return nucleus.last?.token ?? candidates[0].token
  }
}

/// Chatterbox's source-parity text normalization.
public enum ChatterboxTextNormalizer {
  /// Normalizes text the way the Chatterbox reference pipeline expects:
  /// collapsed whitespace, ASCII punctuation, a leading capital, and a
  /// terminal punctuation mark.
  public static func normalize(_ source: String) -> String {
    var text = source
    if text.isEmpty {
      return "You need to add some text for me to talk."
    }

    if let first = text.first, first.isLowercase {
      text.replaceSubrange(
        text.startIndex...text.startIndex,
        with: String(first).uppercased()
      )
    }

    text =
      text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    let replacements = [
      ("…", ", "),
      (":", ","),
      ("—", "-"),
      ("–", "-"),
      (" ,", ","),
      ("\u{201C}", "\""),
      ("\u{201D}", "\""),
      ("\u{2018}", "'"),
      ("\u{2019}", "'"),
    ]
    for (source, replacement) in replacements {
      text = text.replacingOccurrences(of: source, with: replacement)
    }

    text = text.trimmingCharacters(in: .whitespaces)
    if ![".", "!", "?", "-", ","].contains(where: text.hasSuffix) {
      text.append(".")
    }
    return text
  }
}

/// A minimal 16-bit PCM WAV writer for debugging and export.
public enum ChatterboxWaveFile {
  /// Writes samples as a mono 16-bit PCM WAV file.
  public static func write(
    samples: [Float],
    sampleRate: Int,
    to url: URL
  ) throws {
    try data(samples: samples, sampleRate: sampleRate)
      .write(to: url, options: .atomic)
  }

  /// Returns samples encoded as a mono 16-bit PCM WAV payload.
  public static func data(samples: [Float], sampleRate: Int) throws -> Data {
    let bytesPerSample = 2
    guard (1...384_000).contains(sampleRate) else {
      throw ChatterboxEngineError.invalidWaveFile(
        "The WAV sample rate is outside the supported range."
      )
    }
    let (dataByteCount, dataSizeOverflow) = samples.count
      .multipliedReportingOverflow(by: bytesPerSample)
    let (riffByteCount, riffSizeOverflow) = 36.addingReportingOverflow(
      dataByteCount
    )
    let (byteRate, byteRateOverflow) = sampleRate.multipliedReportingOverflow(
      by: bytesPerSample
    )
    guard !dataSizeOverflow,
      !riffSizeOverflow,
      !byteRateOverflow,
      dataByteCount <= 200_000_000,
      riffByteCount <= Int(UInt32.max),
      dataByteCount <= Int(UInt32.max),
      byteRate <= Int(UInt32.max)
    else {
      throw ChatterboxEngineError.invalidWaveFile(
        "The generated waveform is too large for a PCM WAV file."
      )
    }
    let (reservedByteCount, reserveOverflow) = 44.addingReportingOverflow(
      dataByteCount
    )
    guard !reserveOverflow else {
      throw ChatterboxEngineError.invalidWaveFile(
        "The generated waveform exceeds the runtime integer range."
      )
    }
    var data = Data()
    data.reserveCapacity(reservedByteCount)

    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(UInt32(riffByteCount))
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(byteRate))
    data.appendLittleEndian(UInt16(bytesPerSample))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(UInt32(dataByteCount))

    for sample in samples {
      guard sample.isFinite else {
        throw ChatterboxEngineError.invalidWaveFile(
          "The generated waveform contains a non-finite sample."
        )
      }
      let clamped = min(max(sample, -1), 1)
      let pcm = Int16((clamped * Float(Int16.max)).rounded())
      data.appendLittleEndian(pcm)
    }
    return data
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) {
      append(contentsOf: $0)
    }
  }
}
