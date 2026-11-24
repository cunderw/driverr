import Foundation
import Testing

/// The app bundle carries no `.entitlements` file.
///
/// `Driverr/Driverr.entitlements` and `DriverrWatch/DriverrWatch.entitlements` sit inside
/// folder-synced groups, and their only consumer is `CODE_SIGN_ENTITLEMENTS`. The build does
/// not copy them, and the project has no exclusion that says so, because an `xcrun xcodeproj
/// setting set` write deleted both. A copy in the product would be wrong and invisible: it
/// collides with nothing and the build stays green. `DriverrTests` is app-hosted, so
/// `Bundle.main` here is the Driverr app, and the walk also covers the widget extension.
@Suite("Bundled entitlements")
struct BundledEntitlementsTests {
  @Test("the app bundle holds no .entitlements file")
  func noEntitlementsShip() throws {
    let root = Bundle.main.bundleURL
    #expect(root.pathExtension == "app", "Bundle.main is not the app: \(root.path)")
    let walker = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
      "cannot walk \(root.path)"
    )
    var shipped: [String] = []
    var seen = 0
    for case let url as URL in walker {
      seen += 1
      if url.pathExtension == "entitlements" {
        shipped.append(String(url.path.dropFirst(root.path.count)))
      }
    }
    #expect(seen > 0, "walked nothing under \(root.path)")
    #expect(shipped.isEmpty, "Driverr.app ships entitlements files: \(shipped)")
  }
}
