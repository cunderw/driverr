/// How a scripted command reaches a host's login shell.
///
/// An SSH exec channel hands its command to the user's login shell, and that shell can be
/// fish. `shellQuoted` writes POSIX single quotes. fish reads `\` and `'` inside single quotes
/// as escapes, so a quoted value that holds both can end its quoting early under fish.
///
/// `posix(_:)` sends the whole script as one `sh -c` word, quoted by
/// `HookInstallCommands.loginShellQuoted`. bash, zsh, dash and fish all read that word back
/// as the exact script, and `sh` then reads the script with POSIX rules. Every command
/// Driverr writes goes through it. The Run box on the host screen does not: the user types
/// that command for their own shell.
public enum LoginShell {
  /// `script` as a command that any supported login shell hands to `sh` unchanged.
  public static func posix(_ script: String) -> String {
    script
  }
}
