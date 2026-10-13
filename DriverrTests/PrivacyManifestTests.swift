import Foundation
import Testing

/// The app and the widget extension each ship their own privacy manifest.
///
/// Nothing in the project file names either one. Both are plain files in folder-synced groups,
/// so a move, a rename or a new membership exception drops a manifest from its product and the
/// build stays green. The kit tier cannot see a built product. `DriverrTests` is app-hosted, so
/// `Bundle.main` here is the Driverr app with `DriverrWatch.appex` embedded in it.
///
/// The declared reasons are pinned per bundle because the two files share a name: a build that
/// put the app's manifest in the extension would pass a check for the file alone.
@Suite("Privacy manifest")
struct PrivacyManifestTests {
  private static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
  private static let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"

  private func manifest(at url: URL?, in product: String) throws -> [String: Any] {
    let url = try #require(url, "\(product) has no PrivacyInfo.xcprivacy")
    let data = try #require(
      FileManager.default.contents(atPath: url.path),
      "\(product) has no PrivacyInfo.xcprivacy at \(url.path)"
    )
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: Any], "\(product)'s manifest is not a dictionary")
  }

  /// Category to reason codes, as the manifest declares them.
  private func accessedAPIReasons(in manifest: [String: Any]) throws -> [String: Set<String>] {
    let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    var reasons: [String: Set<String>] = [:]
    for entry in entries {
      let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
      let codes = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
      reasons[category, default: []].formUnion(codes)
    }
    return reasons
  }

  /// `docs/appstore/privacy.md` says Driverr collects nothing, and the manifest has to agree.
  private func expectNoTrackingAndNoCollectedData(_ manifest: [String: Any], in product: String) {
    #expect(manifest["NSPrivacyTracking"] as? Bool == false, "\(product) declares tracking")
    #expect(
      (manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true,
      "\(product) declares tracking domains"
    )
    #expect(
      (manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true,
      "\(product) declares collected data"
    )
  }

  @Test("the app bundle holds its manifest")
  func appManifestShips() throws {
    let manifest = try manifest(
      at: Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
      in: "Driverr.app"
    )
    expectNoTrackingAndNoCollectedData(manifest, in: "Driverr.app")
    #expect(
      try accessedAPIReasons(in: manifest) == [
        Self.userDefaults: ["CA92.1", "1C8F.1"],
        Self.fileTimestamp: ["DDA9.1", "C617.1"],
      ]
    )
  }

  @Test("the widget extension inside the app holds its own manifest")
  func widgetManifestShips() throws {
    let manifest = try manifest(
      at: Bundle.main.builtInPlugInsURL?
        .appendingPathComponent("DriverrWatch.appex/PrivacyInfo.xcprivacy"),
      in: "DriverrWatch.appex"
    )
    expectNoTrackingAndNoCollectedData(manifest, in: "DriverrWatch.appex")
    // The file timestamp entry is for `AppBuildStamp`, which `DriverrCore` links into the
    // extension's binary. The extension does not call it.
    #expect(
      try accessedAPIReasons(in: manifest) == [
        Self.userDefaults: ["1C8F.1"],
        Self.fileTimestamp: ["C617.1"],
      ]
    )
  }
}
