import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Synchronization
import Testing
import UIKit

@testable import Driverr

/// Where a composer's photo is sent, by the pane it was staged for (#68).
///
/// A pane on a machine a herdr-core added (`core:box/t7`) runs on that machine, not on the SSH
/// host. The host's inbox path names a file the agent there cannot open, so the photo must not
/// go through the host's uploader and that path must never be typed into such a pane.
///
/// Through `ConnectionModel`, because the routing is the composer cache's upload closure that
/// the connection wires, and `PaneComposerModel` alone is handed whatever closure it is given.
@MainActor
@Suite("Attachment routing by machine", .timeLimit(.minutes(1)))
struct PaneAttachmentMachineRoutingTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  /// What the SSH host's inbox would print. It exists only on `workbox`.
  nonisolated private static let hostInboxPath = "/home/carson/.driverr/inbox/host-only.png"

  private let machinePane = Pane(
    id: "core:box/t7",
    tabID: "core:box/tab",
    workspaceID: "core:box/workspace",
    title: "claude",
    agent: Agent(name: "Claude", kind: "claude", status: .blocked, machine: "box"),
    terminalID: "box/t7"
  )

  private let hostPane = Pane(
    id: "w1:p2",
    tabID: "w1:t1",
    workspaceID: "w1",
    title: "needs a decision",
    agent: Agent(name: "Claude", kind: "claude", status: .blocked),
    terminalID: "term_w1p2"
  )

  private func environment(
    control: FakeControl,
    hostUploads: HostUploadLog
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey])
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in control }
    environment.makeImageUpload = { _, bytes, _ in
      hostUploads.record()
      return LandedUpload(hostPath: Self.hostInboxPath, byteCount: bytes.count)
    }
    return environment
  }

  private static func pngBytes() throws -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
      UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
    return try #require(image.pngData())
  }

  /// Done either way: handed over, or refused with a sentence.
  private static func settled(_ phase: PaneAttachmentPhase?) -> Bool {
    switch phase {
    case .handedOver, .failed: true
    default: false
    }
  }

  @Test("a photo for a pane on an added machine never goes to the SSH host's inbox")
  func aMachinePanesPhotoSkipsTheHost() async throws {
    let control = FakeControl()
    let hostUploads = HostUploadLog()
    let model = ConnectionModel(
      host: workbox, environment: environment(control: control, hostUploads: hostUploads))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
    let composers = try #require(model.composers)

    let composer = composers.model(for: machinePane)
    composer.attachment.attach(try Self.pngBytes())
    await waitUntil("the machine pane's attachment settles") {
      Self.settled(composer.attachment.phase)
    }

    #expect(
      hostUploads.count == 0,
      "the photo for core:box/t7 was uploaded to the SSH host, not to box")
    #expect(
      !(await control.sent).contains(.text(paneID: machinePane.id, text: Self.hostInboxPath)),
      "the SSH host's inbox path was typed into a pane on box, where no such file exists")
  }

  /// The control: a pane on the SSH host itself still uses the host's uploader and gets its path.
  @Test("a photo for a pane on the SSH host still lands in the host's inbox")
  func aHostPanesPhotoStillUsesTheHost() async throws {
    let control = FakeControl()
    let hostUploads = HostUploadLog()
    let model = ConnectionModel(
      host: workbox, environment: environment(control: control, hostUploads: hostUploads))
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    let composers = try #require(model.composers)

    let composer = composers.model(for: hostPane)
    composer.attachment.attach(try Self.pngBytes())
    await waitUntil("the host pane's attachment settles") {
      Self.settled(composer.attachment.phase)
    }

    #expect(composer.attachment.phase == .handedOver)
    #expect(hostUploads.count == 1)
    #expect(await control.sent == [.text(paneID: hostPane.id, text: Self.hostInboxPath)])
  }
}

/// Counts uploads made through the SSH host's uploader. Read on the main actor after the wait.
final class HostUploadLog: Sendable {
  private let calls = Mutex(0)
  var count: Int { calls.withLock { $0 } }
  func record() { calls.withLock { $0 += 1 } }
}

/// An upload that lands at once at a fixed host path.
private struct LandedUpload: ImageUploading {
  let progress: AsyncStream<ImageUploadProgress>
  private let signal: AsyncStream<ImageUploadProgress>.Continuation
  private let hostPath: String
  private let byteCount: Int

  init(hostPath: String, byteCount: Int) {
    self.hostPath = hostPath
    self.byteCount = byteCount
    (progress, signal) = AsyncStream.makeStream(of: ImageUploadProgress.self)
  }

  func upload() async throws -> ImageUploadOutcome {
    signal.yield(ImageUploadProgress(bytesSent: byteCount, totalBytes: byteCount))
    signal.finish()
    return ImageUploadOutcome(hostPath: hostPath, bytesSent: byteCount)
  }
}
