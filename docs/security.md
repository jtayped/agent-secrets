# security

this tool shapes how a process reaches a secret. it does not contain a process that has decided to take one. the readme says this at the top and it is worth repeating here, because everything below is only meaningful inside that limit.

## what it actually buys you

values never reach stdout. every command hands a group to a child process through its environment instead of printing it, so a secret does not end up in a terminal transcript, a log, or an agent's context just because something needed it.

names are readable without values. groups, key names, descriptions and sensitivity marks live in a plaintext index, so a process can work out what exists without decrypting anything.

a command gets one group rather than the whole store, and a group you marked sensitive costs a prompt and a journal entry.

that is real, and it is also the whole of it.

## what the root install changes

before the root install, your account owns ~/.secrets/key/.key. any program running as you can read it, decrypt every scope with bare gpg, and never touch this tool. the approval dialog catches mistakes. it stops nothing.

after the root install, root owns the installed helper and the key. a process running as you cannot decrypt a scope by reading a file. it has to go through the helper, which validates scope and group names, reads sensitivity from the encrypted metadata rather than the writable index, and asks for local approval before releasing a sensitive group.

what that does not give you: a process running as you can still call `secret-run` on any group you did not mark sensitive and pipe the value wherever it likes, with no prompt. it can also rewrite the unprivileged commands in ~/.local/bin, which your account owns. root owns the helper, but not the thing that calls it.

so mark the groups that matter as sensitive, and treat everything else as readable by anything running as you. if you need a credential to be out of reach of a process on this machine, do not put it on this machine.

approval is a consent check, not an authorisation check. after you approve, the process you approved receives the values, and so does anything that process runs. read the command before approving it.

## the approval gate

the gate needs an active, unlocked, local desktop session and kdialog. it exits instead of guessing when no safe approval channel exists.

- 69 means there is no local approval channel.
- 75 means the dialog timed out or failed. nothing was cached.
- 77 means approval was denied. stop rather than retrying.
- 78 means an index is stale or metadata is malformed.

the gate uses the encrypted scope metadata, not the writable index. it caches an approval per sensitive group for 15 minutes by default. a sensitive parent covers all of its children.

## handling values

do not put a value in an argument, shell history, commit, issue, chat transcript, or log. use stdin with secret-set.

do not run a scope with commands that print its environment:

~~~text
env
printenv
set
~~~

use secret-list scope --tree to learn what exists. it reads an index that contains key names, groups, descriptions, attributes, and sensitivity marks, but no secret values.

## backup and recovery

a scope is an ordinary .env payload encrypted with gpg symmetric encryption. encrypted scope files may be backed up or synced. the key must be backed up separately and kept out of broad sync directories.

if you restore or edit a scope outside this tool, run:

~~~bash
secret-reindex scope
~~~

without the key, the encrypted scopes cannot be recovered. with both the key and scope files, gpg can decrypt the payload even if these scripts are unavailable.

## before publishing a fork

check that the repository has no .gpg files, .key files, .env files, local rclone configuration, ssh private keys, or scope indexes copied from a real store. the included .gitignore blocks common accidents, but it is not a substitute for reviewing git status.

## if secret-doctor reports a weakened key

`secret-init` used to write the key as 32 raw random bytes. gpg reads a
passphrase file as text: it takes the first line and stops. about one key in
eight contained a newline somewhere, and gpg silently used only the bytes
before it. a newline at byte 10 left 80 bits of entropy where 256 was
intended. keys are base64 now, which cannot contain a newline or a NUL, and
`secret-doctor` reports an older key that is affected.

**your scopes still open normally.** the key is weaker than intended, not
broken, and nothing needs doing urgently. to move to a full-strength key, the
shape of it is: decrypt every scope with the current key, generate a new one,
re-encrypt each scope under it, and replace your key backup. do that with the
old key still in hand until you have confirmed every scope opens under the new
one.
