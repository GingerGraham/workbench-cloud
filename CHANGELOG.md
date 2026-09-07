# Changelog

All notable changes to `workbench-cloud` are documented here.

## [Unreleased]

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
