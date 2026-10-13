# Security policy

## Supported versions

Security fixes are made for the latest release, or for `main` before the first release.
Older versions are not supported separately.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use **Report a vulnerability** in
this repository's Security tab so the report and follow-up remain private.

Use private reporting for issues involving SSH authentication, private keys or saved
passwords, host-key validation, transcript disclosure, or unintended command execution.
Include the affected version, reproduction steps, impact, and any evidence that can be
shared safely. Do not include credentials or private host data unless they are essential
to the report.

Ordinary bugs and feature requests should continue to use the public issue templates.

Driverr does not currently offer a bug bounty or promise a response deadline.

## Known limitations

Driverr acts on a host by running commands over SSH. While a command runs, other
accounts on the same host can usually read its arguments in the process list.

These commands carry text you typed or supplied:

- A reply sent from the composer. herdr's `pane` commands take the text of a reply only
  as an argument, and Driverr sends replies with those commands.
- A command you type in the Run a command field on the host screen.
- A new name for a pane, a tab or a workspace.
- The name of an SSH key, when you install its public key on a host. The name is one
  Driverr made, or the comment of a key you imported. The public key in the same command
  is not secret.
- The herdr socket path, if you set one for the host.

Other commands carry paths and ids that Driverr read from the host, and values it made
itself.

Driverr never puts these in a command:

- Passwords and private keys. Driverr uses them only to sign in.
- The agent settings file that the hook install writes. Driverr sends it on the
  command's standard input.
- Text you type in the terminal view. It goes over the open connection.

On a host that other people can sign in to, do not send a secret through the composer or
the Run a command field. Type it in the terminal view, at the prompt of the program that
asks for it.

If you find that Driverr exposes more than this, please report it through private
reporting.
