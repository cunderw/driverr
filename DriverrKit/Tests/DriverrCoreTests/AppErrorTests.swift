import Foundation
import Testing
@testable import DriverrCore

@Suite("AppError")
struct AppErrorTests {
  @Test("authentication failure names the host so the message is actionable")
  func authenticationFailedMessage() {
    let error = AppError.authenticationFailed(host: "workbox")
    #expect(error.errorDescription?.contains("workbox") == true)
  }

  @Test("host key mismatch is worded as a hard stop, not a retryable hiccup")
  func hostKeyMismatchIsAHardStop() {
    let error = AppError.hostKeyMismatch(host: "workbox")
    let message = error.errorDescription ?? ""
    #expect(message.contains("workbox"))
    #expect(!error.isRetryable)
    // The button underneath is the only way out, so the sentence names it.
    #expect(message.contains("Forget Host Key"))
  }

  /// Nothing was sent to the server, so it must not read as a refusal.
  @Test("a missing password is not reported as the server refusing")
  func passwordRequiredIsNotARefusal() {
    let error = AppError.passwordRequired(host: "workbox")
    let message = error.errorDescription ?? ""
    #expect(message.contains("workbox"))
    #expect(!message.lowercased().contains("refused"))
    #expect(!error.isRetryable)
    #expect(error != AppError.authenticationFailed(host: "workbox"))
  }

  @Test("a dropped connection is retryable, unlike a key mismatch")
  func disconnectionIsRetryable() {
    #expect(AppError.disconnected(reason: "timed out").isRetryable)
  }

  /// The host was reached, so the message must not say it was not.
  @Test("a set-up that stops answering says the host was reached, not that it was not")
  func herdrDidNotAnswerSaysTheHostWasReached() {
    let error = AppError.herdrDidNotAnswer(host: "workbox")
    #expect(error.errorDescription == "Reached workbox, but herdr did not answer.")
    #expect(error.isRetryable)
    #expect(error != AppError.connectionFailed(host: "workbox", reason: "herdr did not answer."))
  }

  @Test("every case produces a non-empty user-facing message")
  func allCasesHaveMessages() {
    let cases: [AppError] = [
      .connectionFailed(host: "h", reason: "refused"),
      .authenticationFailed(host: "h"),
      .passwordRequired(host: "h"),
      .hostKeyMismatch(host: "h"),
      .hostKeyRejected(host: "h"),
      .channelFailed(reason: "no pty"),
      .notConnected(host: "h"),
      .disconnected(reason: "eof"),
      .keyImportFailed(reason: "bad key"),
      .herdrNotInstalled,
      .herdrCommandFailed(reason: "no such pane"),
      .herdrDidNotAnswer(host: "h"),
      .herdrResponseUnreadable,
      .transcriptUnreadable(reason: "gone"),
      .cancelled,
    ]
    for error in cases {
      let message = error.errorDescription ?? ""
      #expect(!message.isEmpty, "\(error) had an empty message")
    }
  }

  // MARK: - A fixed headline does not contradict the reason it carries

  @Test("channelFailed's description is the reason alone, with no headline prefixed onto it")
  func channelFailedIsReasonOnly() {
    // A fixed headline in front would contradict a reason like "This host isn't connected."
    let error = AppError.channelFailed(reason: "This host isn't connected.")
    #expect(error.errorDescription == "This host isn't connected.")
  }

  @Test("notConnected names the host, with no connection open to contradict")
  func notConnectedNamesTheHost() {
    let error = AppError.notConnected(host: "workbox")
    #expect(error.errorDescription == "Driverr isn't connected to workbox.")
  }

  @Test("notConnected is retryable, the same as the channel failure it stands in for")
  func notConnectedIsRetryable() {
    #expect(AppError.notConnected(host: "workbox").isRetryable)
  }

  @Test("transcriptUnreadable's description is the reason alone")
  func transcriptUnreadableIsReasonOnly() {
    // `TranscriptNotice(failure:)`'s title already says it could not be read.
    let error = AppError.transcriptUnreadable(reason: "sh: tail: not found")
    #expect(error.errorDescription == "sh: tail: not found")
  }

  @Test("herdr-missing does not blame the login shell's PATH")
  func herdrNotInstalledDoesNotBlameTheLoginShell() {
    // An SSH exec channel runs a non-login shell, so the login PATH is not the one searched.
    let message = AppError.herdrNotInstalled.errorDescription ?? ""
    #expect(!message.contains("login shell's PATH"))
  }
}
