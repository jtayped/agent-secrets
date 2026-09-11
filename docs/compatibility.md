# compatibility

the short version: **linux is fully supported, macos is supported with one
caveat, and windows works only inside wsl2.**

this page says exactly which parts of the tool depend on which parts of the
operating system, because "supported" means different things at each layer.

## what the tool is made of

there are two halves, and they have very different requirements.

the **unprivileged half** is the `secret-*` commands. it needs bash, gpg, awk,
sed and a sha256 program. that half is portable to anything posix.

the **privileged half** is `lib/agent-secrets-helper`, which runs as root, owns
the decryption key, and asks you to approve access to a sensitive group. it
needs, from the operating system:

- a way for root to run a program as you, without a password
- a way to tell whether you are sitting at an unlocked local display
- a way to draw a modal dialog in your desktop session
- file ownership that root can set and you cannot undo

every one of those is os-specific, and the last one is the reason windows is
out.

## matrix

| | linux | macos | windows (wsl2) | windows (native) |
|---|---|---|---|---|
| encrypted scopes, groups, `secret-run` | yes | yes | yes | no |
| value-free index and `--tree` | yes | yes | yes | no |
| approval dialog | kdialog or zenity | applescript | kdialog or zenity | no |
| "am i at a local unlocked seat" check | `loginctl` | `/dev/console` + `ioreg` | `loginctl` | no |
| root-owned key and helper | yes | conditional, see below | yes | no |

## linux

the reference platform. the hardening step wants systemd (`loginctl` for the
session check, and the user manager for your display environment), util-linux
(`setpriv`), sudo, and either kdialog or zenity.

without systemd the tool still runs, but `secret-doctor` will report that the
approval gate cannot establish whether a request is coming from a person at the
machine, and sensitive groups will refuse rather than guess.

## macos

the unprivileged half works out of the box once gnupg is installed. the
approval dialog is a native applescript dialog, drawn in your gui session
through `launchctl asuser`. the session check reads the owner of `/dev/console`
and asks `ioreg` whether the screen is locked, which answers the same question
`loginctl` answers on linux: is this request coming from the person physically
at this mac.

the helper is written for **bash 3.2**, which is what macos ships at
`/bin/bash`. that is not nostalgia. it is the only bash on a mac that root
actually owns, and a root-owned helper has to be run by a root-owned
interpreter. a homebrew bash lives under a prefix your own account can write,
so a helper with a `#!/opt/homebrew/bin/bash` shebang could be hijacked by
replacing bash. the ci matrix runs the full test suite under `/bin/bash` 3.2 on
both intel and apple silicon runners so this constraint cannot rot.

**the caveat.** `install-root.sh` refuses to harden unless the helper, its
interpreter, and gpg all sit under paths that only root can write. on a typical
mac, gnupg comes from homebrew and lives in `/opt/homebrew/bin` (apple silicon)
or `/usr/local/bin` (intel), both of which your admin account owns. installing
a root-owned helper that calls a gpg you can replace would look like hardening
and stop nothing, so the installer declines and tells you why.

to get hardened mode on macos you need gnupg under a root-owned prefix, for
example macports, which installs into `/opt/local` as root. otherwise use the
unhardened mode, which is honest: the dialog still catches mistakes, but any
process running as you can read the key.

## windows

there is no native windows support and there is not going to be a native
windows port of this design. the protection here is posix file ownership plus
sudo plus a root-owned helper. windows has its own answers to that problem
(dpapi, the credential manager, a service running as a different principal),
and reaching them would mean a different program in a different language rather
than a port of these scripts.

what would happen without the guard is worse than an error: under git bash,
`chmod 700` is close to a no-op, there is no `sudo`, and the helper would run as
you with the key readable. the tool would report success and protect nothing.
so `install.sh` detects git bash, msys and cygwin and refuses.

**use wsl2.** inside a wsl2 distribution every linux instruction on this page
applies unchanged, including the hardening step. one detail worth knowing: wsl2
has no local seat in the sense the gate means, so if you want the approval
dialog you need wslg (shipped with windows 11 and recent windows 10) and a
dialog program installed in the distribution. without a display, sensitive
groups refuse rather than silently allowing.

## checking your own machine

~~~bash
secret-doctor
~~~

it names every dependency, whether it is present, and what is lost without it.
it is the answer to "will this work here", and it is worth running again after
any os upgrade.
