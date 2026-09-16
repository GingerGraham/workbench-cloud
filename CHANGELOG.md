# Changelog

All notable changes to `workbench-cloud` are documented here.

## [Unreleased]

### Fixed

- **`get-cloud-functions` no longer lists `aws-update`, `az-update`, or
  `az`'s aliases (`azl`, `azlo`, `azs`, `azsl`, `azss`) on hosts missing
  the corresponding CLI** — these were already self-gated undefined at
  the file level (`command -v aws`/`command -v az` guards), but the
  getter's static-grep listing couldn't see that runtime guard and
  listed them regardless. Declares `_wb_declare_availability` predicates
  for each, per `workbench-core`'s shared `_<name>-available` convention
  (`workbench-core`'s `docs/module-authoring.md`, once merged — this repo
  has no `docs/` directory of its own).

## [0.2.1] - 2026-09-15

### Added

- **Agent-instruction files** (`AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md`,
  `.claude/skills/conventional-commits/SKILL.md`) — ports
  `workbench-core`'s D32 agent-instruction topology to this repo. See
  `workbench-core`'s `docs/decisions-log.md` D58.
- **Repo governance files** (`.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`,
  `.github/CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`) — ports
  `workbench-core`'s D31 governance-file topology to this repo,
  piloted on `workbench-git` first. See `workbench-core`'s
  `docs/decisions-log.md` D60.

### Fixed

- **`install-gcloud` no longer pipes the Google Cloud SDK install script
  straight into `bash`** — it now downloads to a temp file via
  `_download_file_robust`, verifies the download landed and is non-empty,
  then executes the file. Closes a `scan-patterns` CI finding
  (remote-script-execution pattern).

## [0.2.0] - 2026-09-09

- Added `installed-aws`, `installed-azure`, `installed-gcloud` — reports
  install status to `wb tools upgrade`/`list --status` (workbench-core
  §12 D43).

## [0.1.0] - 2026-09-09

### Added

- Initial decomposition from `workbench-precursor` (Wave C): `aws-update`,
  `az*` aliases + `az-update`, and `install-aws`/`install-azure`/
  `install-gcloud`, split out of the precursor's grab-bag `installers-iac.sh`
  (despite that file's name, these three are cloud-CLI installers, not IaC).

### Changed

- `install-gcloud` drops the precursor's `_restore_managed_shell_files`
  call — that workaround reset git-tracked rc-file symlinks after Google's
  installer script touched them; `workbench-core`'s rc files are plain
  stubs, never a live git working tree, so the problem it solved doesn't
  exist here.
- `WORKBENCH_OS`/`WORKBENCH_DISTRO`/`WORKBENCH_ARCH` replace
  `DOTFILES_OS`/`DOTFILES_DISTRO`.

### Fixed

- `get-cloud-functions` moved ahead of `shell/aws.sh`'s `command -v aws`
  guard — it's the module's sole registered getter, so on an Azure-only
  machine (no `aws` CLI) it was previously never defined, making `azure.sh`'s
  `az*` aliases/`az-update` unenumerable via `wb functions`.
- `install-azure`'s macOS branch now propagates `_azure-install-mac`'s exit
  status instead of always returning success.
