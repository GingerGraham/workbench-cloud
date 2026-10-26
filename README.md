# workbench-cloud

AWS / Azure / Google Cloud CLI aliases and installers for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2) — meaningless
standalone. Requires `workbench-core` installed first:

```sh
wb add cloud
```

## What this gives you

- `aws-update` — runs `wb tools install aws` (fresh-install or
  update-in-place).
- `az*` aliases (`azl`/`azlo`/`azs`/`azsl`/`azss`) and `az-update`, which
  runs `wb tools install azure`.
- Installers for `aws`, `azure` and `gcloud` — `wb tools install <name>`
  to install, `wb tools upgrade <name>` to update one you already have.

`shell/aws.sh`/`shell/azure.sh` each self-guard on the matching CLI being
present, so installing this module doesn't add noise if you only use one
provider. `shell/gcloud.sh` puts `~/google-cloud-sdk/bin` on `PATH` when
`wb tools install gcloud` has installed the SDK there.

## What installers verify

| Installer | Source | Verification |
|---|---|---|
| `aws` (Linux) | AWS's CLI v2 installer zip | Detached signature checked against AWS's signing key, embedded in `shell/installers.sh` |
| `aws`, `azure` (macOS) | Homebrew | Homebrew's own checks |
| `azure` (Fedora) | Fedora's repositories | dnf's signature check |
| `azure` (rhel, debian, suse) | packages.microsoft.com | Only Microsoft's pinned key is trusted, from a local copy; the repo is limited to `azure-cli` |
| `azure` (Arch) | AUR `azure-cli` | Off unless `WORKBENCH_ALLOW_AUR=true` is set in `~/.config/workbench/local/settings.sh`. Otherwise it prints the `yay -S azure-cli` command and stops. An AUR package is an unreviewed build script |
| `azure` (other Linux) | pip, user site | pip's own checks only |
| `gcloud` | Google's installer script, `https://sdk.cloud.google.com` | **None.** The vendor script runs unverified (accepted, 2026-10 decision) |

## Requires

Nothing at install time — each CLI is installed by its own installer,
run with `wb tools install <name>`.
