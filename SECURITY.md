# security policy

## reporting a vulnerability

report privately through
[github security advisories](https://github.com/jtayped/agent-secrets/security/advisories/new).
please do not open a public issue for a vulnerability.

include what an attacker gains and the position they need to start from —
"any process running as the store owner" and "another local account" are very
different findings here, and the difference is most of the analysis.

this is a personal project with one maintainer and no paid support. expect a
first response within a week or so, and no bounty.

## the threat model

worth stating plainly, because it decides whether a report is a vulnerability
or a design limit that is already written down.

**what the hardened setup is meant to stop.** the key is root-owned, so a
process running as you cannot decrypt a scope on its own. it has to ask the
privileged helper, and the helper asks you, on an unlocked local display,
before a sensitive group is handed over. the point is that a coding agent, a
compromised dependency, or a careless script running with your privileges
cannot silently read your production credentials.

**what it is not meant to stop.** root. another local account with sudo. an
attacker with physical access. anything that can make you approve a dialog you
should not have approved. and it is not a substitute for backups or for
reviewing the command you are about to hand a secret to.

**in the unhardened setup it stops none of that.** the dialog catches mistakes,
but any process running as you can read the key file directly. `secret-doctor`
says so every time it runs, and it is not a vulnerability when it does.

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
