# user guide

this is the walkthrough. it assumes you have never used the tool and takes
about ten minutes, after which you will know where your secrets live, how to
add one, and how to hand one to a command without it appearing on your screen.

if you want to know what this protects you from and what it does not, the
[readme](../readme.md) says so at the top. read that first. it is short and it
is the honest version.

## install it

~~~bash
git clone https://github.com/jtayped/agent-secrets.git
cd agent-secrets
./install.sh
~~~

the commands land in `~/.local/bin`. if that is not on your path, add it:

~~~bash
export PATH="$HOME/.local/bin:$PATH"     # bash, zsh
~~~

~~~fish
fish_add_path ~/.local/bin               # fish
~~~

then check what your machine can do:

~~~bash
secret-doctor
~~~

it lists every dependency, whether it is there, and what you lose without it.
run it again any time something behaves oddly.

leave the hardening step alone for now. [setup.md](setup.md) covers it once you
have used the tool for a bit.

## make your first scope

a scope is one encrypted file holding related secrets. most people end up with
two or three: `personal`, `work`, maybe one per client.

~~~bash
secret-edit personal --new
~~~

your editor opens on a new file with two comment lines reminding you of the
syntax. under them, type this:

~~~dotenv
#@g github   github
#@d personal access token, repo scope
GITHUB_TOKEN=ghp_replace_me

#@g openai   openai api
OPENAI_API_KEY=sk-replace-me
~~~

save and close. the file is encrypted before it touches disk again.

## what you just wrote

it is an ordinary `.env` file. `KEY=value`, one per line, no quotes and no
`export`. the lines beginning `#@` are the only additions, and there are three
worth knowing.

`#@g <path>   <description>` starts a group. the path is lowercase and dotted,
like `pg.prod`. separate the description from the path with a tab or two
spaces.

`#@d <text>` describes the **next** thing you write, whether that is a key or
another group. this catches people out. a `#@d` line sitting above `GITHUB_TOKEN`
describes the token, not the group above it.

`#@sensitive` marks the next thing as needing your approval before anything can
read it. more on that below.

keys join a group by their name. a group at `pg.prod` claims every key starting
`PG_PROD_`, so `PG_PROD_PASSWORD` lands in it with the short name `PASSWORD`.
the longest matching group wins, which is why `PG_PROD_PASSWORD` goes to
`pg.prod` and not to `pg`. you never write the mapping down. name the key after
the group and it lands in the right place.

## finding things later

this is the part you will use most, and it works like `ls`.

with no arguments it lists your scopes:

~~~text
$ secret-list
personal
work
~~~

give it a scope and you see the top level of that scope:

~~~text
$ secret-list work
work  (4 groups, 6 keys)

  pg/           2 groups, 4 keys  postgres endpoints
  stripe/       2 keys            payments

  go deeper with: secret-list work pg
~~~

the count on each line is what is underneath it, so you can tell whether a
branch is worth opening before you open it. add a group to go in:

~~~text
$ secret-list work pg
work:pg  (2 groups, 4 keys)  postgres endpoints

  prod/         2 keys            production database  [sensitive]
  staging/      2 keys            staging database

  go deeper with: secret-list work pg.prod
  give a command just this group: secret-run work pg -- <command>
~~~

keep going until you reach the keys:

~~~text
$ secret-list work stripe
work:stripe  (2 keys)  payments

  PUBLISHABLE_KEY
  SECRET_KEY *                         live secret key

  * needs your approval before it can be read.
  give a command just this group: secret-run work stripe -- <command>
~~~

none of that decrypts anything. names, descriptions and structure live in a
separate plaintext index, so browsing costs nothing and prompts you for
nothing.

two other ways to look:

~~~bash
secret-list work --tree        # everything at once
secret-list work pg --tree     # everything under one group
secret-list work --keys        # every variable name, one per line, for scripts
~~~

`--tree` is genuinely useful once you know roughly what you are looking at. it
is the wrong tool when you have forgotten, which is why it is no longer the
default.

## add one secret

if you have a value already, pipe it in. never put it in the command itself,
where it lands in your shell history:

~~~bash
pbpaste | secret-set work stripe.secret_key --desc "live secret key"
~~~

on linux, `wl-paste` or `xclip -o` instead of `pbpaste`. generating a new one
works the same way:

~~~bash
openssl rand -base64 32 | secret-set work service.api_token --desc "internal api"
~~~

### when someone else has to supply the value

piping works when the value is on the machine already. it is the wrong shape
when a person has to hand it over, because the obvious thing to do with a
command someone gives you is to paste the credential into it — and then it is
in your shell history, and in the transcript of whoever wrote the command.

`secret-ask` names the destination and asks for the value in a dialog instead:

~~~bash
secret-ask work stripe.secret_key --desc "live secret key"
~~~

a masked prompt opens on your screen showing the scope, the variable name and
the description. what you type goes from the dialog into the encrypted store
without passing through the command line, the shell, or the process that ran
the command. an agent can write this one out for you to run; it learns only
that the value was stored.

it refuses an existing key before asking rather than after, so you are never
asked to retype something only to be told it was already there.

credentials usually come in sets, so ask for them together. `--desc` attaches
to the path in front of it:

~~~bash
secret-ask work stripe.publishable_key --desc "publishable" \
                stripe.secret_key      --desc "live secret key"
~~~

one approval covers the set, and the values are spliced and encrypted in one
step, so a cancelled second field cannot leave the first one written.

whether that is one dialog or two depends on what is installed. zenity has a
multi-field form and gets one; kdialog has none and asks in sequence.

the dotted path becomes the variable name. `work stripe.secret_key` writes
`STRIPE_SECRET_KEY` into the `stripe` group. it refuses to overwrite something
that already exists:

~~~text
$ printf 'x' | secret-set personal github.token
agent-secrets-helper: GITHUB_TOKEN already exists; use --force to replace it
~~~

pass `--force` when you mean it, which is what rotating a token looks like.

for anything more than one value, open the editor instead:

~~~bash
secret-edit work              # the whole scope
secret-edit work pg.prod      # only that group, and only that group is decrypted
~~~

prefer the second form. it keeps the rest of the scope out of your editor and
off your screen.

## use a secret

this is the part that matters, and it is the reason the tool exists.

~~~bash
secret-run work pg.staging -- sh -c 'psql -h "$PG_STAGING_HOST" -U "$PG_STAGING_USER"'
~~~

the named group becomes environment variables for that one command and nothing
else. the value never prints, never reaches your terminal, and never lands in a
transcript.

note the single quotes. your own shell expands `$PG_STAGING_HOST` before
`secret-run` has done anything, and at that point the variable does not exist
yet, so double quotes there would quietly pass an empty host. anything
referring to the variables by name has to be inside single quotes so the inner
shell does the expanding. commands that read their own environment, like
`psql` with `PGHOST` or `curl` with `--netrc`, avoid the problem entirely:

~~~bash
secret-run work pg.staging -- sh -c 'PGHOST=$PG_STAGING_HOST psql'
~~~

~~~text
$ secret-run work pg.staging -- sh -c 'echo "host is $PG_STAGING_HOST"'
host is staging.db.internal
~~~

name the narrowest group that the job needs. leaving the group out hands the
command every value in the scope, which is occasionally what you want and
usually is not.

do not point it at `env`, `printenv`, `set`, or anything else whose job is to
print its environment. that undoes the whole point.

## mark the dangerous things

put `#@sensitive` above a group and reading anything inside it needs your
approval:

~~~dotenv
#@sensitive
#@g pg.prod   production database
PG_PROD_HOST=prod.db.internal
PG_PROD_PASSWORD=replace-me
~~~

after the hardening step in [setup.md](setup.md), the next attempt to read that
group opens a dialog on your desktop naming the scope, the group, its
description, and the reason given by whatever asked. you allow or deny. an
allow lasts fifteen minutes so a task does not ask you twenty times, and every
answer goes to the system journal.

a sensitive group covers everything beneath it. mark `pg` and both `pg.prod`
and `pg.staging` are covered.

be selective. mark the credentials that would ruin your week, and leave the
rest alone. marking everything trains you to click allow without reading, and
then the prompt is worth nothing.

## back it up

two things to back up, and they belong in different places.

`~/.secrets/scopes/` is encrypted. put it wherever you like: a cloud drive, a
private git repo, a usb stick. that is what the encryption is for.

`~/.secrets/key/.key` is the key. back it up once, by hand, somewhere that is
not wherever the scopes went. a password manager is a good home for it.

**without the key, the scopes are gone.** there is no recovery, no reset and no
support address. that is the intended property, and it is worth being blunt
about because people assume otherwise.

there is an rclone helper if you want the scopes synced automatically:

~~~bash
AGENT_SECRETS_SYNC_REMOTE=remote:agent-secrets secrets-bisync
~~~

it never touches `key/`. note that it also syncs the plaintext index by
default, which holds no values but does list your group names, key names and
descriptions. set `AGENT_SECRETS_SYNC_INDEX=0` if you would rather not publish
an inventory of which credentials you own.

## changing the key

if the key ever leaks, or `secret-doctor` tells you yours is weaker than it
should be:

~~~bash
secret-rekey
~~~

it re-encrypts every scope under a freshly generated key, reading each one back
and comparing it before replacing anything. the old key stays at
`~/.secrets/key/.key.old` the whole time, so an interrupted or regretted rekey
is recoverable.

then, in this order: check a value still works, replace the key in your backup
with the new one, and only then run `secret-rekey --finish` to delete the old
key. until you do, the old key still opens everything, which is your way back.

if a rekey gets interrupted, `secret-rekey --resume` finishes it using the keys
already on disk.

## the short version

~~~text
secret-list                          which scopes exist
secret-list <scope>                  what is in one
secret-list <scope> <group>          go one level deeper
secret-list <scope> --tree           all of it at once

secret-edit <scope> --new            make a scope
secret-edit <scope> <group>          edit one group
<producer> | secret-set <scope> <group.key> --desc "what it is"

secret-run <scope> <group> -- <command>      hand it over, briefly

secret-doctor                        what works on this machine
secret-update --check                what an upgrade would do
secret-rekey                         move everything onto a new key
~~~

## when something goes wrong

**`error: no scope 'nosuch'`** followed by a list. you mistyped the scope name,
and the list is every scope you have.

**`error: no group 'pg.dev' in 'work'`** followed by `at that level: prod
staging`. same thing for groups, and it tells you the siblings so you can spot
the right one.

**`index for 'work' is stale or missing`.** the plaintext index no longer
matches the encrypted file, usually because a scope was restored or synced from
elsewhere. run `secret-reindex work`. it is a cache and rebuilding costs
nothing.

**`agent-secrets-gate: unavailable`, exit 69.** something asked for a sensitive
group and there is no unlocked local desktop session to ask you on. this
happens over ssh. the tool refuses rather than guessing.

**`agent-secrets-gate: denied`, exit 77.** you said no. nothing retries this
automatically, and nothing should.

**`agent-secrets-gate: timeout`, exit 75.** the dialog went unanswered. try
again.

**`the installed helper speaks protocol N`.** you upgraded the commands but not
the root-owned helper, which is installed separately. the message names the
command that fixes it.

when none of that helps, `secret-doctor` prints your platform, versions, mode
and every missing dependency. it contains no secret values, so it is safe to
paste into an issue.
