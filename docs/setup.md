# setup

this is the install and hardening reference. if you are new, read
[the user guide](guide.md) instead: it walks through actually using the tool
and links back here when you are ready to lock the key down.

## 1. install the user commands

~~~bash
git clone https://github.com/jtayped/agent-secrets.git
cd agent-secrets
./install.sh
export PATH="$HOME/.local/bin:$PATH"
~~~

on fish, the last line is `fish_add_path ~/.local/bin` instead.

the installer creates these directories with restrictive permissions:

~~~text
~/.secrets/scopes
~/.secrets/index
~/.secrets/key
~~~

it creates ~/.secrets/key/.key only when no key exists. keep a backup of that file outside the scope backup. without it, encrypted scopes cannot be recovered.

## 2. create a scope

~~~bash
secret-edit example --new
~~~

your editor opens a small .env file. add an entry such as:

~~~dotenv
#@g service.api  api credentials used by the example service
#@d bearer token for the example api
SERVICE_API_TOKEN=replace-me
~~~

save and close the editor. the command encrypts the scope and builds its index.

browse it without decrypting anything. `secret-list` is an `ls`: a scope shows
its top level, a group shows one level inside it.

~~~bash
secret-list example
secret-list example service
secret-list example service.api
~~~

`secret-list example --tree` prints the whole thing at once when that is what
you want, and takes a group to scope it.

add a generated value without placing it in shell history:

~~~bash
openssl rand -base64 32 | secret-set example service.api.token --desc "token used by the example service"
~~~

secret-set derives SERVICE_API_TOKEN from the dotted path. it refuses an existing key unless you pass --force.

## 3. run a scoped command

~~~bash
secret-run example service.api -- bash -c 'test -n "$SERVICE_API_TOKEN"'
~~~

the helper runs the child command with only the selected group in its environment. it does not print the decrypted payload.

## 4. harden the key

the initial install runs the helper as your account. that mode is good for trying the workflow, but any process running as you can read the key file. make the helper and key root-owned:

~~~bash
sudo ~/.local/libexec/agent-secrets-install-root
secret-helper-status
~~~

the installer adds one sudoers entry for /usr/local/libexec/agent-secrets-helper. the helper validates its own arguments because sudoers cannot safely express the group and scope rules.

when you change lib/agent-secrets-helper, run ./install.sh and rerun the root installer.

## 5. mark a group sensitive

put #@sensitive immediately above a group declaration:

~~~dotenv
#@sensitive ttl=900
#@g service.production  production api credentials
SERVICE_PRODUCTION_TOKEN=replace-me
~~~

a sensitive group inherits that mark to child groups. access opens a confirmation dialog that names the requested group and motive. approvals last 15 minutes by default. a denial exits with code 77 and must not be retried.

on linux the dialog is zenity or kdialog; on macos it is an applescript dialog. without one of them sensitive groups cannot be approved at all.

one toolkit draws every dialog — the approval gate, the value prompt and the multi-field form — so that one operation never shows you two different widget sets. zenity is preferred where both are installed, because it is the only one that can draw all three: kdialog has no multi-field form, and where it is the only one present `secret-ask` asks for a set one credential at a time.

`secret-doctor` reports which one is in use, and whether a set arrives as one form.

if a task needs several known groups, request one batch approval first:

~~~bash
secret-approve example --motive "run the requested deployment check" service.production service.api
~~~

## optional sync

install and configure rclone, then choose a remote path that contains no decryption key:

~~~bash
AGENT_SECRETS_SYNC_REMOTE=remote:agent-secrets secrets-bisync
~~~

the script syncs scopes/ and index/. it never touches key/.

scopes/ is ciphertext and safe to put anywhere. index/ is not: it holds no values, but it does hold group names, key names and your descriptions, which together describe what credentials you have. set AGENT_SECRETS_SYNC_INDEX=0 to sync only the ciphertext and run secret-reindex on the other machine.

to run it on a timer, copy the two systemd files from ~/.local/libexec/agent-secrets/ into ~/.config/systemd/user/, replace replace-me:agent-secrets, then enable the timer:

~~~bash
systemctl --user daemon-reload
systemctl --user enable --now secrets-bisync.timer
~~~
