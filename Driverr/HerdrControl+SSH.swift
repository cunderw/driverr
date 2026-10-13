import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTranscript

/// Joins two modules that do not import each other: `DriverrHerdr` runs herdr through a
/// `CommandRunner` closure, and `DriverrSSH` runs a command on a host.
extension CLIControl {
  init(transport: any SSHTransport, binaryPath: String = "herdr") {
    self.init(binaryPath: binaryPath) { command in
      try await transport.execChannel(command: command)
    }
  }
}

/// The same join for `DriverrTranscript`, which imports neither of the other two.
extension TranscriptReader {
  init(transport: any SSHTransport) {
    self.init { command in
      try await transport.execChannel(command: command)
    }
  }
}
