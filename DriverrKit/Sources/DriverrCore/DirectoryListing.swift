import Foundation

public struct DirectoryListing: Hashable, Sendable {
  public static let entryLimit = 500
  public let path: String
  public let names: [String]
  public let isTruncated: Bool

  public static func command(for path: String) -> String { "" }

  public static func parse(_ result: CommandResult, requestedPath: String) throws -> DirectoryListing {
    DirectoryListing(path: "", names: [], isTruncated: false)
  }

  public func childPath(_ name: String) -> String { "" }
}
