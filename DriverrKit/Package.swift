// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DriverrKit",
  platforms: [.iOS(.v26), .macOS(.v14)],
  products: [
    .library(name: "DriverrCore", targets: ["DriverrCore"]),
    .library(name: "DriverrSSH", targets: ["DriverrSSH"]),
    .library(name: "DriverrTerm", targets: ["DriverrTerm"]),
    .library(name: "DriverrHerdr", targets: ["DriverrHerdr"]),
    .library(name: "DriverrTranscript", targets: ["DriverrTranscript"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
    // **A fork, temporarily. Delete it when migueldeicaza/SwiftTerm#659 merges and an
    // upstream tag refuses kitty graphics local media by default.** Upstream's
    // `TerminalView.hasText` answers from `textInputStorage` — cleared on every Enter,
    // and never holding what the far side echoed — so it reads `false` at an ordinary
    // shell prompt. iOS reads `hasText` to decide whether the delete key has anything to
    // act on, so that cost backspace its auto-repeat: holding it deleted one character
    // and stopped. It cannot be fixed downstream — `hasText` is `public`, not
    // `open`, so a subclass cannot override it, and no version bump changes that.
    //
    // The fork also refuses the kitty graphics media `t=f`, `t=t` and `t=s`, which name a
    // file, a temporary file or a shared memory object **on the device that runs the
    // terminal**. v1.18.0 reads the file, deletes the temporary file, unlinks the segment,
    // and tells the host whether the path exists. The fork answers
    // `EINVAL: unsupported medium` and touches nothing. `t=d`, pixels sent in the sequence
    // itself, is unchanged. Upstream main refuses these by default behind a policy option,
    // and no tag has it yet. `KittyGraphicsLocalMediaTests` holds the rule, so a pin that
    // loses it fails the kit tier.
    //
    // The fork is upstream **v1.18.0** plus those two commits, so the delta from upstream is
    // one function and one `switch`. Pinned by revision rather than a version range on
    // purpose: it makes no version claim it would have to keep, and it cannot drift if
    // someone runs `swift package update`.
    //
    // When the upstream pull request merges and a tag carries both changes, put this back to
    // `.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: …)`.
    .package(
      url: "https://github.com/cunderw/SwiftTerm.git",
      revision: "96771c0ea228df36583daf71c1e17698e41efb67"
    ),
  ],
  targets: [
    .target(name: "DriverrCore"),
    .testTarget(name: "DriverrCoreTests", dependencies: ["DriverrCore"]),
    .target(
      name: "DriverrSSH",
      dependencies: [
        "DriverrCore",
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
      ]
    ),
    .testTarget(name: "DriverrSSHTests", dependencies: ["DriverrSSH"]),
    // No dependency on DriverrSSH on purpose: DriverrTerm renders a byte stream, and
    // making it import the SSH module would tie the terminal to one source of bytes.
    .target(
      name: "DriverrTerm",
      dependencies: [
        "DriverrCore",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ]
    ),
    .testTarget(name: "DriverrTermTests", dependencies: ["DriverrTerm"]),
    // No dependency on DriverrSSH, for the same reason DriverrTerm has none: this module
    // maps herdr's wire format, and how the bytes were fetched is the app's business.
    // `CLIControl` runs commands through an injected runner the app fills from
    // `SSHTransport.execChannel`.
    .target(name: "DriverrHerdr", dependencies: ["DriverrCore"]),
    .testTarget(name: "DriverrHerdrTests", dependencies: ["DriverrHerdr"]),
    // No dependency on DriverrHerdr either, and that is the point: a Claude session file
    // is not a herdr wire type, so nothing here may reach for one. It shares only the
    // `CommandRunner` closure, which lives in DriverrCore precisely so both modules can
    // be driven by a dictionary instead of a host.
    .target(name: "DriverrTranscript", dependencies: ["DriverrCore"]),
    .testTarget(name: "DriverrTranscriptTests", dependencies: ["DriverrTranscript"]),
  ]
)
