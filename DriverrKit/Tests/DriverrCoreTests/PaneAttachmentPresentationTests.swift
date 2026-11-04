import Foundation
import Testing

@testable import DriverrCore

/// The attachment row's copy and its phase machine.
@Suite struct PaneAttachmentPresentationTests {
  @Test func bytesReadAsSizesAPersonRecognises() {
    #expect(PaneAttachmentCopy.size(0) == "0 bytes")
    #expect(PaneAttachmentCopy.size(999) == "999 bytes")
    #expect(PaneAttachmentCopy.size(1000) == "1.0 KB")
    #expect(PaneAttachmentCopy.size(412_000) == "412 KB")
    #expect(PaneAttachmentCopy.size(1_200_000) == "1.2 MB")
    #expect(PaneAttachmentCopy.size(1_500_000_000) == "1.5 GB")
  }

  /// Nothing should produce a negative count, and the row must not be where that shows.
  @Test func aNegativeCountIsClampedRatherThanPrinted() {
    #expect(PaneAttachmentCopy.size(-5) == "0 bytes")
  }

  /// Keeps the row's width steady while an upload runs.
  @Test func theDecimalIsDroppedOnceTheNumberIsThreeDigits() {
    #expect(PaneAttachmentCopy.size(99_400) == "99.4 KB")
    #expect(PaneAttachmentCopy.size(100_400) == "100 KB")
  }

  @Test func progressReadsAsSentOfTotal() {
    let progress = ImageUploadProgress(bytesSent: 412_000, totalBytes: 1_200_000)
    #expect(PaneAttachmentCopy.progress(progress) == "412 KB of 1.2 MB")
  }

  /// This is the row's accessibility value, and VoiceOver reads a slash aloud.
  @Test func progressHasNoSlashInIt() {
    let progress = ImageUploadProgress(bytesSent: 1, totalBytes: 2)
    #expect(!PaneAttachmentCopy.progress(progress).contains("/"))
  }

  @Test func theFiveFailuresSayFiveDifferentThings() {
    let sentences = [
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.channelDropped(reason: "gone")),
      PaneAttachmentFailureCopy.sentence(
        for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: "No space left")),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.sizeMismatch(expectedBytes: 10)),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.noHostPath),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.stalled),
    ]
    #expect(Set(sentences).count == 5)
    #expect(sentences.allSatisfy { !$0.isEmpty })
  }

  /// Nothing reported a drop, so this is not the dropped-connection sentence. It says the
  /// upload was stopped, not that it failed, because Driverr gave up waiting. It does not
  /// say the host stopped taking the image: every byte may have been sent, with only the
  /// host's answer missing.
  @Test func aStallSaysTheUploadWasStoppedAndToTryAgain() {
    #expect(
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.stalled)
        == "The host stopped answering, so the upload was stopped. Try again.")
  }

  /// The host's stderr is whatever `/bin/sh` printed in the host's locale. The sentence says
  /// what to check instead.
  @Test func aRefusalDoesNotQuoteTheHostsStandardError() {
    let sentence = PaneAttachmentFailureCopy.sentence(
      for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: "cannot create /root/x"))
    #expect(!sentence.contains("/root/x"))
  }

  @Test func anErrorFromOutsideTheUploadStillGetsASentence() {
    let sentence = PaneAttachmentFailureCopy.sentence(
      for: AppError.channelFailed(reason: "The channel could not be opened."))
    #expect(sentence == "The channel could not be opened.")

    struct Unknown: Error {}
    #expect(!PaneAttachmentFailureCopy.sentence(for: Unknown()).isEmpty)
  }

  @Test func onlyTheUploadingPhaseSaysItIsUploading() {
    #expect(PaneAttachmentPhase.uploading(ImageUploadProgress(bytesSent: 1, totalBytes: 2))
      .isUploading)
    #expect(!PaneAttachmentPhase.ready.isUploading)
    #expect(!PaneAttachmentPhase.preparing.isUploading)
    #expect(!PaneAttachmentPhase.uploaded(hostPath: "/home/c/.driverr/inbox/a.png").isUploading)
    #expect(!PaneAttachmentPhase.handedOver.isUploading)
    #expect(!PaneAttachmentPhase.failed("nope").isUploading)
  }

  /// `PaneAttachmentModel` drives the hand-off from `hostPath`. A `.handedOver` that still
  /// returned a path could hand the same path over twice.
  @Test func onlyTheUploadedPhaseCarriesAHostPath() {
    let path = "/home/carson/.driverr/inbox/8F1C.png"
    #expect(PaneAttachmentPhase.uploaded(hostPath: path).hostPath == path)
    #expect(PaneAttachmentPhase.ready.hostPath == nil)
    #expect(PaneAttachmentPhase.uploading(ImageUploadProgress(bytesSent: 0, totalBytes: 1))
      .hostPath == nil)
    #expect(PaneAttachmentPhase.handedOver.hostPath == nil)
    #expect(PaneAttachmentPhase.failed("nope").hostPath == nil)
  }

  // MARK: - The hand-off

  /// The path lands in the agent's input box on the host, which the reader cannot see.
  @Test func theHandOffHasItsOwnSentenceAndItIsNotTheUploadsOne() {
    #expect(!PaneAttachmentCopy.handedOver.isEmpty)
    #expect(PaneAttachmentCopy.handedOver != PaneAttachmentCopy.uploaded)
  }

  /// The path is an inbox UUID and would fill the row saying nothing.
  @Test func theHandOffSentenceIsNotAPath() {
    #expect(!PaneAttachmentCopy.handedOver.contains("/"))
    #expect(!PaneAttachmentCopy.handedOver.contains(".png"))
  }

  /// A sent reply retires the row only when settled. The hand-off fires from `.uploaded`, so
  /// retiring there would cancel a `sendText` already on the wire.
  @Test func onlyTheTwoPhasesNothingWillMoveAgainAreSettled() {
    #expect(PaneAttachmentPhase.handedOver.isSettled)
    #expect(PaneAttachmentPhase.failed("nope").isSettled)
    #expect(!PaneAttachmentPhase.preparing.isSettled)
    #expect(!PaneAttachmentPhase.ready.isSettled)
    #expect(!PaneAttachmentPhase.uploading(ImageUploadProgress(bytesSent: 1, totalBytes: 2))
      .isSettled)
    #expect(!PaneAttachmentPhase.uploaded(hostPath: "/home/c/.driverr/inbox/a.png").isSettled)
  }

  /// Every other failure means the upload did not land. Told one of those, a reader sends the
  /// photo again and leaves two files in the inbox.
  @Test func theHandOffFailureSaysTheHostKeptTheImage() {
    let sentence = PaneAttachmentFailureCopy.handOffFailed
    #expect(!sentence.isEmpty)
    let others = [
      PaneAttachmentFailureCopy.unreadable,
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.channelDropped(reason: "gone")),
      PaneAttachmentFailureCopy.sentence(
        for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: "No space left")),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.sizeMismatch(expectedBytes: 10)),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.noHostPath),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.stalled),
    ]
    #expect(!others.contains(sentence))
    #expect(!sentence.contains("Try again"))
  }
  // MARK: - A pane on a machine a core added (#68)

  private static let box = PaneAttachmentPlace.machine("box")

  /// The host's sentences are the ones that shipped before a machine had any. A host place
  /// must not change a byte of them.
  @Test func theHostsSentencesAreUnchangedAtTheHost() {
    #expect(PaneAttachmentCopy.uploaded(at: .host) == "Sent to the host")
    #expect(PaneAttachmentCopy.uploaded(at: .host) == PaneAttachmentCopy.uploaded)
    #expect(
      PaneAttachmentFailureCopy.handOffFailed(at: .host)
        == "The host has the image, but the pane could not be told where it is.")
    let failures: [ImageUploadFailure] = [
      .channelDropped(reason: "gone"),
      .commandFailed(exitStatus: 1, standardError: "No space left"),
      .sizeMismatch(expectedBytes: 10),
      .noHostPath,
      .stalled,
    ]
    for failure in failures {
      #expect(
        PaneAttachmentFailureCopy.sentence(for: failure, at: .host)
          == PaneAttachmentFailureCopy.sentence(for: failure))
      #expect(
        PaneAttachmentFailureCopy.sentence(for: failure as any Error, at: .host)
          == PaneAttachmentFailureCopy.sentence(for: failure as any Error))
    }
    #expect(
      PaneAttachmentFailureCopy.sentence(
        for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: ""), at: .host)
        == "The host refused the upload. Check its disk space and permissions.")
    #expect(
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.noHostPath, at: .host)
        == "The host saved the image but did not say where.")
    #expect(
      PaneAttachmentFailureCopy.sentence(for: AppError.notConnected(host: "this host"), at: .host)
        == "Driverr isn't connected to this host.")
  }

  @Test func aMachinesSentencesNameIt() {
    #expect(PaneAttachmentCopy.uploaded(at: Self.box) == "Sent to box")
    #expect(
      PaneAttachmentFailureCopy.handOffFailed(at: Self.box)
        == "The image is on box, but the pane could not be told where it is.")
    #expect(
      PaneAttachmentFailureCopy.sentence(
        for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: "No space"),
        at: Self.box)
        == "Driverr could not save the image on box. Check its disk space and permissions.")
    #expect(
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.noHostPath, at: Self.box)
        == "The image was saved on box, but Driverr was not told where.")
    #expect(
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.stalled, at: Self.box)
        == "Nothing came back from box, so the upload was stopped. Try again.")
    #expect(
      PaneAttachmentFailureCopy.sentence(for: MachineImageRefusal.unsupported, at: Self.box)
        == "Driverr can't send images to box.")
  }

  /// Built from the limit, never a literal, so the sentence cannot drift from the check. The
  /// core's limit is 8 MiB, which `size` writes in decimal units, as iOS shows file sizes.
  @Test func aMachinesSizeRefusalNamesTheLimit() {
    #expect(
      PaneAttachmentFailureCopy.sentence(
        for: MachineImageRefusal.tooLarge(limit: 8 << 20), at: Self.box)
        == "The image is over the 8.4 MB limit for box.")
    #expect(
      PaneAttachmentFailureCopy.sentence(
        for: MachineImageRefusal.tooLarge(limit: 2_000_000), at: Self.box)
        == "The image is over the \(PaneAttachmentCopy.size(2_000_000)) limit for box.")
  }

  /// The core's own words name its terminal, `t7 has finished`, which says nothing about what
  /// to do, so every other error at a machine is the one fallback.
  @Test func anyOtherErrorAtAMachineIsTheFallback() {
    struct Unknown: Error {}
    for error: any Error in [
      AppError.herdrCommandFailed(reason: "t7 has finished"),
      AppError.channelFailed(reason: "The connection to herdr-core ended."),
      Unknown(),
    ] {
      #expect(
        PaneAttachmentFailureCopy.sentence(for: error, at: Self.box)
          == "The image could not be sent to box.")
    }
  }

  /// Only the SSH inbox command drops a channel or writes short, so those keep the host's.
  @Test func theInboxOnlyFailuresKeepTheHostsSentenceAtAMachine() {
    for failure: ImageUploadFailure in [.channelDropped(reason: "gone"), .sizeMismatch(expectedBytes: 3)]
    {
      #expect(
        PaneAttachmentFailureCopy.sentence(for: failure, at: Self.box)
          == PaneAttachmentFailureCopy.sentence(for: failure))
    }
  }

  @Test func aMachinesSentencesAreAllDifferent() {
    let sentences = [
      PaneAttachmentCopy.uploaded(at: Self.box),
      PaneAttachmentFailureCopy.handOffFailed(at: Self.box),
      PaneAttachmentFailureCopy.sentence(
        for: ImageUploadFailure.commandFailed(exitStatus: 1, standardError: ""), at: Self.box),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.noHostPath, at: Self.box),
      PaneAttachmentFailureCopy.sentence(for: ImageUploadFailure.stalled, at: Self.box),
      PaneAttachmentFailureCopy.sentence(for: MachineImageRefusal.unsupported, at: Self.box),
      PaneAttachmentFailureCopy.sentence(
        for: MachineImageRefusal.tooLarge(limit: 8 << 20), at: Self.box),
      PaneAttachmentFailureCopy.sentence(for: AppError.herdrResponseUnreadable, at: Self.box),
    ]
    #expect(Set(sentences).count == sentences.count)
    #expect(sentences.allSatisfy { $0.contains("box") })
  }
}
