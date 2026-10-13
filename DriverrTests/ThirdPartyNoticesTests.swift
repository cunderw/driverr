import Foundation
import Testing

/// The app bundle carries `THIRD-PARTY-NOTICES.md`, so the Apache, MIT and font credits travel
/// with the binary.
///
/// The file is at the repository root, outside every folder-synced group. One file reference
/// and one build file in `project.pbxproj` put it in the app's resources, and a project edit
/// that drops either one leaves the build green. The kit tier cannot see a built product.
/// `DriverrTests` is app-hosted, so `Bundle.main` here is the Driverr app.
///
/// The app does not show the file. This checks only that it ships.
@Suite("Third-party notices")
struct ThirdPartyNoticesTests {
  @Test("the app bundle holds the notices file, with each license family's text")
  func noticesShip() throws {
    let url = try #require(
      Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
      "Driverr.app has no THIRD-PARTY-NOTICES.md"
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    // One marker per license family. An empty or truncated copy fails here.
    for marker in [
      "Apache License", "The SwiftNIO Project", "Miguel de Icaza", "SIL Open Font License",
    ] {
      #expect(text.contains(marker), "the bundled notices do not contain \"\(marker)\"")
    }
  }
}
