import CoreVoiceAgentCore
import Testing

@Suite("SentenceChunker")
struct SentenceChunkerTests {
  @Test("Emits the first sentence immediately for time-to-first-audio")
  func firstSentenceFlushesImmediately() {
    var chunker = SentenceChunker()
    #expect(chunker.consume(cumulativeText: "Hi") == [])
    #expect(chunker.consume(cumulativeText: "Hi there. And") == ["Hi there."])
  }

  @Test("Holds a terminator that is still the last streamed character")
  func holdsTrailingTerminator() {
    var chunker = SentenceChunker()
    // The period might be the start of an ellipsis or a decimal; the
    // chunk must not flush until at least one more character arrives.
    #expect(chunker.consume(cumulativeText: "Hello world.") == [])
    #expect(chunker.consume(cumulativeText: "Hello world. Next") == ["Hello world."])
  }

  @Test("Merges short sentences after the first chunk")
  func mergesShortSentences() {
    var chunker = SentenceChunker(
      configuration: SentenceChunkerConfiguration(minimumChunkCharacters: 25)
    )
    var chunks = chunker.consume(cumulativeText: "Sure. ")
    chunks += chunker.consume(
      cumulativeText: "Sure. Yes. No. That is a much longer sentence with detail. Tail"
    )
    #expect(chunks == ["Sure.", "Yes. No. That is a much longer sentence with detail."])
  }

  @Test("Does not split decimals, abbreviations, or initials")
  func protectsNonSentencePeriods() {
    var chunker = SentenceChunker()
    let text = "The value is 3.14 according to Dr. Smith and J. Appleseed today. More"
    let chunks = chunker.consume(cumulativeText: text)
    #expect(chunks == ["The value is 3.14 according to Dr. Smith and J. Appleseed today."])
  }

  @Test("Keeps closing quotes with their sentence")
  func keepsTrailingQuotes() {
    var chunker = SentenceChunker()
    let chunks = chunker.consume(cumulativeText: "She said \"stop.\" Then")
    #expect(chunks == ["She said \"stop.\""])
  }

  @Test("Treats newlines as hard boundaries")
  func newlineBoundaries() {
    var chunker = SentenceChunker()
    let chunks = chunker.consume(cumulativeText: "First line\nSecond line continues")
    #expect(chunks == ["First line"])
  }

  @Test("Force-flushes run-on text at a word boundary")
  func forceFlushesLongRunOnText() {
    var chunker = SentenceChunker(
      configuration: SentenceChunkerConfiguration(maximumChunkCharacters: 40)
    )
    let words = Array(repeating: "word", count: 30).joined(separator: " ")
    let chunks = chunker.consume(cumulativeText: words)
    #expect(!chunks.isEmpty)
    for chunk in chunks {
      #expect(chunk.count <= 40)
      #expect(!chunk.hasPrefix(" "))
      #expect(!chunk.hasSuffix(" "))
    }
  }

  @Test("finish() flushes the remainder exactly once")
  func finishFlushesRemainder() {
    var chunker = SentenceChunker()
    _ = chunker.consume(cumulativeText: "Complete sentence. And a tail without terminator")
    let flushed = chunker.finish()
    #expect(flushed.last == "And a tail without terminator")
    #expect(chunker.finish().isEmpty)
  }

  @Test("Chunks concatenate back to the full reply")
  func chunksReconstructReply() {
    var chunker = SentenceChunker()
    let reply =
      "Sure, I can help with that. The meeting is at 3.30 pm on Thursday. "
        + "Dr. Lee will join too! Anything else?"
    var chunks: [String] = []
    var end = reply.startIndex
    while end < reply.endIndex {
      end = reply.index(end, offsetBy: 7, limitedBy: reply.endIndex) ?? reply.endIndex
      chunks += chunker.consume(cumulativeText: String(reply[..<end]))
    }
    chunks += chunker.finish()
    let reconstructed = chunks.joined(separator: " ")
    let normalizedReply = reply.split(separator: " ").joined(separator: " ")
    #expect(reconstructed == normalizedReply)
  }

  @Test("Restarts cleanly when the snapshot regresses")
  func snapshotRegressionResets() {
    var chunker = SentenceChunker()
    _ = chunker.consume(cumulativeText: "First attempt. Some")
    let chunks = chunker.consume(cumulativeText: "Rewritten reply. Tail")
    #expect(chunks == ["Rewritten reply."])
  }
}
