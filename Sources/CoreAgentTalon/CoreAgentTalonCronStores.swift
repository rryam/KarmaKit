import Foundation

public actor InMemoryCoreAgentTalonCronJobStore: CoreAgentTalonCronJobStore {
  private var jobs: [CoreAgentTalonCronJob]

  public init(jobs: [CoreAgentTalonCronJob] = []) {
    self.jobs = jobs
  }

  public func loadJobs() async throws -> [CoreAgentTalonCronJob] {
    jobs
  }

  public func saveJobs(_ jobs: [CoreAgentTalonCronJob]) async throws {
    self.jobs = jobs
  }
}

public actor FileCoreAgentTalonCronJobStore: CoreAgentTalonCronJobStore {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func loadJobs() async throws -> [CoreAgentTalonCronJob] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([CoreAgentTalonCronJob].self, from: data)
  }

  public func saveJobs(_ jobs: [CoreAgentTalonCronJob]) async throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(jobs)
    try data.write(to: fileURL, options: [.atomic])
  }
}
