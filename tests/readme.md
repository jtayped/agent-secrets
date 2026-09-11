# tests

secrets are not like other data. a wrong answer is visible and recoverable; a
lost secret is neither. so these files are organised by **what a bug costs**,
not by which function it lives in.

| file | guards | a failure here means |
|---|---|---|
| `key.sh` | the key | the one thing with no recovery path. if it is weak or wrong, every scope is affected at once and nothing else in this list matters. |
| `integrity.sh` | the destructive paths | a bug that makes the store **shorter** rather than wrong. |
| `format.sh` | the scope format | a save that silently changes or drops what you stored. |
| `upgrade.sh` | upgrades | an upgrade that touches a store instead of only replacing code. |
| `smoke.sh` | the happy path | the ordinary commands stopped working. |

run them all:

~~~bash
for t in tests/*.sh; do "$t" || break; done
~~~

they need nothing installed. each builds an isolated store under `mktemp -d`,
points `AGENT_SECRETS_DIR` at it, and removes it on exit. none of them touch
`~/.secrets`, and none require the hardened setup or a desktop session — a test
that needed someone to click an approval dialog could not run in ci, so no test
reads a group marked `#@sensitive`.

## the ideas worth keeping

**assert the strongest property the code supports.** in rough order of
strength: it did not crash, an invariant held, the operation is idempotent, it
round-trips against an oracle. `format.sh` asserts the last three, because the
renderer can support them.

**do not let the code under test supply the fixtures.** a round-trip checked
with the same writer that produced the file inherits that writer's assumptions
and confirms them. `format.sh` therefore decrypts with bare `gpg` rather than
with this project's reader, and separately feeds in a payload that bare `gpg`
encrypted. that pair is what actually tests the promise in `docs/format.md`:
that a ciphertext backup plus the key is enough to recover everything with no
tooling at all.

**repeat anything probabilistic.** `key.sh` generates 64 keys rather than one.
the bug it exists to catch would have passed a single-key test roughly seven
times in eight, which is exactly how it survived from the initial release until
a ci run happened to hit it.

**test the guards, not just the happy path.** `integrity.sh` ends by sabotaging
the renderer inside a copy of the helper and asserting the save is refused.
without that, the key-loss guard in `cmd_encrypt` would be untested code that
merely looks reassuring. if you change that guard, check the mutation still
trips it — a mutation test that no longer mutates anything passes silently, so
the test fails loudly when its `sed` pattern stops matching.

**run the suite on every platform you claim to support.** `integrity.sh` passed
on linux and failed on both macos runners the first time it ran, because
`render_excluding` passed a multi-line list to `awk -v` and the awk on macos
rejects that. the awk was inside a process substitution, so its exit status
went nowhere and `secret-edit <scope> <group>` quietly wrote back a scope
containing only the group that had just been edited. a linux-only suite would
have called that green.

**a destructive operation deserves a before-and-after fingerprint**, not a spot
check. `upgrade.sh` cksums every file in the store and diffs the whole list,
because "the value i looked at is still there" and "nothing was lost" are
different claims.
