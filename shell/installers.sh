#!/usr/bin/env bash
# shell/installers.sh — workbench-cloud
# install-aws, install-azure, install-gcloud and their per-distro helpers.
# Ported from workbench-precursor's lazy/installers-iac.sh (the cloud-CLI
# slice — despite that file's name, these three are cloud-CLI installers,
# not IaC, per the Wave C module map §3).
#
# WORKBENCH_OS/WORKBENCH_DISTRO/WORKBENCH_ARCH are workbench-core Core API
# platform facts (contracts/core-api.md), replacing the precursor's
# DOTFILES_OS/DOTFILES_DISTRO. _download_file_robust comes from
# workbench-core's Core API (lib/core/installers-common.sh).
#
# install-gcloud drops the precursor's _restore_managed_shell_files call:
# that helper reset workbench-precursor's rc files to their git-committed
# state after an installer script (Google's own) tried to inject PATH/
# completion lines into them, since those rc files were live symlinks into
# a git working tree and an uncommitted diff there would block the sync
# timer. workbench-core's rc files are plain stub files written once by
# `wb install`/`wb apply` (ARCHITECTURE.md §12 D19), never a git-tracked
# working copy — the problem this workaround solved doesn't exist here.

# ── AWS CLI install ───────────────────────────────────────────────────────────
# AWS ships the CLI v2 as a self-contained installer bundle rather than distro
# packages, so the same curl+unzip flow covers every Linux distro; only macOS
# differs (Homebrew).
_aws-install-linux() {
    local arch
    case "${WORKBENCH_ARCH}" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) log_error "AWS CLI: unsupported architecture ${WORKBENCH_ARCH}"; return 1 ;;
    esac
    command -v curl &>/dev/null || { log_error "curl is required for AWS CLI installation"; return 1; }
    command -v unzip &>/dev/null || { log_error "unzip is required for AWS CLI installation"; return 1; }

    local tmp_dir; tmp_dir="$(mktemp -d)"
    log_info "Downloading AWS CLI installer (${arch})..."
    _download_file_robust "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" "${tmp_dir}/awscliv2.zip" \
        || { rm -rf "${tmp_dir}"; return 1; }
    unzip -q "${tmp_dir}/awscliv2.zip" -d "${tmp_dir}" \
        || { log_error "AWS CLI: failed to extract installer"; rm -rf "${tmp_dir}"; return 1; }

    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || { rm -rf "${tmp_dir}"; return 1; }
    local rc=0
    if command -v aws &>/dev/null; then
        local aws_path; aws_path="$(command -v aws)"
        ${elevation_cmd} "${tmp_dir}/aws/install" --update --bin-dir "$(dirname "${aws_path}")" || rc=1
    else
        ${elevation_cmd} "${tmp_dir}/aws/install" || rc=1
    fi
    rm -rf "${tmp_dir}"
    return "${rc}"
}

_aws-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v aws &>/dev/null; then brew upgrade awscli; else brew install awscli; fi
}

install-aws() {
    log_info "Installing or updating AWS CLI..."
    case "${WORKBENCH_OS}" in
        Linux) _aws-install-linux ;;
        Mac)   _aws-install-mac ;;
        *)     log_error "Unsupported OS for AWS CLI install"; return 1 ;;
    esac
    local rc=$?

    if [[ ${rc} -eq 0 ]] && command -v aws &>/dev/null; then
        log_info "AWS CLI installed: $(aws --version 2>&1 | head -1)"
    elif [[ ${rc} -ne 0 ]]; then
        log_error "AWS CLI install failed"
    else
        log_warn "aws not found on PATH after install."
    fi
    return "${rc}"
}

installed-aws() {
    command -v aws &>/dev/null
}

# ── Azure CLI install ─────────────────────────────────────────────────────────
# Microsoft publishes a vendor repo for rhel/debian/suse (packages.microsoft.com);
# Arch has no official package, so it falls back to the community AUR package
# (same yay-or-manual-makepkg pattern as workbench-security's install-1password
# arch helper); any other/unknown distro falls back further to pip, which
# works everywhere Python does. macOS uses Homebrew.
_azure-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if [[ ! -f /etc/yum.repos.d/azure-cli.repo ]]; then
        ${elevation_cmd} sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
    fi

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y azure-cli
    else
        ${elevation_cmd} yum install -y azure-cli
    fi
}

_azure-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    ${elevation_cmd} mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
        | ${elevation_cmd} gpg --dearmor --output /etc/apt/keyrings/microsoft.gpg
    ${elevation_cmd} chmod go+r /etc/apt/keyrings/microsoft.gpg

    local az_dist
    az_dist="$(lsb_release -cs 2>/dev/null)"
    # shellcheck disable=SC1091
    [[ -z "${az_dist}" ]] && az_dist="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
    [[ -z "${az_dist}" ]] && { log_error "azure-cli: could not determine distro codename"; return 1; }

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${az_dist} main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/azure-cli.list > /dev/null

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y azure-cli
}

_azure-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if ! zypper lr 2>/dev/null | grep -qi 'azure-cli'; then
        ${elevation_cmd} zypper addrepo --name 'Azure CLI' --check https://packages.microsoft.com/yumrepos/azure-cli azure-cli
    else
        log_info "azure-cli zypper repo already present"
    fi
    ${elevation_cmd} zypper --gpg-auto-import-keys refresh
    ${elevation_cmd} zypper install -y --from azure-cli azure-cli
}

_azure-install-arch() {
    # No official Arch package — community-maintained AUR package.
    if command -v yay &>/dev/null; then
        yay -S --noconfirm azure-cli
    else
        log_info "yay not found — cloning azure-cli AUR package manually..."
        local tmp_dir; tmp_dir="$(mktemp -d)"
        git clone https://aur.archlinux.org/azure-cli.git "${tmp_dir}/azure-cli" \
            || { log_error "Failed to clone azure-cli AUR package"; rm -rf "${tmp_dir}"; return 1; }
        ( cd "${tmp_dir}/azure-cli" && makepkg -si --noconfirm )
        rm -rf "${tmp_dir}"
    fi
}

_azure-install-pip() {
    local pip_cmd
    pip_cmd="$(command -v pip3 || command -v pip)"
    [[ -z "${pip_cmd}" ]] && { log_error "pip3 (or pip) is required to install Azure CLI without a supported distro repo"; return 1; }
    log_info "azure-cli: installing via ${pip_cmd} into the user site..."
    "${pip_cmd}" install --user --upgrade azure-cli
}

_azure-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v az &>/dev/null; then brew upgrade azure-cli; else brew install azure-cli; fi
}

install-azure() {
    log_info "Installing or updating Azure CLI..."

    case "${WORKBENCH_OS}" in
        Mac)
            _azure-install-mac || { log_error "Azure CLI: mac install failed"; return 1; }
            ;;
        Linux)
            # pip is only a fallback for a genuinely unrecognised distro — a
            # real failure on a known distro (repo/network issue, etc.)
            # surfaces as an error instead of silently retrying via pip and
            # risking a mixed system-package + pip install.
            case "${WORKBENCH_DISTRO}" in
                rhel)   _azure-install-rhel   || { log_error "Azure CLI: rhel install failed"; return 1; } ;;
                debian) _azure-install-debian || { log_error "Azure CLI: debian install failed"; return 1; } ;;
                suse)   _azure-install-suse   || { log_error "Azure CLI: suse install failed"; return 1; } ;;
                arch)   _azure-install-arch   || { log_error "Azure CLI: arch install failed"; return 1; } ;;
                *)
                    log_warn "Unknown distro (${WORKBENCH_DISTRO}) — falling back to pip install"
                    _azure-install-pip || return 1
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported OS for Azure CLI install"; return 1
            ;;
    esac

    if command -v az &>/dev/null; then
        log_info "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || az --version 2>/dev/null | head -1)"
        echo
        echo "  Authenticate with:"
        echo "    az login"
    else
        log_warn "az not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}

# Azure CLI's binary is az, not azure.
installed-azure() {
    command -v az &>/dev/null
}

# ── Google Cloud CLI (gcloud) install ─────────────────────────────────────────
# Google's official interactive installer is the same script on every distro
# and macOS (no vendor apt/dnf/zypper repo baked in by default), so there is
# no per-distro branching here — unlike aws/azure. Installs to
# ~/google-cloud-sdk and self-updates thereafter via `gcloud components update`.
#
# The upstream script offers, interactively, to append PATH/completion
# sourcing to shell rc files; --disable-prompts skips that entirely in a
# non-interactive run.
install-gcloud() {
    log_info "Installing or updating Google Cloud CLI (gcloud)..."

    if command -v gcloud &>/dev/null; then
        local gcloud_path; gcloud_path="$(command -v gcloud)"
        # `gcloud components update` only works for this function's own
        # ~/google-cloud-sdk install — the components manager is disabled on
        # package-manager installs (apt/dnf/brew), so it would just fail there.
        if [[ "${gcloud_path}" == "${HOME}/google-cloud-sdk/bin/gcloud" ]]; then
            log_info "gcloud found at ${gcloud_path} — updating components..."
            gcloud components update --quiet
            return $?
        fi
        log_warn "gcloud found at ${gcloud_path}, not the ~/google-cloud-sdk install this function manages."
        log_warn "It looks package-manager-installed — use that package manager (apt/dnf/brew/etc.) to update it instead."
        return 0
    fi

    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts \
        || { log_error "Google Cloud CLI installer failed"; return 1; }

    local sdk_bin="${HOME}/google-cloud-sdk/bin"
    [[ ":${PATH}:" != *":${sdk_bin}:"* ]] && PATH="${sdk_bin}:${PATH}"

    if command -v gcloud &>/dev/null; then
        log_info "Google Cloud CLI installed: $(gcloud --version 2>/dev/null | head -1)"
        echo
        echo "  ~/google-cloud-sdk/bin is not added to your managed shell rc files automatically."
        echo "  Add it to PATH yourself in ~/.config/workbench/local/settings.sh, e.g.:"
        echo "    export PATH=\"\${HOME}/google-cloud-sdk/bin:\${PATH}\""
        echo
        echo "  Authenticate with:"
        echo "    gcloud init"
    else
        log_warn "gcloud not found on PATH after install. Check ~/google-cloud-sdk/bin."
    fi
}

installed-gcloud() {
    command -v gcloud &>/dev/null
}
