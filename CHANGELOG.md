# Changelog

All notable changes to `workbench-cloud` are documented here.

## [Unreleased]

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
