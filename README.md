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
provider.

## Requires

Nothing at install time — each CLI is installed by its own installer,
run with `wb tools install <name>`.
