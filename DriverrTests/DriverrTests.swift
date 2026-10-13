import Testing
import DriverrCore

@Suite("App wiring")
struct AppWiringTests {
  @Test("the app target links DriverrCore")
  func linksDriverrCore() {
    let host = Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
    #expect(host.displayName == "workbox")
  }
}
