# Khmer Shortcut Docker command

Reusable Docker stack scripts with global commands:

- `ksdc` -> `config.sh`
- `ksdd` -> `deploy.sh`
- `ksds` -> `stop.sh`
- `ksdl` -> `log.sh`
- `ksdn` -> `network.sh`
- `ksdu` -> `upgrade.sh`

These commands run against your current working directory, so you can use them
in any folder that contains `docker-compose.yml`, `docker-compose-prd.yml`, or
`docker-compose-stg.yml`.

`ksdc` keeps single-line secret entry simple and also lets you paste armored
multi-line keys such as `.asc` or `.pem` files directly at the prompt.

`ksdd` preflights `secrets` and `configs` before deploying. If a service uses a
secret/config that is not defined with `file:` or `external:`, it prompts for
the missing value, creates a Docker Swarm resource named `<stack>_<name>`, and
deploys with a temporary normalized compose file that points to that external
resource.

`ksdd` also supports parent-folder batch deploy mode: if the current folder does
not contain a compose file, it scans first-level child folders for
`docker-compose*.yml`, lists the stack names, and lets you deploy one, many, or
all of them sequentially.

## Install (Linux)

```sh
chmod +x install.sh
./install.sh
# or: sh install.sh (auto-reexecs with bash)
```

What `install.sh` does:

- Generates command aliases in `./.bin` from your current directory (`ksdc`, `ksdd`, `ksds`, `ksdl`, `ksdn`, `ksdu`)
- Points aliases to scripts in `src/`
- Appends this PATH export to `~/.bashrc` (if missing):
  `export PATH="<current-folder>/.bin:$PATH"`
- Appends `ksdl`/`ksdd`/`ksdn` autocomplete sourcing to `~/.bashrc` (if missing)
- For immediate effect in your current terminal:
  - Recommended: run `source ./install.sh`
  - If you ran `./install.sh`, installer will try to place shims in a writable
    directory already on your current `PATH`
  - If that is not possible, run:
    `export PATH="<current-folder>/.bin:$PATH"`
    (or `source <selected-profile-file>`)
  - For autocomplete in current shell:
    `source ./.bin/.ksdl-completion.bash` (this also loads `ksdd` and `ksdn` completion)

## Examples

```sh
cd /path/to/scripts
./install.sh

cd /path/to/project-with-docker-compose
ksdc
ksdd
ksdd --stack api --stack worker
ksdd --all
ksdd -c docker-compose.stg.yml
ksdn ensure -f docker-compose.yml
ksdn update internal-proxy_net --subnet=10.30.0.0/24 --yes
ksdn check 'proxy|default'
ksdd <TAB>             # suggest -f, --force, -c, --compose-file, -s, --stack, -a, --all
ksdd -c <TAB>          # suggest .yml/.yaml files
ksdd --stack <TAB>     # suggest stack names from first-level folders
ksdl <TAB>             # suggest available services
ksdn <TAB>             # suggest ensure/update/check and options
ksdl api <TAB>         # suggest common line counts
ksdl api 200
ksds
```
