# Khmer Shortcut Docker command

Reusable Docker Swarm stack scripts behind a single global command, `ksd`:

- `ksd config`  -> `config.sh`
- `ksd deploy`  -> `deploy.sh`
- `ksd status`  -> `status.sh`
- `ksd stop`    -> `stop.sh`
- `ksd log`     -> `log.sh`
- `ksd network` -> `network.sh`
- `ksd update`  -> `update.sh`
- `ksd uninstall` -> `uninstall.sh`

These commands run against your current working directory, so you can use them
in any folder that contains `docker-compose.yml`, `docker-compose-prd.yml`, or
`docker-compose-stg.yml`.

Type `ksd` and press `<TAB>` to list available commands, or `ksd deploy` /
`ksd network` / `ksd log` and press `<TAB>` to complete their options and
arguments (see [Autocomplete](#autocomplete)).

`ksd config` keeps single-line secret entry simple and also lets you paste
armored multi-line keys such as `.asc` or `.pem` files directly at the prompt.

`ksd deploy` preflights `secrets` and `configs` before deploying. If a service
uses a secret/config that is not defined with `file:` or `external:`, it
prompts for the missing value, creates a Docker Swarm resource named
`<stack>_<name>`, and deploys with a temporary normalized compose file that
points to that external resource. For `external: true` resources, a missing
Docker resource is created with the external name itself, such as
`POSTGRES_PASSWORD`.

`ksd deploy` also checks every `external: true` network the stack's services
use (by its `name:` if set, with `${VAR}` / `${VAR:-default}` resolved from the
environment and `.env`). If the Docker network does not exist yet, it asks for:

- a driver mode: `overlay` (default, attachable), `overlay-encrypted`,
  `overlay-internal`, or `bridge` (swarm-scoped, one bridge per node)
- a subnet size: `auto` (Docker assigns it, default), `/24` to `/16`, a custom
  prefix such as `/26`, or an explicit subnet such as `10.20.0.0/22`. Not asked
  for a swarm-scoped bridge: Docker assigns its subnet on each node.

For a chosen size it picks the first free subnet of that size from the Swarm
default address pool, creates the network, and continues the deploy. Choosing `q` cancels the deploy. Without a terminal to ask on, the
deploy stops instead of guessing; create the network first with
`ksd network create <name> ... --yes`, which offers the same choices on its own.

`ksd deploy` also supports parent-folder batch deploy mode: if the current
folder does not contain a compose file, it scans first-level child folders for
`docker-compose*.yml`, lists the stack names, and lets you deploy one, many, or
all of them sequentially.

`ksd status` lists the stack's services with their mode, replicas, state
(`running`, `starting`, `failing`, `updating`, `update paused`, `rolled back`,
`scaled to 0`, ...) and image. For every service that is not healthy it adds
the details needed to fix it: the full task errors (for example
`No such image: ...`, `no suitable node (...)` or `task: non-zero exit (1)`),
the update/rollback message, and the last log lines of the most recent failed
task (`--logs N` to change, `--logs 0` to skip). `ksd status <service>` shows
one service with its task history. In a parent folder it checks every
first-level stack folder, like batch deploy. It exits with status 1 when a
service needs attention, so it can be used as a check after deploying.

```text
$ ksd status
Stack: shop
SERVICE  MODE        REPLICAS  STATE    IMAGE
api      replicated  2/2       running  registry.example.com/shop/api:2.4.0
worker   replicated  0/1       failing  registry.example.com/shop/worker:2.4.0

worker: failing, replicas 0/1
  TASK      STATE                   NODE    ERROR
  worker.1  Starting 2 seconds ago  node-2
  worker.1  Failed 9 seconds ago    node-2  task: non-zero exit (1)
  (2 older tasks with the same error)
  Last log lines of worker.1 (failed 9 seconds ago):
    Connecting to postgres://db:5432/shop
    Error: connect ECONNREFUSED 10.0.1.5:5432
  More: ksd log worker

1 of 2 services needs attention.
```

## Install

### Quick install (recommended)

No clone needed. This fetches the source into `~/.ksd` and installs the `ksd`
command:

```sh
curl -fsSL https://raw.githubusercontent.com/SengPhirum/KShortcutDocker/main/install.sh | bash
```

Prefer `wget`?

```sh
wget -qO- https://raw.githubusercontent.com/SengPhirum/KShortcutDocker/main/install.sh | bash
```

For immediate effect in your current terminal, source it instead of piping to
a subshell:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SengPhirum/KShortcutDocker/main/install.sh)" -- --bin-dir "$HOME/.ksd/bin"
source ~/.bashrc
```

or simply open a new terminal after installing.

### Install from a local clone

```sh
git clone https://github.com/SengPhirum/KShortcutDocker.git
cd KShortcutDocker
chmod +x install.sh
./install.sh
# or: sh install.sh (auto-reexecs with bash)
```

What `install.sh` does:

- Generates a single `ksd` wrapper in `./.bin` (local clone) or
  `~/.ksd/bin` (quick install) that dispatches to the scripts in `src/`
- Appends this PATH export to `~/.bashrc` (if missing):
  `export PATH="<bin-dir>:$PATH"`
- Appends `ksd` autocomplete sourcing to `~/.bashrc` (if missing)
- Removes wrappers/completion files from older versions of this tool
  (`kbc`/`kbd`/.../`ksdc`/`ksdd`/...)
- For immediate effect in your current terminal:
  - Recommended: run `source ./install.sh`
  - If you ran `./install.sh`, installer will try to place a shim in a
    writable directory already on your current `PATH`
  - If that is not possible, run:
    `export PATH="<bin-dir>:$PATH"`
    (or `source <selected-profile-file>`)
  - For autocomplete in current shell:
    `source ~/.ksd/bin/.ksd-completion.bash` (or `./.bin/.ksd-completion.bash`
    for a local clone)

## Autocomplete

```sh
ksd <TAB>              # lists: config deploy status stop log network update uninstall
ksd deploy <TAB>       # suggest -f, --force, -c, --compose-file, -s, --stack, -a, --all
ksd deploy -c <TAB>    # suggest .yml/.yaml files
ksd deploy --stack <TAB>  # suggest stack names from first-level folders
ksd status <TAB>       # suggest available services, -n/--logs
ksd log <TAB>          # suggest available services
ksd log api <TAB>      # suggest common line counts
ksd network <TAB>      # suggest create/ensure/update/check and options
ksd uninstall <TAB>    # suggest --bashrc, --keep-source, -y, --yes, --help
```

## Examples

```sh
cd /path/to/project-with-docker-compose
ksd config
ksd deploy
ksd deploy --stack api --stack worker
ksd deploy --all
ksd deploy -c docker-compose.stg.yml
ksd status
ksd status worker --logs 20
ksd network ensure -f docker-compose.yml
ksd network create traefik-public
ksd network create backend --driver overlay --size /22 --yes
ksd network update internal-proxy_net --subnet=10.30.0.0/24 --yes
ksd network check 'proxy|default'
ksd log api 200
ksd stop
ksd update
```

Updating later is just:

```sh
ksd update
```

## Uninstall

```sh
ksd uninstall
```

This removes the `ksd` command (and any leftover wrappers from earlier
versions of this tool) from every `PATH` directory it was installed in, its
completion file(s), and the PATH/completion lines it added to `~/.bashrc`
(a backup of the original file is kept alongside it). If this was a quick
install, it also deletes the cloned source in `~/.ksd`.

Skip the confirmation prompt with `-y`/`--yes`, or keep the cloned source
around with `--keep-source`.
