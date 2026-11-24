# workbench-cloud

AWS / Azure / Google Cloud CLI aliases and installers, and the AWS Emulator,
for the [`workbench`](https://github.com/GingerGraham/workbench-core)
ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2) — meaningless
standalone. Requires `workbench-core` installed first:

```sh
wb add cloud
```

## What this gives you

- `aws-update` — runs `wb tools install aws` (fresh-install or
  update-in-place). On Linux, an existing `aws` is only updated in place
  if the directory it lives in (and every parent) is root-owned and not
  writable by you; otherwise the install stops with an explanation and
  changes nothing.
- `az*` aliases (`azl`/`azlo`/`azs`/`azsl`/`azss`) and `az-update`, which
  runs `wb tools install azure`. An alias is not defined when your shell already has an alias or function of that name; yours is kept, and `wb status` lists what was left alone.
- Installers for `aws`, `azure`, `gcloud` and `aws-emulator` — `wb tools install <name>`
  to install, `wb tools upgrade <name>` to update one you already have.
- The AWS Emulator, a local emulator for AWS APIs:
  - `aws-emulator-server` — start an instance on the first free port from 9297.
  - `aws-emulator-use [<port>]` — point this shell's AWS CLI and SDKs at an instance. `--off` undoes it.
  - `aws-emulator-list` — instances workbench can see, and whether they answer.
  - `aws-emulator-stop <port> | --all` — stop instances started with `--detach`.
  - `aws-emulator-update` — runs `wb tools install aws-emulator`.

`shell/aws.sh`/`shell/azure.sh` each self-guard on the matching CLI being
present, so installing this module doesn't add noise if you only use one
provider. `shell/gcloud.sh` puts `~/google-cloud-sdk/bin` on `PATH` when
`wb tools install gcloud` has installed the SDK there.

## AWS Emulator

```sh
wb tools install aws-emulator
aws-emulator-server --detach        # 9297, or the next free port
aws-emulator-use 9297
aws s3 mb s3://demo
aws-emulator-use --off
aws-emulator-stop 9297
```

`wb tools install aws-emulator` is also the update command. It compares the
installed version with the highest in AWS's version list, does nothing when
they match, and never downgrades. A running instance keeps its old version
until you restart it. A first start takes about ten seconds.

`aws-emulator-server` takes `-b|--bind <ip>|all`, `-p|--port <port>`,
`-d|--detach` and `--allow-unauthenticated`. Options after `--` go to the
emulator, for example `aws-emulator-server -- --idle-timeout 600`.

### Settings

Set these in `~/.config/workbench/local/settings.sh`.

| Setting | Default | Meaning |
|---|---|---|
| `WORKBENCH_AWS_EMULATOR_ROUTE` | `auto` | `auto`, `package` or `container`. `auto` uses AWS's package on rhel and debian family hosts, and a locally built image on everything else (macOS, Arch, SUSE, unknown distributions, rpm-ostree) |
| `WORKBENCH_AWS_EMULATOR_ENGINE` | first installed | `podman`, `docker` or `apple` |
| `WORKBENCH_AWS_EMULATOR_BIND` | ask, else `127.0.0.1` | An IPv4 address of this host, or `all` for `0.0.0.0` |
| `WORKBENCH_AWS_EMULATOR_PORT` | `9297` | Where the search for a free port starts. It tries 100 ports |
| `WORKBENCH_AWS_EMULATOR_MEMORY` | `2g` | Memory limit for container instances |

When neither `--bind` nor the setting is given, the host has an address other
than loopback, and a terminal is available, `aws-emulator-server` asks which
address to listen on. The default is `127.0.0.1`.

### Containers

AWS publishes no image. Workbench builds one from AWS's Dockerfile and the
verified package. Engines are tried in this order: podman, Docker (the real
one; the `podman-docker` shim doesn't count), then Apple's `container` CLI on
Apple silicon. Workbench never installs an engine for this tool.

AWS documents only Docker. Podman and Apple `container` build and run the
same Dockerfile, but AWS has not tested them.

Each rebuild pulls the base image again (`amazonlinux:2023-minimal`), so it
picks up Amazon Linux updates. The image is tagged `:latest` and with its
version.

### Network access

The default bind is `127.0.0.1`. Binding another address makes the instance
reachable from other machines on that network, and the emulator's resource
endpoint ports, which check no request signature, are open there too.

- A non-loopback bind with `--auth off` is refused unless you pass `--allow-unauthenticated`.
- Apple's `container` forwards ports from the loopback address only, so a non-loopback bind is refused there.
- Workbench never changes firewall rules. With firewalld running, `aws-emulator-server` prints the `firewall-cmd` line that opens the port until reboot.
- The emulator's certificate lists `localhost`, `127.0.0.1` and `::1`. A native instance bound to a specific address adds that address. Binding `0.0.0.0`, and container instances, don't add one (not checked for containers). A client on another machine needs the instance's `~/.aws/emulator/<port>/ca.pem`, and the host name check can still fail for an address that is not in the list.
- Telemetry is on by default in the emulator. Turn it off for one instance with `aws-emulator-server -- -t off`, or set `EMULATOR_TELEMETRY=off` for native instances.

### Removing it

```sh
sudo dnf remove aws-emulator          # or: sudo apt-get remove aws-emulator
podman rmi workbench-aws-emulator:latest workbench-aws-emulator:<version>   # or docker rmi / container image delete
```

`rm -rf ~/.aws/emulator` removes instance files, only when no instance is
running. Detached instances keep a pid, log and bind file under
`${XDG_STATE_HOME:-~/.local/state}/workbench/cloud/aws-emulator/`.

## What installers verify

| Installer | Source | Verification |
|---|---|---|
| `aws` (Linux) | AWS's CLI v2 installer zip | Detached signature checked against AWS's signing key, embedded in `shell/installers.sh` |
| `aws`, `azure` (macOS) | Homebrew | Homebrew's own checks |
| `azure` (Fedora) | Fedora's repositories | dnf's signature check |
| `azure` (rhel, debian, suse) | packages.microsoft.com | Only Microsoft's pinned key is trusted, from a local copy; the repo is limited to `azure-cli` |
| `azure` (Arch) | AUR `azure-cli` | Off unless `WORKBENCH_ALLOW_AUR=true` is set in `~/.config/workbench/local/settings.sh`. Otherwise it prints the `yay -S azure-cli` command and stops. An AUR package is an unreviewed build script |
| `azure` (other Linux) | pip, user site | pip's own checks only |
| `aws-emulator` (rhel, debian) | AWS's RPM/DEB from `downloads.aws.com` | Detached signature checked against AWS's SSM Publishing key, embedded in `shell/installers-aws-emulator.sh`. Installed from the checked local file |
| `aws-emulator` (container) | The same RPM, built into a local image | The RPM is checked as above before it is copied in. The base image (`amazonlinux:2023-minimal`, AWS public ECR) is pulled by tag, not digest, so rebuilds pick up its updates |
| `gcloud` | Google's installer script, `https://sdk.cloud.google.com` | **None.** The vendor script runs unverified (accepted, 2026-10 decision) |

## Requires

Nothing at install time — each CLI is installed by its own installer,
run with `wb tools install <name>`.
