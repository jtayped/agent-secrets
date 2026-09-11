# security policy

## reporting a vulnerability

report privately through
[github security advisories](https://github.com/jtayped/agent-secrets/security/advisories/new).
please do not open a public issue for a vulnerability.

include what an attacker gains and the position they need to start from.
"any process running as the store owner" and "another local account" are very
different findings here, and that difference is most of the analysis.

this is a personal project with one maintainer and no paid support. expect a
first response within a week or so, and no bounty.

## the threat model

worth stating plainly, because it decides whether a report is a vulnerability
or a design limit that is already written down.

this tool shapes how a process reaches a secret. it does not contain a process
that has decided to take one. everything below follows from that.

**what the hardened setup is meant to stop.** the key is root-owned, so a
process running as you cannot decrypt a scope by reading a file. it has to go
through the privileged helper, which validates what it is asked for, releases
one group rather than the whole store, and, for a group marked sensitive, asks
you on an unlocked local display first and writes the verdict to the journal.

**what it is not meant to stop, and does not.** a process running as you can
call `secret-run` against any group you did not mark sensitive and send the
value anywhere, with no prompt. it can rewrite the unprivileged commands in
`~/.local/bin`, which your account owns, so that a later call leaks. it can use
a group you already approved, for as long as that approval lasts. none of these
are vulnerabilities. they are the shape of the design, and a report that a
coding agent could exfiltrate a non-sensitive group is describing documented
behaviour.

also outside it: root, another local account with sudo, physical access, and
anything that talks you into approving a prompt you should not have approved.

**in the unhardened setup it stops none of it.** any process running as you can
read the key file and decrypt every scope without involving this tool at all.
the dialog still catches mistakes, which is worth something, but it is not a
control. `secret-doctor` says so on every run, and it is not a vulnerability
when it does.

## what counts as a vulnerability

these are real findings. please report them:

- any way for a process running as the store owner to read a sensitive value in
  the hardened setup without an approval dialog
- any way to influence what the helper decrypts through argv, the environment,
  or a scope's own metadata
- any way to forge, replay or extend an approval verdict
- any way for a non-root account to change what the helper executes, including
  through a path the helper resolves
- a `secret-*` command that prints a value where it says it does not, or a
  value landing in the index, a log, a process listing, or shell history
- anything that makes the approval dialog reachable from somewhere other than
  an active, unlocked, local session

## what does not

- anything requiring root, or a second account that already has sudo
- the unhardened setup failing to protect the key. that is the documented
  difference between the two modes
- a scope being unreadable after the key is lost. there is no recovery and
  there is not meant to be one
- windows not being supported natively. see `docs/compatibility.md` for why a
  git-bash install is refused rather than allowed to look like it works

## supported versions

the latest commit on `main`. there are no backports.
