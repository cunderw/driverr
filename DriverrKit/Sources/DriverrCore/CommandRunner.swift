import Foundation

/// Running one command on the host and getting its result back.
///
/// A closure, not `DriverrSSH`'s `SSHTransport`, because `DriverrHerdr` and
/// `DriverrTranscript` must not import the SSH module. The app supplies `execChannel` and a
/// test supplies a dictionary, so every mapping and error path runs without a host.
public typealias CommandRunner = @Sendable (String) async throws -> CommandResult

/// Running one command with bytes written to its standard input.
///
/// For a command that must be given something no other account on the host may read. A
/// command's text is an argument to the login shell, and `ps` shows every argument to every
/// user. Standard input is not shown.
///
/// The command must read a known number of bytes and exit, as `head -c` does. The channel
/// has no half-close (see `InboxUploadCommand`), so a command reading to end of input never
/// exits.
public typealias InputCommandRunner = @Sendable (String, Data) async throws -> CommandResult
