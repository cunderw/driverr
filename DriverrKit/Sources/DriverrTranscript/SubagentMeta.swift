import DriverrCore
import Foundation

/// A sub-agent's `agent-<agentId>.meta.json`, as Claude Code writes it. Every field is
/// optional, so an unknown or missing key cannot drop the row. See `SubagentSummary` for
/// which spawns write which fields.
struct SubagentMeta: Decodable {
  let agentType: String?
  let spawnedAgentType: String?
  let customAgentType: String?
  let description: String?
  let name: String?
  let toolUseId: String?
  let finished: Bool?

  /// The wire record as a `DriverrCore` value.
  ///
  /// **A teammate's `agentType` is its name**, so its type comes from `spawnedAgentType` or
  /// `customAgentType`, and an `agentType` equal to the name is dropped.
  func summary(id: String, spawnedAt: Date?, writtenAt: Date?) -> SubagentSummary {
    let name = Self.nonEmpty(self.name)
    let declared = Self.nonEmpty(agentType)
    let type =
      Self.nonEmpty(spawnedAgentType) ?? Self.nonEmpty(customAgentType)
      ?? (declared == name ? nil : declared)
    return SubagentSummary(
      id: id,
      name: name,
      description: Self.nonEmpty(description),
      agentType: type,
      toolUseID: Self.nonEmpty(toolUseId),
      isFinished: finished == true,
      spawnedAt: spawnedAt,
      writtenAt: writtenAt
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
