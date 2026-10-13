import DriverrCore
import DriverrSSH
import Foundation
import Observation
import Testing
import UIKit

@testable import Driverr

/// What makes a connection outlive the screen that opened it.
///
/// The registry owns each `ConnectionModel`, so `.id(host.id)` on the host screen, or a pop
/// back to the host list, does not take the connection down with the view.
/// `HostConnectUITests.testAHostStaysConnectedWhileYouVisitAnother` shows the host screen
/// reads its model from here.
///
/// The memory-warning tests post to a centre of their own. A warning on
/// `NotificationCenter.default` reaches every registry and terminal scene in the process,
/// including other suites' running in parallel.
@MainActor
@Suite("ConnectionRegistry", .serialized, .timeLimit(.minutes(1)))
struct ConnectionRegistryTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let edge = DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root")

  /// `.ephemeral` with both hosts' keys already trusted.
  ///
  /// Seeded, or TOFU raises a prompt nobody answers and the connect hangs instead of failing.
  private func environment() -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [
        workbox.hostname: FakeSSHTransport.defaultHostKey,
        edge.hostname: FakeSSHTransport.defaultHostKey,
      ]
    )
    return environment
  }

  /// The shared `waitUntil` in `TestWaker.swift`, on a private waker. Both things this file
  /// waits on, `ConnectionModel.phase` and `InteractiveHostKeyPrompt.pending`, are
  /// `@Observable`. Keep the `Task.isCancelled` check; see `Waker`.
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let waker = Waker()
    while true {
      let seen = waker.generation
      var satisfied = false
      withObservationTracking {
        satisfied = condition()
      } onChange: {
        waker.signalFromAnywhere()
      }
      if satisfied { return }
      await waker.next(after: seen)
      if Task.isCancelled {
        Issue.record(
          "waitUntil was cancelled before its condition ever held",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  /// The model closes over the `Host` it was built with, so an edited host needs a new model,
  /// or the next connect goes to the old address.
  ///
  /// Asserted against the transport: where the connection went is the claim.
  @Test("editing a host's port sends the next connection to the new port")
  func editedPortReachesTheConnection() async {
    let transport = FakeSSHTransport()
    var environment = environment()
    // One transport for every connect, so the attempts accumulate in one place.
    environment.makeTransport = { transport }
    let registry = ConnectionRegistry()

    let original = registry.model(for: workbox, environment: environment)
    await original.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(original.phase == .connected)
    await original.disconnect()

    var edited = workbox
    edited.port = 2222
    let updated = registry.model(for: edited, environment: environment)
    #expect(updated !== original, "an edited host kept the model bound to its old address")
    await updated.connect(password: "hunter2", persistence: .promptEveryTime)

    let ports = await transport.connectionAttempts.map(\.port)
    #expect(ports == [22, 2222])
  }

  /// The limit on the rule above. A connecting or connected model owns a live socket and a
  /// session, so an edit reaches it on the next disconnect, the first moment the new address
  /// could be used.
  @Test("editing a host that is connected does not strand its live connection")
  func editingAConnectedHostKeepsItsConnection() async {
    let registry = ConnectionRegistry()
    let environment = environment()
    let original = registry.model(for: workbox, environment: environment)
    await original.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(original.phase == .connected)

    var edited = workbox
    edited.port = 2222

    #expect(registry.model(for: edited, environment: environment) === original)
    #expect(original.phase == .connected)
  }

  @Test("asking twice for one host gives back the same connection")
  func oneModelPerHost() {
    let registry = ConnectionRegistry()
    let environment = environment()

    let first = registry.model(for: workbox, environment: environment)
    let second = registry.model(for: workbox, environment: environment)

    #expect(first === second, "the host screen would rebuild onto a fresh connection")
  }

  @Test("two hosts get two connections")
  func oneModelPerHostNotOnePerApp() {
    // The second host must not inherit the first's connection.
    let registry = ConnectionRegistry()
    let environment = environment()

    #expect(
      registry.model(for: workbox, environment: environment)
        !== registry.model(for: edge, environment: environment)
    )
  }

  @Test("a connection survives the screen that opened it")
  func connectionOutlivesTheScreen() async {
    let registry = ConnectionRegistry()
    let environment = environment()

    let opened = registry.model(for: workbox, environment: environment)
    await opened.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(opened.phase == .connected)

    // The screen goes and comes back (a pop on iPhone, a new `.id(host.id)` view on iPad).
    let reopened = registry.model(for: workbox, environment: environment)
    #expect(reopened.phase == .connected, "the connection was torn down by navigation")
    #expect(reopened.session != nil, "the herdr session went with it")
  }

  @Test("disconnecting still disconnects, and the host reconnects afterwards")
  func disconnectThenReconnect() async {
    let registry = ConnectionRegistry()
    let environment = environment()
    let model = registry.model(for: workbox, environment: environment)

    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.disconnect()
    #expect(model.phase == .idle)
    #expect(registry.model(for: workbox, environment: environment).phase == .idle)

    // A fresh transport from the same long-lived model.
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)
  }

  @Test("a memory warning disconnects hosts with no terminal scene open")
  func memoryWarningDropsUnwatchedHosts() async {
    let warnings = NotificationCenter()
    let registry = ConnectionRegistry(notifications: warnings)
    let environment = environment()
    let watched = registry.model(for: workbox, environment: environment)
    let unwatched = registry.model(for: edge, environment: environment)
    await watched.connect(password: "hunter2", persistence: .promptEveryTime)
    await unwatched.connect(password: "hunter2", persistence: .promptEveryTime)
    registry.sceneOpened(for: workbox.id)

    warnings.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

    await waitUntil { unwatched.phase == .idle }
    #expect(unwatched.phase == .idle, "a host nothing is looking at kept its connection")
    #expect(watched.phase == .connected, "the terminal on screen lost its connection")
  }

  @Test("a scene that has closed no longer holds its host's connection")
  func closingTheSceneReleasesTheHost() async {
    let warnings = NotificationCenter()
    let registry = ConnectionRegistry(notifications: warnings)
    let environment = environment()
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    registry.sceneOpened(for: workbox.id)
    registry.sceneClosed(for: workbox.id)
    warnings.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

    await waitUntil { model.phase == .idle }
    #expect(model.phase == .idle)
  }

  /// The root presents the trust prompt, not the split view's detail column, so the registry
  /// says which connection is waiting on one.
  ///
  /// The environment is unseeded `.ephemeral`, so TOFU raises the prompt and suspends the
  /// handshake. That suspension is under test, so the connect runs in its own task.
  @Test("the registry reports the connection waiting on a trust decision")
  func pendingHostKeyPromptNamesTheWaitingConnection() async {
    let registry = ConnectionRegistry()
    let environment = AppEnvironment.ephemeral
    let model = registry.model(for: workbox, environment: environment)
    #expect(registry.pendingHostKeyPrompt() == nil, "nothing has been asked yet")

    let connecting = Task {
      await model.connect(password: "hunter2", persistence: .promptEveryTime)
    }
    await waitUntil { registry.pendingHostKeyPrompt() != nil }

    let pending = registry.pendingHostKeyPrompt()
    // Identity, not the hostname: an answer sent to another `ConnectionModel` resumes nothing.
    #expect(pending?.model === model, "the answer would reach a different connection")
    #expect(pending?.request.hostname == workbox.hostname)

    // Falls back to the model when the registry handed back nothing. An unanswered handshake
    // stays suspended for ever, so a regression would hang the suite instead of failing here.
    (pending?.model ?? model).prompt.answer(true)
    await connecting.value

    #expect(
      registry.pendingHostKeyPrompt() == nil,
      "the sheet would stay up over an answered question"
    )
    #expect(model.phase == .connected, "trusting the key did not let the connect finish")
  }

  @Test("forgetting a deleted host disconnects it")
  func forgettingDisconnects() async {
    // Deleting the host takes its row and its Disconnect away, so nothing else could close it.
    let registry = ConnectionRegistry()
    let environment = environment()
    let model = registry.model(for: workbox, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    await registry.forget(workbox.id)

    #expect(model.phase == .idle)
    #expect(
      registry.model(for: workbox, environment: environment) !== model,
      "a host added again under the same id would resume a stranger's connection"
    )
  }
}
