import CoreAgentTalon
import Foundation
import Testing

@Suite("CoreAgentTalon events")
struct TalonEventTests {
  @Test("Encodes talon_event records deterministically and round-trips them")
  func eventEncodesDeterministically() throws {
    let event = CoreAgentTalonEvent(
      id: "talon_event:0",
      sequence: 0,
      source: .host,
      timestamp: Date(timeIntervalSince1970: 0),
      conversationID: CoreAgentTalonConversationID("conversation-a"),
      payload: .run(
        CoreAgentTalonRunEvent(
          transition: .started,
          status: .running
        )
      )
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(event)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(
      json
        == """
        {"conversationID":"conversation-a","id":"talon_event:0","payload":{"kind":"run","run":{"status":"running","transition":"started"}},"sequence":0,"source":"host","timestamp":0,"type":"talon_event"}
        """)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(try decoder.decode(CoreAgentTalonEvent.self, from: data) == event)
  }
}
