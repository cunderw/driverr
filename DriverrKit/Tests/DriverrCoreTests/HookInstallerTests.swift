import Foundation
import Testing

@testable import DriverrCore

/// The install as the app runs it (read, edit, write) against a host that answers as `sh`
/// would.
@Suite("Hook installer")
struct HookInstallerTests {
  private let claude = AgentIntegration.claudeCode

  @Test("an install into the real shape writes the file the editor built, and a second install writes nothing")
  func installsOnceAndThenFindsItInstalled() async throws {
    let host = FakeHookHost(integration: claude, text: HookSettingsFixture.realShape)
    #expect(try await HookInstaller.status(of: claude, run: host.run).get() == .absent)

    #expect(try await HookInstaller.install(claude, run: host.run, write: host.write).get() == .installed)
    let written = await host.text
    let expected = try #require(try claude.installing(into: HookSettingsFixture.realShape))
    #expect(written == (expected.hasSuffix("\n") ? expected : expected + "\n"))
    #expect(try await HookInstaller.status(of: claude, run: host.run).get() == .installed)

    #expect(try await HookInstaller.install(claude, run: host.run, write: host.write).get() == .alreadyInstalled)
    #expect(await host.writeCount == 1)
  }

  @Test("a host with no settings file gets one")
  func createsAMissingFile() async throws {
    let host = FakeHookHost(integration: claude, text: nil)
    #expect(try await HookInstaller.install(claude, run: host.run, write: host.write).get() == .installed)
    let text = await host.text
    #expect(try claude.status(in: text) == .installed)
  }

  @Test("a host without the configuration directory reports it and is never offered")
  func noConfigDirectory() async {
    let host = FakeHookHost(integration: claude, text: nil, hasConfigDirectory: false)
    let check = await HookInstaller.status(of: claude, run: host.run)
    #expect(check == .failure(.host(.noConfigDirectory(path: "~/.claude"))))
    #expect(!HookOfferPolicy.shouldOffer(stored: nil, check: check, currentVersion: claude.version))
  }

  @Test("a file that changes between the read and the write is not written, and a retry reads again")
  func changedSinceRead() async throws {
    let rewritten = HookSettingsFixture.realShape.replacingOccurrences(of: "\"1\"", with: "\"2\"")
    let host = FakeHookHost(
      integration: claude, text: HookSettingsFixture.realShape, changeBeforeWrite: rewritten)

    let first = await HookInstaller.install(claude, run: host.run, write: host.write)
    #expect(first == .failure(.host(.changedSinceRead)))
    #expect(first.failureValue?.isRetryable == true)
    #expect(await host.text == rewritten, "a refused write leaves the file as it was")

    #expect(try await HookInstaller.install(claude, run: host.run, write: host.write).get() == .installed)
    #expect(await host.text?.contains("\"EXAMPLE_FLAG\": \"2\"") == true, "the retry kept the newer file")
  }

  @Test("a link that fails is a transport error")
  func transportFailure() async {
    let check = await HookInstaller.status(of: claude) { _ in throw AppError.notConnected(host: "workbox") }
    #expect(check == .failure(.transport(.notConnected(host: "workbox"))))
  }

  @Test("the failure text never quotes the settings file")
  func messagesNeverQuoteTheFile() {
    let failures: [HookInstallError] = [
      .host(.noConfigDirectory(path: "~/.claude")), .host(.notARegularFile(path: "~/.claude/settings.json")),
      .host(.settings(.invalidJSON)), .host(.settings(.unexpectedShape(path: "hooks.PreToolUse"))),
      .host(.settings(.duplicateKey(path: "hooks"))),
      .host(.settings(.markerUnderAnotherMatcher(path: "hooks.PreToolUse[0]"))),
      .host(.settings(.verificationFailed)), .host(.readDidNotMatch), .host(.changedSinceRead),
      .host(.writeDidNotMatch), .host(.checksumFailed(message: "")), .host(.settingsTooLarge(bytes: 99_000)),
      .host(.commandFailed(exitStatus: 1, message: "mv: cannot move")),
    ]
    for failure in failures {
      let message = failure.message(for: claude)
      #expect(!message.isEmpty)
      #expect(!message.contains(HookSettingsFixture.secret))
    }
    #expect(HookInstallError.host(.commandFailed(exitStatus: 1, message: "mv: cannot move")).message(for: claude)
      == "The command failed with exit status 1. Nothing was replaced. The host said: mv: cannot move")
  }

  @Test("a check that failed is never an offer, and a successful one follows the policy")
  func offerAfterCheck() {
    let v = claude.version
    #expect(HookOfferPolicy.shouldOffer(stored: nil, check: .success(.absent), currentVersion: v))
    #expect(!HookOfferPolicy.shouldOffer(stored: nil, check: .success(.installed), currentVersion: v))
    #expect(!HookOfferPolicy.shouldOffer(stored: .declined, check: .success(.absent), currentVersion: v))
    #expect(HookOfferPolicy.shouldOffer(stored: .installed(version: v - 1), check: .success(.outdated), currentVersion: v))
    #expect(!HookOfferPolicy.shouldOffer(stored: nil, check: .failure(.host(.settings(.invalidJSON))), currentVersion: v))
  }

  @Test("the fake refuses a write whose carried checksum does not match its input")
  func fakeChecksWhatItWrites() async throws {
    let plan = try #require(try HookInstallCommands.plan(for: claude, read: .missing))
    let whole = Data(plan.settingsText.utf8)
    let tampered = Data(plan.settingsText.replacingOccurrences(of: "\"matcher\"", with: "\"Matcher\"").utf8)
    #expect(tampered != whole)
    let host = FakeHookHost(integration: claude, text: nil)
    let refused = HookInstallCommands.writeDidNotMatchExitStatus
    #expect(await host.answer(plan.command, standardInput: tampered).exitStatus == refused)
    #expect(await host.answer(plan.command, standardInput: whole.dropLast()).exitStatus == refused)
    #expect(await host.answer(plan.command).exitStatus == refused, "a write with no input is a short copy")
    #expect(await host.text == nil)
    #expect(await host.answer(plan.command, standardInput: whole + Data("trailing".utf8)).exitStatus == 0)
    #expect(await host.text == plan.settingsText)
  }

  /// The write's command is an argument on the host, where `ps` shows it to every account.
  @Test("the install sends the file as the write's input and not in its command")
  func theFileGoesOnStandardInput() async throws {
    let host = FakeHookHost(integration: claude, text: HookSettingsFixture.realShape)
    let sent = SentWrites()
    let write: InputCommandRunner = { command, input in
      await sent.record(command: command, input: input)
      return await host.answer(command, standardInput: input)
    }
    #expect(try await HookInstaller.install(claude, run: host.run, write: write).get() == .installed)

    let writes = await sent.all
    let only = try #require(writes.first)
    #expect(writes.count == 1)
    #expect(!only.command.contains(HookSettingsFixture.secret))
    #expect(String(decoding: only.input, as: UTF8.self).contains(HookSettingsFixture.secret))
    #expect(only.command.contains("head -c \(only.input.count) "))
    #expect(await host.text == String(decoding: only.input, as: UTF8.self))
  }

  @Test("a write that cannot be sent is a transport error")
  func writeTransportFailure() async {
    let host = FakeHookHost(integration: claude, text: nil)
    let install = await HookInstaller.install(claude, run: host.run) { _, _ in
      throw AppError.channelFailed(reason: "The command ended without an exit status.")
    }
    #expect(install == .failure(.transport(.channelFailed(reason: "The command ended without an exit status."))))
    #expect(await host.text == nil)
  }

  /// What `ConnectionCoordinator.run(_:standardInput:)` throws on its deadline. The sheet
  /// shows the sentence as it is. It does not say that nothing was written, because the
  /// command may have got to any point on the host.
  @Test("a write the host stopped answering says so, and does not claim nothing was written")
  func writeDeadline() async throws {
    let host = FakeHookHost(integration: claude, text: nil)
    let install = await HookInstaller.install(claude, run: host.run) { _, _ in
      throw AppError.channelFailed(reason: "The host stopped answering before the command finished.")
    }
    guard case .failure(let error) = install else {
      Issue.record("the install should have failed, got \(install)")
      return
    }
    #expect(error.message(for: claude) == "The host stopped answering before the command finished.")
    #expect(!error.message(for: claude).contains("Nothing was"))
    #expect(!error.isRetryable)
  }
}

/// What a test's write runner was given.
private actor SentWrites {
  private(set) var all: [(command: String, input: Data)] = []
  func record(command: String, input: Data) { all.append((command, input)) }
}

extension Result {
  fileprivate var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
