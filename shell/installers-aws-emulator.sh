#!/usr/bin/env bash
# shell/installers-aws-emulator.sh — workbench-cloud
# install-aws-emulator and installed-aws-emulator: install or update the AWS
# Emulator (workbench-core docs/decisions-log.md D128).
#
# Two routes, one tool name (`wb tools install aws-emulator`):
#   package    AWS's RPM or DEB, on rhel and debian family hosts that can
#              install packages. Installed from a local file that was
#              signature-checked first.
#   container  a locally built image, everywhere else (macOS, Arch, SUSE,
#              unknown distros, rpm-ostree). AWS publishes no prebuilt image,
#              so the same RPM is checked on the host and copied into an
#              image built from AWS's own Dockerfile.
# WORKBENCH_AWS_EMULATOR_ROUTE=auto|package|container overrides the choice.
#
# This file stands alone: `wb tools` sources only the file that holds the
# install-<name> it runs (_wb_tools_invoke, workbench-core bin/wb), so
# helpers in shell/installers.sh are not visible here. That is why the verify
# function below is written a second time rather than shared. It runs only
# in bash, and keeps to bash 3.2.
#
# Installers run under `wb tools`, which turns errexit, nounset and pipefail off
# (D93), so unset variables are not errors here.

# ── shared with shell/installers-aws-emulator.sh — keep identical ─────────────
# tests/check-aws-emulator.sh fails if the two copies differ.

_AWSEMU_IMAGE="workbench-aws-emulator"
_AWSEMU_OSTREE_MARKER="${_AWSEMU_OSTREE_MARKER:-/run/ostree-booted}"

# _awsemu_bin_path <name> — path of an executable on PATH. Ignores aliases
# and functions: zsh's `command -v` reports an alias first.
_awsemu_bin_path() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        whence -p "$1" 2>/dev/null
    else
        type -P "$1" 2>/dev/null
    fi
}

# _awsemu_route — prints package or container. auto: the vendor package on
# rhel/debian family hosts that can install packages (not rpm-ostree),
# otherwise a locally built image (D128 item 2).
_awsemu_route() {
    case "${WORKBENCH_AWS_EMULATOR_ROUTE:-auto}" in
        package|container) printf '%s\n' "${WORKBENCH_AWS_EMULATOR_ROUTE}"; return 0 ;;
        auto) ;;
        *)
            log_error "aws-emulator: WORKBENCH_AWS_EMULATOR_ROUTE must be auto, package or container (got '${WORKBENCH_AWS_EMULATOR_ROUTE}')"
            return 1
            ;;
    esac
    if [ "${WORKBENCH_OS:-}" = "Linux" ] && [ ! -e "${_AWSEMU_OSTREE_MARKER}" ]; then
        case "${WORKBENCH_DISTRO:-unknown}" in
            rhel|debian) echo package; return 0 ;;
        esac
    fi
    echo container
}

# _awsemu_real_docker — true for the Docker CLI. The podman-docker shim is
# also a `docker` binary; it is told apart by what --version prints (same
# test as workbench-containers' _containers_real_docker).
_awsemu_real_docker() {
    [ -n "$(_awsemu_bin_path docker)" ] || return 1
    docker --version 2>/dev/null | grep -q '^Docker version'
}

# _awsemu_engine — prints podman, docker or apple: the engine named by
# WORKBENCH_AWS_EMULATOR_ENGINE, else the first installed in that order.
# Fails when none is installed. Doesn't check that the engine is running.
_awsemu_engine() {
    case "${WORKBENCH_AWS_EMULATOR_ENGINE:-}" in
        podman|docker|apple) printf '%s\n' "${WORKBENCH_AWS_EMULATOR_ENGINE}"; return 0 ;;
        "") ;;
        *)
            log_error "aws-emulator: WORKBENCH_AWS_EMULATOR_ENGINE must be podman, docker or apple (got '${WORKBENCH_AWS_EMULATOR_ENGINE}')"
            return 1
            ;;
    esac
    if [ -n "$(_awsemu_bin_path podman)" ]; then echo podman; return 0; fi
    if _awsemu_real_docker; then echo docker; return 0; fi
    if [ "${WORKBENCH_OS:-}" = "Mac" ] && [ -n "$(_awsemu_bin_path container)" ]; then
        echo apple; return 0
    fi
    return 1
}

# _awsemu_engine_cmd <engine> — the command for an engine name.
_awsemu_engine_cmd() {
    case "$1" in
        apple) echo container ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# _awsemu_engine_usable <engine> — true when the engine answers (daemon,
# podman machine or Apple's container system is running).
_awsemu_engine_usable() {
    case "$1" in
        podman) podman info >/dev/null 2>&1 ;;
        docker) docker info >/dev/null 2>&1 ;;
        apple)  container system status >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# _awsemu_engine_start_hint <engine> — how to start an engine that isn't
# answering.
_awsemu_engine_start_hint() {
    case "$1:${WORKBENCH_OS:-}" in
        podman:Mac)   echo "podman machine start" ;;
        podman:*)     echo "check 'podman info' for the error" ;;
        docker:Mac)   echo "start Docker Desktop" ;;
        docker:*)     echo "systemctl --user start docker (rootless) or sudo systemctl start docker" ;;
        apple:*)      echo "container system start" ;;
    esac
}

# _awsemu_parse_version — the first X.Y.Z in `aws-emulator -v` output on
# stdin, preferring the line that starts with "Version".
_awsemu_parse_version() {
    awk '
        tolower($0) ~ /^version/ && v == "" {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/)) v = substr($0, RSTART, RLENGTH)
        }
        any == "" && match($0, /[0-9]+\.[0-9]+\.[0-9]+/) { any = substr($0, RSTART, RLENGTH) }
        END { if (v != "") print v; else if (any != "") print any }'
}
# ── end shared ─────────────────────────────────────────────────────────────────

# ── Package signing key ───────────────────────────────────────────────────────
# AWS Emulator package signing key ("SSM Publishing
# <ssm-publishing@amazon.com>") — downloaded from
# https://downloads.aws.com/keys/gpg/current.asc on 2026-11-24; fingerprint
# checked against the AWS Emulator user guide ("Verify the package"),
# getting-started-linux.html.
# Fingerprint: 98BCF336A3BE53B734E967C52E5BF49BD940F624. Key expires never
# (no expiry date is set on it). If verification starts failing with an
# expired or unknown key, refresh this block from the same URL and re-check
# the fingerprint on the docs page.
_awsemu_public_key() {
    command cat <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 98BC F336 A3BE 53B7 34E9  67C5 2E5B F49B D940 F624
Comment: SSM Publishing <ssm-publishing@amazon.com>

xsFNBGpea24BEACTZvlXnGJPWFzl5HA8leteS+5BRNVRe344uxJj89bdfig8gQLJ
afoiKWZ7x19YT6YUuPowfr8Zc21oUmArZn0y6xqjwSryiVjnqMWUnTHY04pajJSq
bgtrB4SYK3Y1HgCp6xFllnqDKSBqb2qgYC6WMIBiVBkkdiQxORyREnoMQjnjMBj2
TnrXpHS5h4BZdtzj+WyIDHkpmO7Y64hasPZlNEZH0ZLJqyrkZQPdtJBbLC1gxez5
yqiaxWnufYx1pMVLLI7o4kvAwY6B4X4Tdi8ZG+8RKdV7OlApDt7p28USQOQfSJGs
Dx1jXBQ6VF2/3tPJCCnaXDLkJsqUpxU6Txb+Env6IaUcs4nC9DI0amjE/IeEoXS/
+RnNGidyjJkZtGwnksqxNrtznM5VyEF7lSO3FYdlGtchWOdmdcqKvWSsxuX/qb9T
VoI2Jqt3Ezefbr3imK1xOvkIsrXEG4rLmCzo6dUP9jt3uQWsp0OuSb4GPc/TE6cb
d7scnPObhBNUCLYO0Np6O8pgzZcdlpQaGAY5XRG8y0nFYNKD1lqeJwNtRoA8RpZh
I5bcZIRpFXT9fx/wd78O6P3XyFE107lpvBhbPigAkmtzY0YyMeS5T5HocbgAlsy0
IBJUMjFe2JlqF6LpxvyR3UPxgVx6UTxrvtnBRV6+tiAxaa8f1gha+XbFEQARAQAB
zSpTU00gUHVibGlzaGluZyA8c3NtLXB1Ymxpc2hpbmdAYW1hem9uLmNvbT7Cwb4E
EwEKAHIFgmrrUOcJEC5b9JvZQPYkRxQAAAAAAB4AIHNhbHRAbm90YXRpb25zLnNl
cXVvaWEtcGdwLm9yZyvsTXzac/wo+ScPRGt93f4AbTbKGfKLuubkuXd9s3ynApsD
FiEEmLzzNqO+U7c06WfFLlv0m9lA9iQAAILkD/wPYBplNY1Sv9BT/2ABCLLZMVjg
2ywyV5Wja2nR68TdQHvKVLMGxyrQvVHWV7+iybvEyMDkqpLdwl1VWjq6tD6oeepf
ChDYyAFHtVb5vz+8rQ06/erMYrQtVW9b9qtQ9VK0dRRBzj3sLknJBNQZyqSFburL
29BGHneyF1P7S+QiRw9RmQPS05S8Y9j9iAiA/Prmrte3KwJBP6F78Z2dyNGfIQh+
d7HcMMd7XZ0ycOOjx8TB5bzhzRCzyAKZpOSjDnH1zPPDv9sq2vtJigkGj0/m0MYM
C+IqceYr1zYr91AreF7n27d29MMz2l0WF+Pv81EBBultE58dx8lFRQmZ04l19SX4
xsfPAOV15PIxoxX29nBFyt8nqir9byFg/njNV21yD9hGYBXTbve1E/zioL6/7HfV
a/4UJadYUakfFe7Q2MGUIC0a+w7xjj4aeP8dNMXUATiym5hpcKRG1FNv8uoomDHu
963MhCaC2mE/kAEX+6314DYa77lSqckA0B5lqDSYNmd5wgC/hD+1AJGI45Eb/UTU
dzf5VPmjSeT0hyOr1sOT0c2kEHhhq2DiN3ZOji2E8OEVDKg00gPxapwKy+qfm2Ko
H3XZxgxybz7s1txMpc/9Ll1+N7eFNOM4jWPzJ+U8bHFy7dGpR+/SHeO2YWfUqmGs
fd/p4hphN70BiHCoNA==
=sUZh
-----END PGP PUBLIC KEY BLOCK-----
EOF
}

# _awsemu_verify <file> <sig>
# Verifies the detached signature against the embedded key only, in a
# throwaway keyring. The user's keyring is never read or changed.
_awsemu_verify() {
    local file="$1" sig="$2" gnupg_home rc
    if ! command -v gpg &>/dev/null || ! command -v gpgv &>/dev/null; then
        log_error "gpg and gpgv are required to verify the AWS Emulator package (install the gnupg package)"
        return 1
    fi
    gnupg_home="$(mktemp -d)" || return 1
    if ! _awsemu_public_key | gpg --homedir "${gnupg_home}" --dearmor --output "${gnupg_home}/aws.gpg" 2>/dev/null; then
        log_error "AWS Emulator: failed to import the embedded signing key"
        rm -rf "${gnupg_home}"
        return 1
    fi
    gpgv --keyring "${gnupg_home}/aws.gpg" "${sig}" "${file}" 2>/dev/null
    rc=$?
    rm -rf "${gnupg_home}"
    return ${rc}
}

# ── Assets and versions ───────────────────────────────────────────────────────
_AWSEMU_BASE_URL="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS"

# _awsemu_asset <rpm|deb> <version|""> — prints the package URL. With no
# version, the LTS/latest/ URL. Fails for an architecture AWS doesn't ship.
_awsemu_asset() {
    local kind="$1" version="$2" arch
    case "${kind}:${WORKBENCH_ARCH}" in
        rpm:x86_64|rpm:amd64)   arch="x86_64" ;;
        rpm:aarch64|rpm:arm64)  arch="aarch64" ;;
        deb:x86_64|deb:amd64)   arch="amd64" ;;
        deb:aarch64|deb:arm64)  arch="arm64" ;;
        *) log_error "aws-emulator: no ${kind} package for architecture ${WORKBENCH_ARCH}"; return 1 ;;
    esac
    if [[ -z "${version}" ]]; then
        case "${kind}" in
            rpm) printf '%s/latest/aws-emulator-%s.rpm\n' "${_AWSEMU_BASE_URL}" "${arch}" ;;
            deb) printf '%s/latest/aws-emulator_%s.deb\n' "${_AWSEMU_BASE_URL}" "${arch}" ;;
        esac
    else
        case "${kind}" in
            rpm) printf '%s/aws-emulator-%s-1-%s.rpm\n' "${_AWSEMU_BASE_URL}" "${version}" "${arch}" ;;
            deb) printf '%s/aws-emulator_%s-1_%s.deb\n' "${_AWSEMU_BASE_URL}" "${version}" "${arch}" ;;
        esac
    fi
}

# _awsemu_versions_from_json — reads versions.json on stdin and prints one
# release version per line, as X.Y.Z.
#
# The file is one object, {"versions":[{"productId":"aws-emulator",
# "releaseStream":"LTS","version":"1.0.598.1"}, ...]}. Each "version" is the
# release (1.0.598) followed by the package release number (.1). The
# versioned download URLs use the release and a fixed "-1-" for the package
# release, so the last part is dropped here. Only the value of a "version"
# key is read; other numbers in the file are ignored.
_awsemu_versions_from_json() {
    awk '
        {
            n = split($0, parts, /[{},]/)
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ /"version"[[:space:]]*:/ && match(parts[i], /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                    v = substr(parts[i], RSTART, RLENGTH)
                    sub(/\.[0-9]+$/, "", v)
                    print v
                }
            }
        }'
}

# _awsemu_version_highest — the highest X.Y.Z on stdin. A module-local copy:
# core's _wb_semver_* is not documented Core API.
_awsemu_version_highest() {
    awk -F. '
        /^[0-9]+\.[0-9]+\.[0-9]+$/ {
            if (best == "" || $1 > b1 || ($1 == b1 && ($2 > b2 || ($2 == b2 && $3 > b3)))) {
                best = $0; b1 = $1 + 0; b2 = $2 + 0; b3 = $3 + 0
            }
        }
        END { if (best != "") print best }'
}

# _awsemu_version_cmp <a> <b> — prints -1, 0 or 1 for a<b, a=b, a>b, comparing
# X.Y.Z numerically part by part.
_awsemu_version_cmp() {
    awk -F. -v a="$1" -v b="$2" '
        BEGIN {
            split(a, av, ".")
            split(b, bv, ".")
            for (i = 1; i <= 3; i++) {
                x = av[i] + 0
                y = bv[i] + 0
                if (x < y) { print -1; exit }
                if (x > y) { print 1; exit }
            }
            print 0
        }'
}

# _awsemu_latest_version — prints the highest release in versions.json, or
# nothing when the list can't be read (the caller then installs LTS/latest/).
_awsemu_latest_version() {
    local tmp_dir latest=""
    tmp_dir="$(mktemp -d)" || return 0
    if _download_file_robust "${_AWSEMU_BASE_URL}/versions.json" "${tmp_dir}/versions.json" >/dev/null 2>&1; then
        latest="$(_awsemu_versions_from_json < "${tmp_dir}/versions.json" | _awsemu_version_highest)"
    fi
    rm -rf "${tmp_dir}"
    if [[ -z "${latest}" ]]; then
        log_warn "AWS Emulator: couldn't read the version list; installing LTS/latest"
        return 0
    fi
    printf '%s\n' "${latest}"
}

# _awsemu_fetch_verified_package <url> <dest_dir>
# Downloads <url> and <url>.sig into <dest_dir>, checks the signature with
# _awsemu_verify, and prints the local package path. On any failure both
# files are removed. Returns 2 when a download failed and 1 when the
# signature check failed, so a caller can tell "not there" from "not signed".
_awsemu_fetch_verified_package() {
    local url="$1" dest_dir="$2" file sig
    file="${dest_dir}/${url##*/}"
    sig="${file}.sig"
    log_info "Downloading ${url##*/}..."
    if ! _download_file_robust "${url}" "${file}" || ! _download_file_robust "${url}.sig" "${sig}"; then
        rm -f "${file}" "${sig}"
        return 2
    fi
    if ! _awsemu_verify "${file}" "${sig}"; then
        log_error "AWS Emulator: signature verification failed for ${url##*/} — refusing to install it"
        rm -f "${file}" "${sig}"
        return 1
    fi
    printf '%s\n' "${file}"
}

# _awsemu_fetch_package <rpm|deb> <version|""> <dest_dir>
# The versioned package when a version is known; when that can't be
# downloaded (a package release other than -1), LTS/latest/ once, with a
# warning. A failed signature check is never retried.
_awsemu_fetch_package() {
    local kind="$1" version="$2" dest_dir="$3" url pkg rc
    if [[ -n "${version}" ]]; then
        url="$(_awsemu_asset "${kind}" "${version}")" || return 1
        pkg="$(_awsemu_fetch_verified_package "${url}" "${dest_dir}")"
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            printf '%s\n' "${pkg}"
            return 0
        fi
        [[ ${rc} -ne 2 ]] && return 1
        log_warn "AWS Emulator: couldn't download ${url##*/}; trying LTS/latest"
    fi
    url="$(_awsemu_asset "${kind}" "")" || return 1
    pkg="$(_awsemu_fetch_verified_package "${url}" "${dest_dir}")" || return 1
    printf '%s\n' "${pkg}"
}

# _awsemu_installed_version — the version of the aws-emulator on PATH.
_awsemu_installed_version() {
    aws-emulator -v 2>/dev/null | _awsemu_parse_version
}

# ── Package route ─────────────────────────────────────────────────────────────
# _awsemu_install_package <latest>
_awsemu_install_package() {
    local latest="$1" kind pm tool elevation_cmd tmp_dir pkg have cmp gnupg_pkg
    local use_container="set WORKBENCH_AWS_EMULATOR_ROUTE=container in ~/.config/workbench/local/settings.sh to build an image instead"

    if [[ "${WORKBENCH_OS:-}" != "Linux" ]]; then
        log_error "AWS Emulator: AWS's packages are for Linux; this host is ${WORKBENCH_OS:-unknown}. ${use_container}"
        return 1
    fi
    case "${WORKBENCH_DISTRO:-unknown}" in
        rhel)
            kind="rpm"
            gnupg_pkg="gnupg2"
            if command -v dnf &>/dev/null; then
                pm="dnf"
            elif command -v yum &>/dev/null; then
                pm="yum"
            else
                log_error "AWS Emulator: neither dnf nor yum found"
                return 1
            fi
            ;;
        debian)
            kind="deb"
            gnupg_pkg="gnupg"
            pm="apt-get"
            ;;
        *)
            log_error "AWS Emulator: AWS documents packages for dnf/yum and apt hosts only; this host's distribution family is '${WORKBENCH_DISTRO:-unknown}'. ${use_container}"
            return 1
            ;;
    esac
    if [[ -e "${_AWSEMU_OSTREE_MARKER}" ]]; then
        log_error "AWS Emulator: this is an rpm-ostree host, which can't install a package this way. ${use_container}"
        return 1
    fi
    for tool in curl gpg gpgv; do
        if ! command -v "${tool}" &>/dev/null; then
            case "${tool}" in
                curl) log_error "AWS Emulator: curl is required (install the curl package)" ;;
                *)    log_error "AWS Emulator: ${tool} is required to verify the package (install the ${gnupg_pkg} package)" ;;
            esac
            return 1
        fi
    done

    if [[ -n "$(_awsemu_bin_path aws-emulator)" ]]; then
        have="$(_awsemu_installed_version)"
        if [[ -n "${latest}" && -n "${have}" ]]; then
            cmp="$(_awsemu_version_cmp "${have}" "${latest}")"
            case "${cmp}" in
                0)
                    log_info "AWS Emulator ${have} is the latest LTS release"
                    return 0
                    ;;
                1)
                    log_warn "AWS Emulator ${have} is newer than the latest LTS release in the version list (${latest}); not changed"
                    return 0
                    ;;
            esac
        fi
    fi

    elevation_cmd="$(get-elevation-command)" || return 1
    tmp_dir="$(mktemp -d)" || return 1
    # apt downloads as an unprivileged user and warns about a directory it
    # can't read. The files are public packages, and only this user can write
    # in the directory.
    chmod 755 "${tmp_dir}"

    pkg="$(_awsemu_fetch_package "${kind}" "${latest}" "${tmp_dir}")" || { rm -rf "${tmp_dir}"; return 1; }

    # Installed from the verified local file, by absolute path (apt reads a
    # bare name as a package name). Never `dnf install <url>`: that would
    # download a second copy that nothing here has checked.
    log_info "Installing ${pkg##*/} with ${pm}..."
    if ! ${elevation_cmd} "${pm}" install -y "${pkg}"; then
        log_error "AWS Emulator: ${pm} could not install the verified package"
        rm -rf "${tmp_dir}"
        return 1
    fi
    rm -rf "${tmp_dir}"

    log_info "AWS Emulator installed: $(aws-emulator -v 2>&1 | head -1)"
    if command -v pgrep &>/dev/null && pgrep -x aws-emulator >/dev/null 2>&1; then
        log_info "Running emulators keep the old version until you restart them"
    fi
    return 0
}

# ── Container route ───────────────────────────────────────────────────────────
# _awsemu_image_exists <engine> <image>
_awsemu_image_exists() {
    "$(_awsemu_engine_cmd "$1")" image inspect "$2" >/dev/null 2>&1
}

# _awsemu_image_build <engine> <image> <context-dir>
# Always pulls the base image, so each rebuild picks up Amazon Linux updates.
_awsemu_image_build() {
    local engine="$1" image="$2" ctx="$3"
    case "${engine}" in
        docker) docker build --pull -t "${image}" "${ctx}" ;;
        podman) podman build --pull=always -t "${image}" "${ctx}" ;;
        apple)  container build --pull -t "${image}" "${ctx}" ;;
    esac
}

# _awsemu_image_tag <engine> <source> <target>
_awsemu_image_tag() {
    case "$1" in
        apple) container image tag "$2" "$3" ;;
        *)     "$1" tag "$2" "$3" ;;
    esac
}

# _awsemu_image_remove <engine> <image>
_awsemu_image_remove() {
    case "$1" in
        apple) container image delete "$2" ;;
        *)     "$1" rmi "$2" ;;
    esac
}

# _awsemu_image_version <engine> <image> — the emulator version inside an image.
_awsemu_image_version() {
    "$(_awsemu_engine_cmd "$1")" run --rm "$2" -v 2>/dev/null | _awsemu_parse_version
}

# _awsemu_install_container <latest>
_awsemu_install_container() {
    local latest="$1" engine cmd tool old_version new_version ctx pkg gnupg_hint

    engine="$(_awsemu_engine)" || {
        log_error "AWS Emulator: no container engine found; install podman (wb tools install podman, from workbench-containers), Docker, or on Apple silicon Apple's container CLI"
        return 1
    }
    cmd="$(_awsemu_engine_cmd "${engine}")"
    if ! _awsemu_engine_usable "${engine}"; then
        log_error "AWS Emulator: ${engine} is installed but not answering — $(_awsemu_engine_start_hint "${engine}")"
        return 1
    fi
    if [[ "${engine}" == "apple" ]]; then
        case "${WORKBENCH_ARCH}" in
            arm64|aarch64) ;;
            *) log_error "AWS Emulator: Apple's container CLI runs only on Apple silicon"; return 1 ;;
        esac
    fi
    gnupg_hint="install the gnupg package"
    [[ "${WORKBENCH_OS:-}" == "Mac" ]] && gnupg_hint="brew install gnupg"
    for tool in curl gpg gpgv; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "AWS Emulator: ${tool} is required (${gnupg_hint})"
            return 1
        fi
    done

    if [[ -n "${latest}" ]] && _awsemu_image_exists "${engine}" "${_AWSEMU_IMAGE}:${latest}"; then
        log_info "AWS Emulator image ${_AWSEMU_IMAGE}:${latest} is the latest LTS release"
        return 0
    fi

    old_version=""
    if _awsemu_image_exists "${engine}" "${_AWSEMU_IMAGE}:latest"; then
        old_version="$(_awsemu_image_version "${engine}" "${_AWSEMU_IMAGE}:latest")"
    fi

    ctx="$(mktemp -d)" || return 1
    pkg="$(_awsemu_fetch_package rpm "${latest}" "${ctx}")" || { rm -rf "${ctx}"; return 1; }
    command mv "${pkg}" "${ctx}/aws-emulator.rpm" && rm -f "${pkg}.sig"

    # AWS's own Dockerfile, except that COPY of the file checked above
    # replaces ADD <url>, which would skip the signature check.
    command cat > "${ctx}/Dockerfile" <<'EOF'
# Built by workbench-cloud (wb tools install aws-emulator). The package
# was signature-checked on the host before it was copied in (D128).
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
LABEL io.github.gingergraham.workbench.module="cloud"
COPY aws-emulator.rpm /tmp/aws-emulator.rpm
RUN rpm -i /tmp/aws-emulator.rpm && rm /tmp/aws-emulator.rpm \
    && mkdir -p /home/emulator && chown 1000 /home/emulator
USER 1000
ENV HOME=/home/emulator EMULATOR_BIND_ADDRESS=0.0.0.0
ENTRYPOINT ["aws-emulator"]
EOF

    log_info "Building ${_AWSEMU_IMAGE}:latest with ${engine}..."
    if ! _awsemu_image_build "${engine}" "${_AWSEMU_IMAGE}:latest" "${ctx}"; then
        log_error "AWS Emulator: ${engine} could not build the image"
        rm -rf "${ctx}"
        return 1
    fi
    rm -rf "${ctx}"

    new_version="$(_awsemu_image_version "${engine}" "${_AWSEMU_IMAGE}:latest")"
    if [[ -z "${new_version}" ]]; then
        log_warn "AWS Emulator: built the image but couldn't read its version; it has only the :latest tag"
        return 0
    fi
    _awsemu_image_tag "${engine}" "${_AWSEMU_IMAGE}:latest" "${_AWSEMU_IMAGE}:${new_version}" \
        || log_warn "AWS Emulator: couldn't add the ${new_version} tag"

    if [[ -n "${old_version}" && "${old_version}" != "${new_version}" ]]; then
        if ! _awsemu_image_remove "${engine}" "${_AWSEMU_IMAGE}:${old_version}" >/dev/null 2>&1; then
            log_info "Kept ${_AWSEMU_IMAGE}:${old_version}: a container still uses it"
        fi
    fi
    log_info "AWS Emulator image built: ${_AWSEMU_IMAGE}:latest (${new_version}), with ${engine}"
    return 0
}

# ── Entry points ──────────────────────────────────────────────────────────────
install-aws-emulator() {
    local route latest rc
    log_info "Installing or updating the AWS Emulator..."
    route="$(_awsemu_route)" || return 1
    latest="$(_awsemu_latest_version)"
    case "${route}" in
        package)   _awsemu_install_package "${latest}" ;;
        container) _awsemu_install_container "${latest}" ;;
    esac
    rc=$?
    [[ ${rc} -ne 0 ]] && log_error "AWS Emulator install failed"
    return "${rc}"
}

# 0 installed, 1 not installed, 2 don't know (the engine isn't answering,
# so the image can't be checked — wb tools upgrade then leaves it alone).
installed-aws-emulator() {
    local route engine cmd
    route="$(_awsemu_route 2>/dev/null)" || return 2
    if [[ "${route}" == "package" ]]; then
        [[ -n "$(_awsemu_bin_path aws-emulator)" ]]
        return $?
    fi
    engine="$(_awsemu_engine 2>/dev/null)" || return 1
    cmd="$(_awsemu_engine_cmd "${engine}")"
    "${cmd}" image inspect "${_AWSEMU_IMAGE}:latest" >/dev/null 2>&1 && return 0
    _awsemu_engine_usable "${engine}" || return 2
    return 1
}
