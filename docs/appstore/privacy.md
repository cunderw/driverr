# Driverr privacy policy

This file is a copy kept in the repository. The published policy is at
<https://cunderw.dev/privacy-policy/driverr/>, the `privacyPolicyUrl` in `copy.json`, and that
page governs if the two differ.

_Last updated: 2026-10-09_

Driverr does not collect any data.

Driverr is an SSH client. It connects from your device directly to machines you name and
have credentials for. There is no Driverr server, no account, and no analytics — nothing to
send data to even if it wanted to.

## What Driverr stores, and where

| What | Where | Leaves the device? |
| --- | --- | --- |
| Hosts (name, hostname, port, username, and a herdr socket path if you set one) | On the device | Only to that host, when you connect (the username is sent to sign in) |
| Known host keys | On the device | No |
| SSH private keys | The device Keychain | No |
| Passwords, if you ask Driverr to remember one | The device Keychain | Only to the saved host entry's address, over SSH |
| Your settings (theme, font, font size, whether a pane's screen wraps, and whether Driverr shows Live Activities) | On the device | No |
| The last pane you opened, and which blocked panes Driverr has already told you about | On the device | No |
| Other app state: which host is selected, your Start or Stop choice for a host's Live Activity, and your answer when Driverr offered to install its hook | On the device | No |

Private keys and passwords are held in the Keychain and are never written to a file or a
log. A private key never leaves the device. A saved password belongs to the host entry, so
it is sent only to that entry's address. If you edit the address, the password is sent to
the new address the next time you connect.

## Host keys

The first time Driverr connects to a host, it shows you the key's fingerprint and stores
the key on the device only if you accept it. After that it checks the host's key on every
connection. If the key has changed, Driverr stops the connection, tells you, and does not
offer to accept the new key.

## What Driverr sends, and to whom

Your terminal input, a command you type in the Run a command field, herdr commands, and
the commands described in the next section, over an encrypted SSH connection, to the host
you chose. A command you type in that field runs on that host. To sign in, Driverr also
sends that host your username, and your password or a signature made with your key, as
any SSH client does. If you attach a photo to a message for an agent, Driverr sends that
photo to the same host, over the same connection. Nothing goes anywhere else.

While Driverr is in the background, iOS may wake it, no more than about every 15 minutes.
If Driverr can sign in without asking you, it opens its own SSH connection to the last
host you selected, checks whether an agent is waiting for you, and closes the connection.
That check sends nothing anywhere else.

If you tap Continue in Background while connected, Driverr asks iOS to let it keep running
after you leave the app. While that task runs, the SSH connection stays open and Driverr
keeps checking herdr on that host, so the Live Activity stays current.

## What Driverr reads and changes on your host

To show an agent's conversation, Driverr runs commands on your host that read the session
files Claude Code and Codex keep there, and the list of skills and commands installed for
them. The conversation is shown from memory and is not saved on the device.

Each time you connect to a host yourself, Driverr also reads Claude Code's settings file to
see if its hook is installed, unless you answered Not Now for that host. Driverr holds the
file in memory and does not save it.

Driverr changes files on your host only in these cases:

- When you attach a photo, Driverr writes it under `~/.driverr/inbox` and deletes files
  there that are more than a day old.
- When you choose to install Driverr's hook, Driverr reads Claude Code's settings file
  (normally `~/.claude/settings.json`), adds its entry, and writes the file back. If the
  file already existed, Driverr first copies it to `settings.json.driverr-backup` beside
  it, and replaces any older backup.
- When you choose to install a key, Driverr appends your public key to
  `~/.ssh/authorized_keys`, and creates the file or the folder if it is missing.

A program running on your host can put text on your device's clipboard, as in other
terminal apps.

## Notifications and Live Activities

When an agent on your host is waiting for you, Driverr can show a notification. While
Driverr is connected to a host, it can also show a Live Activity on your Lock Screen and
in the Dynamic Island. The card names the connected hosts, counts their panes by state,
such as working, finished or idle, and says how many need you. When an agent is waiting,
it also shows that agent, the title of its pane and the host. iOS may show a Live Activity
on a paired Apple Watch too, without any watch app from Driverr. Driverr makes the
notification and the card on the device from what your host sent it. They do not go
through a push server. You can turn Live Activities off in Driverr's settings, and
notifications off in iOS Settings.

## Deleting your data

You can delete individual hosts and SSH keys inside Driverr at any time. Deleting a host
also removes its saved password and remembered host key, unless another saved host uses
the same hostname. Deleting an SSH key removes its private key from the Keychain.

Deleting a host, or the app, does not undo changes Driverr made on that host: the hook
entry in Claude Code's settings file and its backup file, photos in `~/.driverr/inbox`
(Driverr clears old ones only when you attach another photo), and a public key you
installed in `~/.ssh/authorized_keys`.

Deleting the app removes data in its app container, such as hosts and settings, but iOS
may retain Keychain items after an app is uninstalled. To remove saved credentials before
uninstalling Driverr, delete every host and SSH key inside the app first.

## Contact

Open an issue at <https://github.com/cunderw/driverr>.
