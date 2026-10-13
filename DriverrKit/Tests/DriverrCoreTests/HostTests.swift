import Testing
@testable import DriverrCore

@Suite("Host")
struct HostTests {
  @Test("displayName prefers the user-given name")
  func displayNameUsesName() {
    let host = Host(name: "workbox", hostname: "10.1.0.9", port: 22, username: "carson")
    #expect(host.displayName == "workbox")
  }

  @Test("displayName falls back to user@hostname when name is blank")
  func displayNameFallsBack() {
    let host = Host(name: "  ", hostname: "10.1.0.9", port: 22, username: "carson")
    #expect(host.displayName == "carson@10.1.0.9")
  }

  @Test("port defaults to 22")
  func defaultPort() {
    let host = Host(name: "box", hostname: "example.com", username: "carson")
    #expect(host.port == 22)
  }
}
