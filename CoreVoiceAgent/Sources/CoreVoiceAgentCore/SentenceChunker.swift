import Foundation

/// Splits a streamed assistant reply into sentence-sized chunks for
/// pipelined synthesis.
///
/// The chunker consumes cumulative snapshots of the reply (Foundation
/// Models streaming semantics: each partial contains the full text so
/// far) and emits each chunk exactly once, as soon as it is safely
/// complete. The first chunk of a reply flushes on the first finished
/// sentence regardless of length, which is what keeps time-to-first-audio
/// low; later chunks may merge short sentences to avoid choppy synthesis.
public struct SentenceChunker: Sendable {
  private let configuration: SentenceChunkerConfiguration

  /// Offset into the cumulative text that has already been emitted.
  private var consumedOffset: String.Index?
  private var lastSnapshot: String = ""
  private var emittedChunkCount = 0

  private static let terminators: Set<Character> = [".", "!", "?", "…"]
  /// Characters that may trail a terminator and still belong to the
  /// sentence (closing quotes and brackets).
  private static let trailers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
  /// Abbreviations that end with a period but do not end a sentence.
  private static let abbreviations: Set<String> = [
    "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "etc",
    "e.g", "i.e", "approx", "dept", "fig", "no", "inc", "ltd", "co",
  ]

  public init(configuration: SentenceChunkerConfiguration = SentenceChunkerConfiguration()) {
    self.configuration = configuration
  }

  /// Consume the latest cumulative snapshot and return newly completed
  /// chunks, oldest first.
  public mutating func consume(cumulativeText: String) -> [String] {
    // Streaming snapshots only ever grow. If the text regressed (a retry
    // rewrote the reply), start over rather than emit stale offsets.
    if !cumulativeText.hasPrefix(lastSnapshot) {
      consumedOffset = nil
      emittedChunkCount = 0
    }
    lastSnapshot = cumulativeText

    var chunks: [String] = []
    while let chunk = nextChunk(in: cumulativeText, isFinal: false) {
      chunks.append(chunk)
    }
    return chunks
  }

  /// Flush any remaining text once the reply is complete.
  public mutating func finish() -> [String] {
    let text = lastSnapshot
    var chunks: [String] = []
    while let chunk = nextChunk(in: text, isFinal: true) {
      chunks.append(chunk)
    }
    consumedOffset = nil
    lastSnapshot = ""
    emittedChunkCount = 0
    return chunks
  }

  private mutating func nextChunk(in text: String, isFinal: Bool) -> String? {
    let start = consumedOffset ?? text.startIndex
    guard start < text.endIndex else { return nil }

    let remainder = text[start...]
    let minimum = emittedChunkCount == 0 ? 1 : configuration.minimumChunkCharacters

    if let boundary = sentenceBoundary(in: remainder, minimumLength: minimum, isFinal: isFinal) {
      return emit(text, from: start, to: boundary)
    }

    // No safe sentence boundary. Force a flush at a word boundary if the
    // pending text exceeded the synthesizer budget, or emit everything on
    // finish.
    if remainder.count >= configuration.maximumChunkCharacters {
      let boundary = wordBoundary(in: remainder) ?? remainder.endIndex
      return emit(text, from: start, to: boundary)
    }
    if isFinal {
      let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
      consumedOffset = text.endIndex
      return trimmed.isEmpty ? nil : trimmed
    }
    return nil
  }

  private mutating func emit(
    _ text: String,
    from start: String.Index,
    to boundary: String.Index
  ) -> String? {
    consumedOffset = boundary
    let chunk = text[start..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chunk.isEmpty else { return nil }
    emittedChunkCount += 1
    return chunk
  }

  /// Find the end index (exclusive) of the first complete sentence in
  /// `slice` whose length is at least `minimumLength`.
  ///
  /// A terminator only counts once at least one more character follows it
  /// in the stream (or the reply is final): a period that is currently the
  /// last streamed character might be the start of an ellipsis or a
  /// decimal, and cutting there would race the model.
  private func sentenceBoundary(
    in slice: Substring,
    minimumLength: Int,
    isFinal: Bool
  ) -> String.Index? {
    var index = slice.startIndex
    while index < slice.endIndex {
      let character = slice[index]
      let next = slice.index(after: index)

      // Newlines are hard boundaries: list items and paragraphs read as
      // separate utterances.
      if character == "\n" {
        if slice.distance(from: slice.startIndex, to: index) + 1 >= minimumLength {
          return next
        }
        index = next
        continue
      }

      guard Self.terminators.contains(character) else {
        index = next
        continue
      }

      // Swallow closing quotes/brackets that belong to this sentence.
      var end = next
      while end < slice.endIndex, Self.trailers.contains(slice[end]) {
        end = slice.index(after: end)
      }

      guard end < slice.endIndex || isFinal else { return nil }
      let length = slice.distance(from: slice.startIndex, to: end)
      if length >= minimumLength,
        isSentenceEnd(slice, terminator: index, boundary: end)
      {
        return end
      }
      index = end > next ? end : next
    }
    return nil
  }

  private func isSentenceEnd(
    _ slice: Substring,
    terminator: String.Index,
    boundary: String.Index
  ) -> Bool {
    let character = slice[terminator]

    if character == "." {
      // Decimal number: digit on both sides.
      let after = slice.index(after: terminator)
      if terminator > slice.startIndex, after < slice.endIndex {
        let before = slice.index(before: terminator)
        if slice[before].isNumber && slice[after].isNumber {
          return false
        }
      }
      // Known abbreviation directly before the period.
      let word = trailingWord(in: slice, before: terminator)
      if Self.abbreviations.contains(word.lowercased()) {
        return false
      }
      // Single-letter initial such as "J." in "J. Appleseed".
      if word.count == 1, word.first?.isUppercase == true {
        return false
      }
    }

    // Whatever follows must begin a new sentence: whitespace, or end of
    // the available text.
    if boundary < slice.endIndex {
      return slice[boundary].isWhitespace
    }
    return true
  }

  private func trailingWord(
    in slice: Substring,
    before index: String.Index
  ) -> String {
    var start = index
    while start > slice.startIndex {
      let previous = slice.index(before: start)
      let character = slice[previous]
      if character.isLetter || character == "." {
        start = previous
      } else {
        break
      }
    }
    var word = String(slice[start..<index])
    // "e.g." arrives as "e.g" plus the terminator being inspected.
    while word.hasSuffix(".") {
      word.removeLast()
    }
    return word
  }

  private func wordBoundary(in slice: Substring) -> String.Index? {
    let limit =
      slice.index(
        slice.startIndex,
        offsetBy: configuration.maximumChunkCharacters,
        limitedBy: slice.endIndex
      ) ?? slice.endIndex
    var index = limit
    while index > slice.startIndex {
      let previous = slice.index(before: index)
      if slice[previous].isWhitespace {
        return index
      }
      index = previous
    }
    return limit == slice.startIndex ? nil : limit
  }
}
