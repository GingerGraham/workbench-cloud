#!/usr/bin/env bash
# tests/check-aws-bin-dir.sh — workbench-cloud
# Guards the --bin-dir safety check in shell/installers.sh.
#
# _aws-install-linux updates an existing `aws` in place by running the AWS
# installer as root with --bin-dir set to the directory that `aws` lives in.
# A directory the user can write to would let the user redirect that root
# write, so _aws_safe_bin_dir must refuse it, and _aws-install-linux must
# refuse before downloading or elevating anything.
#
# Linux only (the code under test uses GNU stat). Directories are made with
# mktemp, so the checks behave the same whether this runs as root or not:
# a directory this user creates is either owned by a non-root user or, as
# root, made world-writable on purpose.
set -uo pipefail

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: Linux only — the code under test uses GNU stat"
    exit 0
fi

# Core API stand-ins. They write to stderr, because _aws_safe_bin_dir is run
# inside $(...) and only stdout is captured there.
# shellcheck disable=SC2329  # called by the sourced installers.sh
log_error() { echo "ERROR: $*" >&2; }
# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info()  { echo "INFO: $*" >&2; }
# shellcheck disable=SC2329  # called by the sourced installers.sh
log_warn()  { echo "WARN: $*" >&2; }

# shellcheck source=/dev/null
source "${INSTALLERS}"

WORK_DIR="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK_DIR}"' EXIT

# ── _aws_safe_bin_dir ─────────────────────────────────────────────────────────

# Safe: /usr/bin and every parent are root-owned and not writable by others
# on any Linux system.
out="$(_aws_safe_bin_dir /usr/bin/aws 2>&1)"; rc=$?
resolved_usr_bin="$(builtin cd -P /usr/bin && pwd -P)"
if [[ ${rc} -eq 0 && "${out}" == "${resolved_usr_bin}" ]]; then
    ok "root-controlled dir (/usr/bin) is accepted and printed resolved"
else
    fail "/usr/bin/aws should be accepted, got rc=${rc} output='${out}'"
fi

# World-writable dir: rejected, whoever owns it.
world_dir="${WORK_DIR}/world"
mkdir "${world_dir}" && chmod 777 "${world_dir}"
out="$(_aws_safe_bin_dir "${world_dir}/aws" 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && "${out}" == *"refusing to run the installer as root"* ]]; then
    ok "world-writable dir is rejected with an explanation"
else
    fail "world-writable dir should be rejected, got rc=${rc} output='${out}'"
fi

# Nothing may be printed on stdout when rejecting: the caller uses stdout as
# the --bin-dir value.
stdout_only="$(_aws_safe_bin_dir "${world_dir}/aws" 2>/dev/null)"
if [[ -z "${stdout_only}" ]]; then
    ok "a rejection prints nothing on stdout"
else
    fail "a rejection must not print on stdout, got '${stdout_only}'"
fi

# A dir this user owns (0755, so only the owner can write): rejected unless
# this user is root, in which case it is root-owned and fine on its own.
own_dir="${WORK_DIR}/own"
mkdir "${own_dir}" && chmod 755 "${own_dir}"
out="$(_aws_safe_bin_dir "${own_dir}/aws" 2>&1)"; rc=$?
if [[ "$(id -u)" != "0" ]]; then
    # Non-root: own_dir is owned by this user; WORK_DIR's other parents
    # don't matter, the first hop already fails.
    if [[ ${rc} -ne 0 && "${out}" == *"not root"* ]]; then
        ok "dir owned by a non-root user (~/.local/bin case) is rejected"
    else
        fail "non-root-owned dir should be rejected as 'not root', got rc=${rc} output='${out}'"
    fi
fi

# A world-writable parent makes an otherwise tidy child unsafe: the parent
# could be used to swap the child out.
parent_dir="${WORK_DIR}/parent"
mkdir -p "${parent_dir}/child" && chmod 777 "${parent_dir}" && chmod 755 "${parent_dir}/child"
out="$(_aws_safe_bin_dir "${parent_dir}/child/aws" 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]]; then
    ok "dir under a writable parent is rejected"
else
    fail "dir under a world-writable parent should be rejected, got output='${out}'"
fi

# A symlink to an unsafe dir is judged by where it points, not its own name.
ln -s "${world_dir}" "${WORK_DIR}/link"
out="$(_aws_safe_bin_dir "${WORK_DIR}/link/aws" 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]]; then
    ok "symlink to an unsafe dir is rejected"
else
    fail "symlink to an unsafe dir should be rejected, got output='${out}'"
fi

# Not a file path (a shell function or alias prints just its name).
out="$(_aws_safe_bin_dir aws 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && "${out}" == *"not a file path"* ]]; then
    ok "a non-path 'aws' (function/alias) is rejected"
else
    fail "non-path aws should be rejected, got rc=${rc} output='${out}'"
fi

# A dir that doesn't exist.
out="$(_aws_safe_bin_dir "${WORK_DIR}/missing/aws" 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]]; then
    ok "nonexistent dir is rejected"
else
    fail "nonexistent dir should be rejected, got output='${out}'"
fi

# Group-write rules need a root-owned dir with a group the user isn't in,
# which only root can create.
if [[ "$(id -u)" == "0" ]]; then
    foreign_gid=65534
    case " $(id -G) " in
        *" ${foreign_gid} "*) foreign_gid="" ;;
    esac
    # The accepted case needs a whole chain that is safe, which /tmp (sticky,
    # world-writable) never is, so build it under root's home instead.
    HOME_WORK_DIR="$(mktemp -d "${HOME}/.check-aws-bin-dir.XXXXXX" 2>/dev/null)" || HOME_WORK_DIR=""
    if [[ -n "${HOME_WORK_DIR}" ]]; then
        trap 'rm -rf "${WORK_DIR}" "${HOME_WORK_DIR}"' EXIT
        chmod 755 "${HOME_WORK_DIR}"
    fi
    if [[ -n "${foreign_gid}" && -n "${HOME_WORK_DIR}" ]] \
        && _aws_safe_bin_dir "${HOME_WORK_DIR}/aws" >/dev/null 2>&1; then
        group_dir="${HOME_WORK_DIR}/group-foreign"
        mkdir "${group_dir}" && chown "0:${foreign_gid}" "${group_dir}" && chmod 775 "${group_dir}"
        out="$(_aws_safe_bin_dir "${group_dir}/aws" 2>&1)"; rc=$?
        if [[ ${rc} -eq 0 ]]; then
            ok "root-owned group-writable dir is accepted when the user is not in the group"
        else
            fail "group-writable dir for a group the user is not in should be accepted, got output='${out}'"
        fi
    else
        echo "SKIP: no root-controlled scratch dir under HOME — skipping the accepted group-write check"
    fi

    member_dir="${WORK_DIR}/group-member"
    mkdir "${member_dir}" && chown 0:0 "${member_dir}" && chmod 775 "${member_dir}"
    out="$(_aws_safe_bin_dir "${member_dir}/aws" 2>&1)"; rc=$?
    if [[ ${rc} -ne 0 && "${out}" == *"member of"* ]]; then
        ok "group-writable dir is rejected when the user is in the group"
    else
        fail "group-writable dir for the user's own group should be rejected, got rc=${rc} output='${out}'"
    fi
else
    echo "SKIP: group-write checks need root to create a root-owned dir with a foreign group"
fi

# ── _aws-install-linux fails fast, before download or elevation ──────────────

STUB_BIN="${WORK_DIR}/stub-bin"
mkdir "${STUB_BIN}" && chmod 777 "${STUB_BIN}"
for stub in aws curl unzip; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_BIN}/${stub}"
    chmod 755 "${STUB_BIN}/${stub}"
done

TOUCHED="${WORK_DIR}/touched"
# shellcheck disable=SC2329  # called by the sourced installers.sh
_download_file_robust()   { echo "download $*" >> "${TOUCHED}"; return 1; }
# shellcheck disable=SC2329  # called by the sourced installers.sh
get-elevation-command()   { echo "elevation" >> "${TOUCHED}"; echo "true"; }

# shellcheck disable=SC2034  # read by the sourced installers.sh
WORKBENCH_ARCH="x86_64"
out="$(PATH="${STUB_BIN}:${PATH}" _aws-install-linux 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && "${out}" == *"refusing to run the installer as root"* ]]; then
    ok "_aws-install-linux refuses when the existing aws is in a writable dir"
else
    fail "_aws-install-linux should refuse, got rc=${rc} output='${out}'"
fi
if [[ ! -e "${TOUCHED}" ]]; then
    ok "nothing was downloaded and nothing was elevated before the refusal"
else
    fail "download/elevation happened before the safety check: $(cat "${TOUCHED}")"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All checks passed."
    exit 0
else
    echo "${FAILED} check(s) failed."
    exit 1
fi
