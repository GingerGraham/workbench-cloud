#!/usr/bin/env bash
# tests/check-aws-emulator.sh — workbench-cloud
# Plain bash, numbered OK:/FAIL: checks, matching tests/check-cloud-shell.sh
# (no framework). No network, no root: every external command is a stub on a
# private PATH that records its argument list. The cases for
# shell/aws-emulator.sh run in bash and in zsh (SKIP when zsh is missing);
# the cases for shell/installers-aws-emulator.sh run in bash only, as
# `wb tools` does. D128.
# The scripts handed to run_in are single-quoted on purpose: they are
# expanded by the child shell, not here.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHELL_FILE="${REPO_ROOT}/shell/aws-emulator.sh"
INSTALLER_FILE="${REPO_ROOT}/shell/installers-aws-emulator.sh"
FIXTURES="${SCRIPT_DIR}/fixtures"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

expect_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "${got}" == "${want}" ]]; then ok "${name}"; else fail "${name}: got '${got}', want '${want}'"; fi
}
expect_has() {
    local name="$1" hay="$2" needle="$3"
    if [[ "${hay}" == *"${needle}"* ]]; then ok "${name}"; else fail "${name}: '${needle}' not in: ${hay}"; fi
}
expect_lacks() {
    local name="$1" hay="$2" needle="$3"
    if [[ "${hay}" != *"${needle}"* ]]; then ok "${name}"; else fail "${name}: '${needle}' unexpectedly in: ${hay}"; fi
}

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

STUBS="${WORK}/stubs"
BASE="${WORK}/base"
HOME_DIR="${WORK}/home"
STATE_HOME="${WORK}/state"
CALLS="${WORK}/calls"
PRELUDE="${WORK}/prelude.sh"
mkdir -p "${STUBS}" "${BASE}" "${HOME_DIR}" "${STATE_HOME}"

# The only real tools the code under test may find. Anything else (docker,
# podman, ss, ip, curl, gpg, ...) exists only when a case stubs it.
for tool in awk sed grep sort find cat tr head tail mkdir rm mv cp id ps kill sleep mktemp \
            dirname basename chmod wc env uname cut ls touch tee sh date nohup xargs expr true false; do
    # The system copy, not whatever wrapper this shell's PATH finds first.
    real=""
    for dir in /usr/bin /bin; do
        [[ -x "${dir}/${tool}" && ! -d "${dir}/${tool}" ]] && { real="${dir}/${tool}"; break; }
    done
    [[ -z "${real}" ]] && real="$(command -v "${tool}" 2>/dev/null)"
    [[ -n "${real}" && "${real}" == /* ]] && ln -s "${real}" "${BASE}/${tool}"
done

# mkstub <name> <body> — a stub that records "<name> arg|arg|" in ${CALLS},
# then runs <body>.
mkstub() {
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s " "%s" >> "%s"; printf "%%s|" "$@" >> "%s"; echo >> "%s"\n' "$1" "${CALLS}" "${CALLS}" "${CALLS}"
        printf '%s\n' "$2"
    } > "${STUBS}/$1"
    chmod +x "${STUBS}/$1"
}
rmstub() { rm -f "${STUBS}/$1"; }

# mkengine <podman|docker|container> — a stub container engine driven by
# files in ${WORK}: images (one reference per line), img-version,
# next-version, engine-down, docker-secopts.
mkengine() {
    local name="$1" version_line
    case "${name}" in
        docker) version_line='echo "Docker version 27.0.1, build abc"' ;;
        podman) version_line='echo "podman version 5.0.0"' ;;
        *)      version_line='echo "container CLI version 0.5.0"' ;;
    esac
    mkstub "${name}" "
W='${WORK}'
case \"\$1\" in
    --version) ${version_line} ;;
    info)
        [ -f \"\$W/engine-down\" ] && exit 1
        case \"\$*\" in *--format*) cat \"\$W/docker-secopts\" 2>/dev/null ;; esac
        exit 0 ;;
    system) [ -f \"\$W/engine-down\" ] && exit 1; exit 0 ;;
    image)
        case \"\$2\" in
            inspect) grep -qx \"\$3\" \"\$W/images\" 2>/dev/null; exit \$? ;;
            tag)     echo \"\$4\" >> \"\$W/images\" ;;
            delete)  grep -vx \"\$3\" \"\$W/images\" > \"\$W/images.new\"; mv \"\$W/images.new\" \"\$W/images\" ;;
        esac ;;
    build)
        for last; do :; done
        cp \"\$last/Dockerfile\" \"\$W/captured.Dockerfile\"
        ls \"\$last\" > \"\$W/ctxfiles\"
        ref=; prev=
        for a in \"\$@\"; do [ \"\$prev\" = -t ] && ref=\$a; prev=\$a; done
        echo \"\$ref\" >> \"\$W/images\"
        cp \"\$W/next-version\" \"\$W/img-version\" ;;
    run)
        for last; do :; done
        if [ \"\$last\" = -v ]; then
            echo \"Version: \$(cat \"\$W/img-version\")\"; echo 'Release date: 2026.11.24'; echo 'Commit: abc'
        fi ;;
    tag)  echo \"\$3\" >> \"\$W/images\" ;;
    rmi)  grep -vx \"\$2\" \"\$W/images\" > \"\$W/images.new\"; mv \"\$W/images.new\" \"\$W/images\" ;;
esac
exit 0"
}

# Common stub hosts. Wipes everything a previous case left behind.
reset_world() {
    rm -rf "${STUBS}" "${HOME_DIR}" "${STATE_HOME}"
    mkdir -p "${STUBS}" "${HOME_DIR}" "${STATE_HOME}"
    : > "${CALLS}"
    : > "${WORK}/images"
    rm -f "${WORK}/engine-down" "${WORK}/docker-secopts" "${WORK}/no-versions" "${WORK}/verify-fail" \
          "${WORK}/answers" "${WORK}/ansn" "${WORK}/captured.Dockerfile" "${WORK}/ctxfiles" "${WORK}/ostree-marker" \
          "${WORK}/curl-fail"
    echo "1.0.598" > "${WORK}/next-version"
    echo "1.0.598" > "${WORK}/img-version"
    echo "1.0.598" > "${WORK}/installed-version"
    # The emulator's own stub: reports ${WORK}/installed-version.
    mkstub aws-emulator "case \"\$1\" in -v) echo \"Version: \$(cat '${WORK}/installed-version')\"; echo 'Release date: 2026.11.24'; echo 'Commit: abc' ;; esac; exit 0"
}

cat > "${PRELUDE}" <<'EOF'
log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
_wb_alias_availability() { printf '%s|' "$@" > "${WORK}/availability"; }
get-elevation-command() { echo sudo; }
# A fake download: versions.json from the fixture, anything else a dummy
# file. DL_FAIL is a glob of URLs that fail.
_download_file_robust() {
    printf 'download %s\n' "$1" >> "${WORK}/calls"
    case "$1" in
        ${DL_FAIL:-__none__}) return 1 ;;
        */versions.json)
            [ -f "${WORK}/no-versions" ] && return 1
            cp "${FIXTURES}/aws-emulator-versions.json" "$2" ;;
        *) printf 'stub:%s\n' "$1" > "$2" ;;
    esac
}
EOF

# run_in <shell> [VAR=value ...] -- <script>
# Runs <script> in a clean shell that has sourced the prelude and the file in
# SRC (the shell file by default). Output is stdout and stderr together.
run_in() {
    local shell_name="$1" script src="${SHELL_FILE}"
    local pre=()
    shift
    while [[ "$1" != "--" ]]; do pre+=("$1"); shift; done
    shift
    script="$1"
    for kv in ${pre[@]+"${pre[@]}"}; do
        [[ "${kv}" == SRC=* ]] && src="${kv#SRC=}"
    done
    env -i PATH="${STUBS}:${BASE}" HOME="${HOME_DIR}" XDG_STATE_HOME="${STATE_HOME}" \
        WORK="${WORK}" FIXTURES="${FIXTURES}" _AWSEMU_OSTREE_MARKER="${WORK}/ostree-marker" \
        ${pre[@]+"${pre[@]}"} \
        "$(command -v "${shell_name}")" -c ". '${PRELUDE}'; . '${src}'; ${script}" 2>&1
}

# The shell-file cases run once per shell that is installed.
SHELLS=""
for candidate in bash zsh; do
    if command -v "${candidate}" &>/dev/null; then
        SHELLS="${SHELLS} ${candidate}"
    else
        echo "SKIP: ${candidate} not installed — shell/aws-emulator.sh not checked in ${candidate}"
    fi
done

# ── 1. the shared blocks are identical ───────────────────────────────────────
extract_shared() {
    sed -n '/^# ── shared with shell\/installers-aws-emulator.sh/,/^# ── end shared/p' "$1"
}
shared_a="$(extract_shared "${SHELL_FILE}")"
shared_b="$(extract_shared "${INSTALLER_FILE}")"
if [[ -n "${shared_a}" && "${shared_a}" == "${shared_b}" ]]; then
    ok "the shared block is identical in shell/aws-emulator.sh and shell/installers-aws-emulator.sh"
else
    fail "the shared block differs between shell/aws-emulator.sh and shell/installers-aws-emulator.sh (or is missing)"
fi

# ── 2. _awsemu_route ─────────────────────────────────────────────────────────
route_of() {
    # route_of <shell> <os> <distro> [extra VAR=value ...]
    local sh="$1" os="$2" distro="$3"
    shift 3
    reset_world
    run_in "${sh}" "WORKBENCH_OS=${os}" "WORKBENCH_DISTRO=${distro}" ${1+"$@"} -- '_awsemu_route'
}
for sh in ${SHELLS}; do
    expect_eq "${sh}: route: Linux rhel → package"     "$(route_of "${sh}" Linux rhel)"    "package"
    expect_eq "${sh}: route: Linux debian → package"   "$(route_of "${sh}" Linux debian)"  "package"
    expect_eq "${sh}: route: Linux arch → container"   "$(route_of "${sh}" Linux arch)"    "container"
    expect_eq "${sh}: route: Linux suse → container"   "$(route_of "${sh}" Linux suse)"    "container"
    expect_eq "${sh}: route: Linux unknown → container" "$(route_of "${sh}" Linux unknown)" "container"
    expect_eq "${sh}: route: Mac → container"          "$(route_of "${sh}" Mac "")"        "container"
    reset_world; : > "${WORK}/ostree-marker"
    expect_eq "${sh}: route: rhel with the rpm-ostree marker → container" \
        "$(run_in "${sh}" WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel -- '_awsemu_route')" "container"
    expect_eq "${sh}: route: override package on Mac" \
        "$(route_of "${sh}" Mac "" WORKBENCH_AWS_EMULATOR_ROUTE=package)" "package"
    expect_eq "${sh}: route: override container on rhel" \
        "$(route_of "${sh}" Linux rhel WORKBENCH_AWS_EMULATOR_ROUTE=container)" "container"
    out="$(route_of "${sh}" Linux rhel WORKBENCH_AWS_EMULATOR_ROUTE=bogus)"
    expect_has "${sh}: route: an invalid override is an error" "${out}" "[ERROR] aws-emulator: WORKBENCH_AWS_EMULATOR_ROUTE must be auto, package or container (got 'bogus')"
done

# ── 3. _awsemu_engine ────────────────────────────────────────────────────────
engine_of() {
    # engine_of <shell> [VAR=value ...] — prints "<engine>" or "none (<rc>)"
    local sh="$1" out rc
    shift
    out="$(run_in "${sh}" WORKBENCH_OS=Linux ${1+"$@"} -- '_awsemu_engine; echo "rc=$?"')"
    rc="${out##*rc=}"
    out="${out%rc=*}"
    out="$(printf '%s' "${out}" | tr -d '\n')"
    if [[ "${rc}" == "0" ]]; then echo "${out}"; else echo "none${out:+ ${out}}"; fi
}
for sh in ${SHELLS}; do
    reset_world
    expect_eq "${sh}: engine: none installed → fails" "$(engine_of "${sh}")" "none"
    mkengine docker
    expect_eq "${sh}: engine: only the real Docker → docker" "$(engine_of "${sh}")" "docker"
    mkengine podman
    expect_eq "${sh}: engine: podman wins over docker" "$(engine_of "${sh}")" "podman"
    reset_world; mkengine podman
    mkstub docker 'echo "podman version 5.0.0"'        # the podman-docker shim
    rmstub podman
    expect_eq "${sh}: engine: the podman-docker shim doesn't count as Docker" "$(engine_of "${sh}")" "none"
    reset_world; mkengine container
    expect_eq "${sh}: engine: Apple's container is ignored on Linux" "$(engine_of "${sh}")" "none"
    out="$(run_in "${sh}" WORKBENCH_OS=Mac -- '_awsemu_engine')"
    expect_eq "${sh}: engine: Apple's container is used on Mac" "${out}" "apple"
    reset_world; mkengine docker
    expect_eq "${sh}: engine: override names the engine without checking it" \
        "$(engine_of "${sh}" WORKBENCH_AWS_EMULATOR_ENGINE=podman)" "podman"
    out="$(engine_of "${sh}" WORKBENCH_AWS_EMULATOR_ENGINE=lxc)"
    expect_has "${sh}: engine: an invalid override is an error" "${out}" "WORKBENCH_AWS_EMULATOR_ENGINE must be podman, docker or apple (got 'lxc')"
done

# ── 4. _awsemu_asset ─────────────────────────────────────────────────────────
asset() {
    # asset <kind> <version> <arch>
    reset_world
    run_in bash "WORKBENCH_ARCH=$3" SRC="${INSTALLER_FILE}" -- "_awsemu_asset '$1' '$2'"
}
B="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS"
expect_eq "asset: rpm x86_64 latest"   "$(asset rpm "" x86_64)"  "${B}/latest/aws-emulator-x86_64.rpm"
expect_eq "asset: rpm amd64 latest"    "$(asset rpm "" amd64)"   "${B}/latest/aws-emulator-x86_64.rpm"
expect_eq "asset: rpm aarch64 latest"  "$(asset rpm "" aarch64)" "${B}/latest/aws-emulator-aarch64.rpm"
expect_eq "asset: rpm arm64 latest"    "$(asset rpm "" arm64)"   "${B}/latest/aws-emulator-aarch64.rpm"
expect_eq "asset: deb x86_64 latest"   "$(asset deb "" x86_64)"  "${B}/latest/aws-emulator_amd64.deb"
expect_eq "asset: deb aarch64 latest"  "$(asset deb "" aarch64)" "${B}/latest/aws-emulator_arm64.deb"
expect_eq "asset: rpm x86_64 versioned"  "$(asset rpm 1.0.598 x86_64)"  "${B}/aws-emulator-1.0.598-1-x86_64.rpm"
expect_eq "asset: rpm arm64 versioned"   "$(asset rpm 1.0.598 arm64)"   "${B}/aws-emulator-1.0.598-1-aarch64.rpm"
expect_eq "asset: deb amd64 versioned"   "$(asset deb 1.0.598 amd64)"   "${B}/aws-emulator_1.0.598-1_amd64.deb"
expect_eq "asset: deb aarch64 versioned" "$(asset deb 1.0.598 aarch64)" "${B}/aws-emulator_1.0.598-1_arm64.deb"
out="$(asset rpm "" riscv64)"
expect_has "asset: an unknown architecture fails" "${out}" "no rpm package for architecture riscv64"

# ── 5. versions ──────────────────────────────────────────────────────────────
vers="$(run_in bash SRC="${INSTALLER_FILE}" -- "_awsemu_versions_from_json < '${FIXTURES}/aws-emulator-versions.json'" | tr '\n' ' ')"
expect_eq "versions: the fixture lists 1.0.191, 1.0.266, 1.0.597 and 1.0.598 (release part dropped)" "${vers}" "1.0.191 1.0.266 1.0.597 1.0.598 "
expect_eq "versions: highest of the fixture" \
    "$(run_in bash SRC="${INSTALLER_FILE}" -- "_awsemu_versions_from_json < '${FIXTURES}/aws-emulator-versions.json' | _awsemu_version_highest")" "1.0.598"
expect_eq "versions: pretty-printed JSON, and other numbers in the file are ignored" \
    "$(printf '{\n "versions": [\n  {"productId": "x", "build": "9.9.9.9",\n   "version" : "3.4.5.1"}\n ]\n}\n' | run_in bash SRC="${INSTALLER_FILE}" -- '_awsemu_versions_from_json')" "3.4.5"
expect_eq "versions: highest of 1.2.3, 1.10.0, 1.9.9, bad, 1.10.0-rc1 is 1.10.0 (installer file)" \
    "$(run_in bash SRC="${INSTALLER_FILE}" -- "printf '1.2.3\n1.10.0\n1.9.9\nbad\n1.10.0-rc1\n' | _awsemu_version_highest")" "1.10.0"
expect_eq "versions: highest of nothing is nothing" \
    "$(run_in bash SRC="${INSTALLER_FILE}" -- "printf 'bad\n' | _awsemu_version_highest")" ""
for sh in ${SHELLS}; do
    expect_eq "${sh}: parse_version reads the real 'aws-emulator -v' output" \
        "$(run_in "${sh}" -- "_awsemu_parse_version < '${FIXTURES}/aws-emulator-version.txt'")" "1.0.598"
    expect_eq "${sh}: parse_version prefers the Version line" \
        "$(printf 'Release date: 2026.11.24 (9.9.9)\nVersion: 1.2.3\n' | run_in "${sh}" -- '_awsemu_parse_version')" "1.2.3"
    expect_eq "${sh}: parse_version falls back to the first X.Y.Z anywhere" \
        "$(run_in "${sh}" -- "printf 'aws-emulator 4.5.6 (commit abc)\n' | _awsemu_parse_version")" "4.5.6"
done
cmp_of() { run_in bash SRC="${INSTALLER_FILE}" -- "_awsemu_version_cmp '$1' '$2'"; }
expect_eq "version_cmp: equal"                "$(cmp_of 1.0.598 1.0.598)" "0"
expect_eq "version_cmp: lower"                "$(cmp_of 1.0.597 1.0.598)" "-1"
expect_eq "version_cmp: higher"               "$(cmp_of 1.1.0 1.0.598)"   "1"
expect_eq "version_cmp: multi-digit 9 < 10"   "$(cmp_of 1.0.9 1.0.10)"    "-1"
expect_eq "version_cmp: multi-digit 100 > 99" "$(cmp_of 1.0.100 1.0.99)"  "1"
expect_eq "version_cmp: major beats minor"    "$(cmp_of 2.0.0 1.99.99)"   "1"

# ── 6. installed-aws-emulator ────────────────────────────────────────────────
installed_rc() {
    # installed_rc [VAR=value ...] — the exit status of installed-aws-emulator
    local out
    out="$(run_in bash SRC="${INSTALLER_FILE}" "$@" -- 'installed-aws-emulator; echo "rc=$?"')"
    echo "${out##*rc=}"
}
reset_world
expect_eq "installed: package route, binary present → 0" \
    "$(installed_rc WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel)" "0"
rmstub aws-emulator
expect_eq "installed: package route, binary absent → 1" \
    "$(installed_rc WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel)" "1"
reset_world; mkengine podman; echo "workbench-aws-emulator:latest" > "${WORK}/images"
expect_eq "installed: container route, image present → 0" \
    "$(installed_rc WORKBENCH_OS=Mac WORKBENCH_AWS_EMULATOR_ROUTE=container)" "0"
: > "${WORK}/images"
expect_eq "installed: container route, image missing, engine answering → 1" \
    "$(installed_rc WORKBENCH_OS=Mac WORKBENCH_AWS_EMULATOR_ROUTE=container)" "1"
: > "${WORK}/engine-down"
expect_eq "installed: container route, image missing, engine down → 2 (don't know)" \
    "$(installed_rc WORKBENCH_OS=Mac WORKBENCH_AWS_EMULATOR_ROUTE=container)" "2"
reset_world
expect_eq "installed: container route, no engine at all → 1" \
    "$(installed_rc WORKBENCH_OS=Mac WORKBENCH_AWS_EMULATOR_ROUTE=container)" "1"
expect_eq "installed: an invalid route setting → 2 (don't know)" \
    "$(installed_rc WORKBENCH_AWS_EMULATOR_ROUTE=bogus)" "2"

# ── 7. package route ─────────────────────────────────────────────────────────
# install_pkg <distro> <arch> [VAR=value ...] — runs install-aws-emulator on a
# stubbed host; the package managers, sudo and the signature check are stubs.
install_pkg() {
    local distro="$1" arch="$2"
    shift 2
    run_in bash SRC="${INSTALLER_FILE}" WORKBENCH_OS=Linux "WORKBENCH_DISTRO=${distro}" "WORKBENCH_ARCH=${arch}" \
        "FIXTURES=${FIXTURES}" ${1+"$@"} -- '
        _awsemu_verify() { printf "verify %s %s\n" "$1" "$2" >> "${WORK}/calls"; [ ! -f "${WORK}/verify-fail" ]; }
        install-aws-emulator; echo "rc=$?"'
}
pkg_world() {
    reset_world
    mkstub sudo 'exec "$@"'
    mkstub curl 'exit 0'; mkstub gpg 'exit 0'; mkstub gpgv 'exit 0'
    mkstub dnf 'exit 0'
}

pkg_world; echo "1.0.598" > "${WORK}/installed-version"
out="$(install_pkg rhel x86_64)"; calls="$(cat "${CALLS}")"
expect_has   "package: installed == latest → says it is the latest LTS release" "${out}" "AWS Emulator 1.0.598 is the latest LTS release"
expect_lacks "package: installed == latest → no package download" "${calls}" "download https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/aws-emulator-"
expect_lacks "package: installed == latest → nothing installed" "${calls}" "install|"
expect_has   "package: installed == latest → exit status 0" "${out}" "rc=0"

pkg_world; echo "1.0.999" > "${WORK}/installed-version"
out="$(install_pkg rhel x86_64)"; calls="$(cat "${CALLS}")"
expect_has   "package: installed newer than latest → warns and leaves it" "${out}" "[WARN] AWS Emulator 1.0.999 is newer than the latest LTS release in the version list (1.0.598); not changed"
expect_lacks "package: installed newer → nothing installed" "${calls}" "install|"
expect_has   "package: installed newer → exit status 0" "${out}" "rc=0"

pkg_world; rmstub aws-emulator; mkstub dnf 'exit 0'
out="$(install_pkg rhel x86_64)"; calls="$(cat "${CALLS}")"
expect_has "package: fresh rhel install downloads the versioned rpm" "${calls}" "download ${B}/aws-emulator-1.0.598-1-x86_64.rpm"
expect_has "package: ... and its .sig" "${calls}" "download ${B}/aws-emulator-1.0.598-1-x86_64.rpm.sig"
if printf '%s\n' "${calls}" | grep -Eq '^dnf install\|-y\|/[^|]*/aws-emulator-1\.0\.598-1-x86_64\.rpm\|$'; then
    ok "package: dnf is given -y and an absolute local path (not a URL)"
else
    fail "package: dnf call wrong: $(printf '%s\n' "${calls}" | grep '^dnf' || echo none)"
fi
expect_has "package: the signature is checked before the install" "$(printf '%s\n' "${calls}" | grep -n 'verify\|^dnf' | tr '\n' ' ')" "verify"
verify_line="$(printf '%s\n' "${calls}" | grep -n '^verify' | head -1 | cut -d: -f1)"
dnf_line="$(printf '%s\n' "${calls}" | grep -n '^dnf' | head -1 | cut -d: -f1)"
if [[ -n "${verify_line}" && -n "${dnf_line}" && "${verify_line}" -lt "${dnf_line}" ]]; then
    ok "package: verify runs before dnf"
else
    fail "package: verify (line ${verify_line:-none}) did not run before dnf (line ${dnf_line:-none})"
fi
expect_lacks "package: no flag that skips the package manager's own signature check" "${calls}" "nogpgcheck"
expect_has   "package: fresh install exit status 0" "${out}" "rc=0"

pkg_world; rmstub aws-emulator; rmstub dnf; mkstub yum 'exit 0'
out="$(install_pkg rhel aarch64)"; calls="$(cat "${CALLS}")"
if printf '%s\n' "${calls}" | grep -Eq '^yum install\|-y\|/[^|]*/aws-emulator-1\.0\.598-1-aarch64\.rpm\|$'; then
    ok "package: yum is used when there is no dnf (aarch64 rpm)"
else
    fail "package: yum call wrong: ${calls}"
fi

pkg_world; rmstub aws-emulator; rmstub dnf; mkstub apt-get 'exit 0'
out="$(install_pkg debian x86_64)"; calls="$(cat "${CALLS}")"
if printf '%s\n' "${calls}" | grep -Eq '^apt-get install\|-y\|/[^|]*/aws-emulator_1\.0\.598-1_amd64\.deb\|$'; then
    ok "package: apt-get installs the absolute path of the amd64 deb on debian"
else
    fail "package: apt-get call wrong: ${calls}"
fi

pkg_world; rmstub aws-emulator; mkstub dnf 'exit 0'; : > "${WORK}/verify-fail"
out="$(install_pkg rhel x86_64)"; calls="$(cat "${CALLS}")"
expect_lacks "package: a failed signature check means nothing is installed" "${calls}" "dnf install"
expect_has   "package: a failed signature check is reported" "${out}" "signature verification failed"
expect_lacks "package: a failed signature check is not retried against latest/" "${calls}" "download ${B}/latest/aws-emulator-x86_64.rpm"
expect_lacks "package: a failed signature check exits 0 never" "${out}" "rc=0"

pkg_world; rmstub aws-emulator; mkstub dnf 'exit 0'
out="$(install_pkg rhel x86_64 "DL_FAIL=*1.0.598-1-x86_64.rpm")"; calls="$(cat "${CALLS}")"
expect_has "package: a versioned URL that can't be downloaded falls back to LTS/latest/" "${calls}" "download ${B}/latest/aws-emulator-x86_64.rpm"
expect_has "package: ... with a warning" "${out}" "[WARN] AWS Emulator: couldn't download aws-emulator-1.0.598-1-x86_64.rpm; trying LTS/latest"
expect_has "package: ... and still installs" "${calls}" "dnf install"

pkg_world; rmstub aws-emulator; mkstub dnf 'exit 0'; : > "${WORK}/no-versions"
out="$(install_pkg rhel x86_64)"; calls="$(cat "${CALLS}")"
expect_has "package: an unreadable version list warns" "${out}" "[WARN] AWS Emulator: couldn't read the version list; installing LTS/latest"
expect_has "package: ... and installs LTS/latest" "${calls}" "download ${B}/latest/aws-emulator-x86_64.rpm"

pkg_world; mkstub dnf 'exit 0'; echo "1.0.597" > "${WORK}/installed-version"; mkstub pgrep 'exit 0'
out="$(install_pkg rhel x86_64)"
expect_has "package: an older install is updated" "$(cat "${CALLS}")" "dnf install"
expect_has "package: a running emulator is told it keeps the old version" "${out}" "Running emulators keep the old version until you restart them"

pkg_world; mkstub dnf 'exit 0'
out="$(install_pkg suse x86_64 WORKBENCH_AWS_EMULATOR_ROUTE=package)"
expect_has "package: refused on suse, with the container setting" "${out}" "WORKBENCH_AWS_EMULATOR_ROUTE=container in ~/.config/workbench/local/settings.sh"
out="$(run_in bash SRC="${INSTALLER_FILE}" WORKBENCH_OS=Mac WORKBENCH_DISTRO=unknown WORKBENCH_ARCH=arm64 WORKBENCH_AWS_EMULATOR_ROUTE=package -- '_awsemu_install_package ""')"
expect_has "package: refused on macOS" "${out}" "AWS's packages are for Linux"
pkg_world; mkstub dnf 'exit 0'; : > "${WORK}/ostree-marker"
out="$(install_pkg rhel x86_64 WORKBENCH_AWS_EMULATOR_ROUTE=package)"
expect_has "package: refused on rpm-ostree, with the container setting" "${out}" "rpm-ostree host"
pkg_world; mkstub dnf 'exit 0'; rmstub gpgv
out="$(install_pkg rhel x86_64)"
expect_has "package: a missing gpgv names the package to install" "${out}" "gpgv is required to verify the package (install the gnupg2 package)"
pkg_world; rmstub dnf; mkstub apt-get 'exit 0'; rmstub gpg
out="$(install_pkg debian x86_64)"
expect_has "package: a missing gpg on debian names gnupg" "${out}" "gpg is required to verify the package (install the gnupg package)"

# ── 8. container route ───────────────────────────────────────────────────────
# install_ctr <os> <arch> [VAR=value ...]
install_ctr() {
    local os="$1" arch="$2"
    shift 2
    run_in bash SRC="${INSTALLER_FILE}" "WORKBENCH_OS=${os}" "WORKBENCH_DISTRO=arch" "WORKBENCH_ARCH=${arch}" \
        WORKBENCH_AWS_EMULATOR_ROUTE=container ${1+"$@"} -- '
        _awsemu_verify() { printf "verify %s %s\n" "$1" "$2" >> "${WORK}/calls"; [ ! -f "${WORK}/verify-fail" ]; }
        install-aws-emulator; echo "rc=$?"'
}
ctr_world() {
    reset_world
    mkstub curl 'exit 0'; mkstub gpg 'exit 0'; mkstub gpgv 'exit 0'
}

ctr_world; mkengine podman
out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"; df="$(cat "${WORK}/captured.Dockerfile" 2>/dev/null)"
expect_has   "container: podman build pulls the base image" "${calls}" "podman build|--pull=always|-t|workbench-aws-emulator:latest|"
expect_has   "container: the rpm is downloaded for the image" "${calls}" "download ${B}/aws-emulator-1.0.598-1-x86_64.rpm"
expect_has   "container: the rpm is verified on the host" "${calls}" "verify "
expect_has   "container: the Dockerfile COPYs the verified file" "${df}" "COPY aws-emulator.rpm /tmp/aws-emulator.rpm"
expect_lacks "container: the Dockerfile has no ADD" "$(printf '%s\n' "${df}" | grep -v '^#')" "ADD "
expect_has   "container: the Dockerfile uses AWS's base image" "${df}" "FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal"
expect_has   "container: the Dockerfile binds all addresses and runs as 1000" "${df}" "EMULATOR_BIND_ADDRESS=0.0.0.0"
expect_eq    "container: the build context holds the Dockerfile and the rpm, not the .sig" "$(tr '\n' ' ' < "${WORK}/ctxfiles")" "Dockerfile aws-emulator.rpm "
expect_has   "container: the image gets a version tag" "$(cat "${WORK}/images")" "workbench-aws-emulator:1.0.598"
expect_lacks "container: a first build removes no tag" "${calls}" "rmi|"
expect_has   "container: exit status 0" "${out}" "rc=0"

out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"
: > "${CALLS}"
out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"
expect_has   "container: an image already at the latest version is left alone" "${out}" "is the latest LTS release"
expect_lacks "container: ... with no build" "${calls}" "podman build"
expect_lacks "container: ... and no download" "${calls}" "download ${B}/aws-emulator-"

ctr_world; mkengine podman
printf 'workbench-aws-emulator:latest\nworkbench-aws-emulator:1.0.597\n' > "${WORK}/images"; echo "1.0.597" > "${WORK}/img-version"
out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"
expect_has "container: an update removes the old version tag" "${calls}" "podman rmi|workbench-aws-emulator:1.0.597|"
expect_has "container: ... and keeps the new ones" "$(cat "${WORK}/images")" "workbench-aws-emulator:1.0.598"

ctr_world; mkengine podman; : > "${WORK}/no-versions"
printf 'workbench-aws-emulator:latest\nworkbench-aws-emulator:1.0.598\n' > "${WORK}/images"
out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"
expect_has   "container: with no version list the image is rebuilt" "${calls}" "podman build"
expect_lacks "container: a rebuild at the same version removes no tag" "${calls}" "rmi|"

ctr_world; mkengine docker
out="$(install_ctr Linux aarch64)"; calls="$(cat "${CALLS}")"
expect_has "container: docker build uses --pull" "${calls}" "docker build|--pull|-t|workbench-aws-emulator:latest|"
expect_has "container: aarch64 downloads the aarch64 rpm" "${calls}" "download ${B}/aws-emulator-1.0.598-1-aarch64.rpm"
expect_has "container: docker tags the version" "${calls}" "docker tag|workbench-aws-emulator:latest|workbench-aws-emulator:1.0.598|"

ctr_world; mkengine container
printf 'workbench-aws-emulator:latest\nworkbench-aws-emulator:1.0.597\n' > "${WORK}/images"; echo "1.0.597" > "${WORK}/img-version"
out="$(install_ctr Mac arm64 WORKBENCH_AWS_EMULATOR_ENGINE=apple)"; calls="$(cat "${CALLS}")"
expect_has "container: apple build uses --pull" "${calls}" "container build|--pull|-t|workbench-aws-emulator:latest|"
expect_has "container: apple tags with 'image tag'" "${calls}" "container image|tag|workbench-aws-emulator:latest|workbench-aws-emulator:1.0.598|"
expect_has "container: apple removes the old tag with 'image delete'" "${calls}" "container image|delete|workbench-aws-emulator:1.0.597|"
ctr_world; mkengine container
out="$(install_ctr Mac x86_64 WORKBENCH_AWS_EMULATOR_ENGINE=apple)"
expect_has "container: apple is refused off Apple silicon" "${out}" "runs only on Apple silicon"

ctr_world; mkengine podman; : > "${WORK}/engine-down"
out="$(install_ctr Mac arm64)"; calls="$(cat "${CALLS}")"
expect_has   "container: an engine that isn't answering gets the start hint" "${out}" "podman is installed but not answering — podman machine start"
expect_lacks "container: ... and nothing is built" "${calls}" "podman build"
ctr_world
out="$(install_ctr Linux x86_64)"
expect_has "container: no engine at all says how to get one" "${out}" "install podman (wb tools install podman, from workbench-containers), Docker, or on Apple silicon Apple's container CLI"
ctr_world; mkengine podman; : > "${WORK}/verify-fail"
out="$(install_ctr Linux x86_64)"; calls="$(cat "${CALLS}")"
expect_lacks "container: a failed signature check builds nothing" "${calls}" "podman build"
ctr_world; mkengine podman; rmstub gpgv
out="$(install_ctr Mac arm64)"
expect_has "container: on macOS a missing gpgv says brew install gnupg" "${out}" "brew install gnupg"

# ── 9. ports ─────────────────────────────────────────────────────────────────
# ss_listen <port>... — a stub `ss` that reports these ports as listening.
ss_listen() {
    local lines="" p
    for p in "$@"; do lines="${lines}LISTEN 0 4096 0.0.0.0:${p} 0.0.0.0:*\n"; done
    mkstub ss "printf '${lines}'"
}
for sh in ${SHELLS}; do
    reset_world; ss_listen 9297 9298
    expect_eq "${sh}: pick_port skips 9297 and 9298 → 9299" "$(run_in "${sh}" -- '_awsemu_pick_port 9297')" "9299"
    reset_world; mkstub ss ': '
    expect_eq "${sh}: pick_port takes the base port when it is free" "$(run_in "${sh}" -- '_awsemu_pick_port 9297')" "9297"
    reset_world; ss_listen 9297; mkstub ss "printf 'LISTEN 0 4096 [::]:9297 [::]:*\n'"
    expect_eq "${sh}: pick_port counts a port used on another address (IPv6) as used" "$(run_in "${sh}" -- '_awsemu_pick_port 9297')" "9298"
    reset_world
    all=""; p=9297; while [[ ${p} -le 9396 ]]; do all="${all} ${p}"; p=$((p + 1)); done
    # shellcheck disable=SC2086 # one argument per port
    ss_listen ${all}
    out="$(run_in "${sh}" -- '_awsemu_pick_port 9297; echo "rc=$?"')"
    expect_has "${sh}: pick_port fails when the whole range is used" "${out}" "no free port from 9297 to 9396"
    expect_has "${sh}: ... with a non-zero status" "${out}" "rc=1"
    reset_world
    out="$(run_in "${sh}" -- '_awsemu_pick_port 9297')"
    expect_has "${sh}: pick_port without ss or lsof warns once ..." "${out}" "[WARN] aws-emulator: can't check ports (no ss or lsof) — trying 9297"
    expect_has "${sh}: ... and uses the base port" "${out}" "9297"
    reset_world; ss_listen 9297
    out="$(run_in "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package WORKBENCH_AWS_EMULATOR_BIND=127.0.0.1 -- 'aws-emulator-server --port 9297; echo "rc=$?"')"
    expect_has "${sh}: server: an explicit --port that is in use is refused" "${out}" "port 9297 is in use"
    expect_has "${sh}: ... with status 1" "${out}" "rc=1"
    out="$(run_in "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- 'aws-emulator-server --port 0; echo "rc=$?"')"
    expect_has "${sh}: server: --port 0 is refused" "${out}" "--port must be from 1024 to 65535 (got 0)"
    out="$(run_in "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- 'aws-emulator-server --port 80; echo "rc=$?"')"
    expect_has "${sh}: server: a privileged port is refused" "${out}" "--port must be from 1024 to 65535 (got 80)"
    out="$(run_in "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- 'aws-emulator-server --port abc; echo "rc=$?"')"
    expect_has "${sh}: server: a non-numeric port is refused" "${out}" "--port must be a number"
done

# ── 10. _awsemu_ipv4_list ────────────────────────────────────────────────────
IP_OUT='2: wlp1s0    inet 192.168.1.20/24 brd 192.168.1.255 scope global dynamic wlp1s0\       valid_lft 86000sec
3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever'
IFCONFIG_OUT='en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether aa:bb:cc:dd:ee:ff
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
	inet 10.8.0.2 --> 10.8.0.1 netmask 0xffffffff'
for sh in ${SHELLS}; do
    reset_world; mkstub ip "cat <<'EOF'
${IP_OUT}
EOF"
    expect_eq "${sh}: ipv4_list from ip: loopback first, then the rest in order" \
        "$(run_in "${sh}" -- '_awsemu_ipv4_list' | tr '\n' ',')" "127.0.0.1 lo,192.168.1.20 wlp1s0,172.17.0.1 docker0,"
    reset_world; mkstub ifconfig "cat <<'EOF'
${IFCONFIG_OUT}
EOF"
    expect_eq "${sh}: ipv4_list from ifconfig (macOS: lo0/en0): loopback first" \
        "$(run_in "${sh}" -- '_awsemu_ipv4_list' | tr '\n' ',')" "127.0.0.1 lo0,192.168.1.20 en0,10.8.0.2 utun0,"
    reset_world; mkstub ifconfig "printf 'eth0      Link encap:Ethernet\n          inet addr:10.0.0.5  Bcast:10.0.0.255  Mask:255.255.255.0\n'"
    expect_eq "${sh}: ipv4_list from net-tools ifconfig (inet addr:)" \
        "$(run_in "${sh}" -- '_awsemu_ipv4_list' | tr '\n' ',')" "10.0.0.5 eth0,"
done

# ── 11. _awsemu_choose_bind ──────────────────────────────────────────────────
# choose <shell> <tty yes|no> <answers> [VAR=value ...] -- <args> — runs
# _awsemu_choose_bind with a fixed address list, a stubbed tty and stubbed
# answers (one per line, "|"-separated here). Prints "<stdout>|rc=<n>".
IPLIST_STUB='_awsemu_ipv4_list() { printf "127.0.0.1 lo\n192.168.1.20 wlp1s0\n172.17.0.1 docker0\n"; }'
choose() {
    local sh="$1" tty="$2" answers="$3" out
    shift 3
    reset_world
    printf '%s\n' "${answers}" | tr '|' '\n' > "${WORK}/answers"
    out="$(run_in "${sh}" ${1+"$@"} -- "
        ${IPLIST_STUB}
        _awsemu_have_tty() { [ '${tty}' = yes ]; }
        _read_prompt() { _n=\$(cat \"\${WORK}/ansn\" 2>/dev/null || echo 0); _n=\$((_n + 1)); echo \"\${_n}\" > \"\${WORK}/ansn\"; _a=\$(sed -n \"\${_n}p\" \"\${WORK}/answers\"); eval \"\$2=\\\${_a}\"; }
        _awsemu_choose_bind \"\${CHOOSE_ARG:-}\" 2>\"\${WORK}/choose.err\"; echo \"rc=\$?\"")"
    printf '%s' "${out}" | tr '\n' '|'
    printf '|ERR:%s' "$(tr '\n' '~' < "${WORK}/choose.err" 2>/dev/null)"
}
for sh in ${SHELLS}; do
    out="$(choose "${sh}" no "")"
    expect_has "${sh}: choose_bind: no tty → 127.0.0.1, no question" "${out}" "127.0.0.1|rc=0|"
    expect_lacks "${sh}: ... and nothing asked" "${out}" "Which address"
    out="$(choose "${sh}" yes "" WORKBENCH_AWS_EMULATOR_BIND=all)"
    expect_has "${sh}: choose_bind: the setting 'all' → 0.0.0.0 without asking" "${out}" "0.0.0.0|rc=0|"
    out="$(choose "${sh}" yes "" WORKBENCH_AWS_EMULATOR_BIND=192.168.1.20)"
    expect_has "${sh}: choose_bind: a setting that is an address of this host is used" "${out}" "192.168.1.20|rc=0|"
    out="$(choose "${sh}" yes "" CHOOSE_ARG=0.0.0.0 WORKBENCH_AWS_EMULATOR_BIND=192.168.1.20)"
    expect_has "${sh}: choose_bind: --bind beats the setting" "${out}" "0.0.0.0|rc=0|"
    out="$(choose "${sh}" yes "" WORKBENCH_AWS_EMULATOR_BIND=10.9.9.9)"
    expect_has "${sh}: choose_bind: an address this host doesn't have is an error" "${out}" "rc=1|"
    expect_has "${sh}: ... that lists the valid addresses" "${out}" "10.9.9.9 is not an address of this host. Valid: all, 0.0.0.0, 127.0.0.1, 192.168.1.20, 172.17.0.1"
    out="$(run_in "${sh}" -- '
        _awsemu_ipv4_list() { printf "127.0.0.1 lo\n"; }
        _awsemu_have_tty() { return 0; }
        _read_prompt() { echo "ASKED"; }
        _awsemu_choose_bind')"
    expect_eq "${sh}: choose_bind: only loopback → no question, 127.0.0.1" "${out}" "127.0.0.1"
    out="$(choose "${sh}" yes "")"
    expect_has "${sh}: choose_bind: an empty answer is 1, 127.0.0.1" "${out}" "127.0.0.1|rc=0|"
    expect_has "${sh}: ... the question shows the numbered list" "${out}" "1) 127.0.0.1       lo        this machine only (default)~  2) 192.168.1.20    wlp1s0"
    expect_has "${sh}: ... and the 'all' line" "${out}" "a) all addresses (0.0.0.0)"
    expect_has "${sh}: ... and how to skip the question" "${out}" "To skip this question: set WORKBENCH_AWS_EMULATOR_BIND=127.0.0.1 (or an address, or all) in ~/.config/workbench/local/settings.sh"
    out="$(choose "${sh}" yes "2")"
    expect_has "${sh}: choose_bind: answer 2 → the second address" "${out}" "192.168.1.20|rc=0|"
    out="$(choose "${sh}" yes "3")"
    expect_has "${sh}: choose_bind: answer 3 → the third address" "${out}" "172.17.0.1|rc=0|"
    out="$(choose "${sh}" yes "a")"
    expect_has "${sh}: choose_bind: answer a → 0.0.0.0" "${out}" "0.0.0.0|rc=0|"
    out="$(choose "${sh}" yes "x|x|x")"
    expect_has "${sh}: choose_bind: three invalid answers fail" "${out}" "rc=1|"
    out="$(choose "${sh}" yes "x|9|2")"
    expect_has "${sh}: choose_bind: an invalid answer asks again" "${out}" "192.168.1.20|rc=0|"
    expect_has "${sh}: ... and says the answer isn't a choice" "${out}" "'x' is not one of the choices."
done

# ── 12. aws-emulator-server argv ─────────────────────────────────────────────
SERVER_ID="$(id -u):$(id -g)"
srv_world() {
    reset_world
    mkstub ss ': '
    mkstub ip "cat <<'EOF'
${IP_OUT}
EOF"
    mkstub curl 'echo ok'
}
# server <shell> [VAR=value ...] -- <aws-emulator-server args> → recorded calls (engine/emulator only)
server() {
    local sh="$1"
    shift
    local pre=()
    while [[ "$1" != "--" ]]; do pre+=("$1"); shift; done
    shift
    : > "${CALLS}"
    run_in "${sh}" WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel ${pre[@]+"${pre[@]}"} -- "aws-emulator-server $*; echo \"rc=\$?\"" > "${WORK}/server.out"
    cat "${WORK}/server.out"
}
for sh in ${SHELLS}; do
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 127.0.0.1 -p 9400 -- --idle-timeout 600)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq "${sh}: server (package): -b <ip> -p <port> then the pass-through" "${calls}" "aws-emulator -b|127.0.0.1|-p|9400|--idle-timeout|600|"
    expect_has "${sh}: server (package): foreground prints the endpoint and the use hint" "${out}" "AWS Emulator on https://127.0.0.1:9400 — in another shell: aws-emulator-use 9400   (Ctrl+C stops it)"
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -p 9400)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq "${sh}: server (package): without -b, no tty, the default is 127.0.0.1" "${calls}" "aws-emulator -b|127.0.0.1|-p|9400|"
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- --bind=127.0.0.1 --port=9401 -- --telemetry "'two words'")"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq "${sh}: server (package): --bind=/--port= forms, and an argument with a space survives" "${calls}" "aws-emulator -b|127.0.0.1|-p|9401|--telemetry|two words|"
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 127.0.0.1)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq "${sh}: server (package): with no -p the first free port from 9297" "${calls}" "aws-emulator -b|127.0.0.1|-p|9297|"
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package WORKBENCH_AWS_EMULATOR_PORT=9500 -- -b 127.0.0.1)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq "${sh}: server (package): WORKBENCH_AWS_EMULATOR_PORT moves the base port" "${calls}" "aws-emulator -b|127.0.0.1|-p|9500|"

    # container: podman
    srv_world; mkengine podman; echo "workbench-aws-emulator:latest" > "${WORK}/images"; mkstub selinuxenabled 'exit 0'
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400 -- --idle-timeout 60)"; calls="$(grep '^podman run' "${CALLS}")"
    want="podman run|--rm|--name|workbench-aws-emulator-9400|-p|127.0.0.1:9400:9400|-e|HOME=${HOME_DIR}|-v|${HOME_DIR}/.aws/emulator:${HOME_DIR}/.aws/emulator:z|--memory=2g|--memory-swap=2g|--userns=keep-id|--user|${SERVER_ID}|workbench-aws-emulator:latest|-p|9400|--idle-timeout|60|"
    expect_eq "${sh}: server (podman, SELinux on): the full argument list, in order" "${calls}" "${want}"
    if [[ -d "${HOME_DIR}/.aws/emulator" ]]; then
        ok "${sh}: server (container): ~/.aws/emulator is created by the user first"
    else
        fail "${sh}: ~/.aws/emulator was not created"
    fi
    srv_world; mkengine podman; echo "workbench-aws-emulator:latest" > "${WORK}/images"; mkstub selinuxenabled 'exit 1'
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"; calls="$(grep '^podman run' "${CALLS}")"
    expect_lacks "${sh}: server (podman): no :z when SELinux is off" "${calls}" ".aws/emulator:z"
    srv_world; mkengine podman; echo "workbench-aws-emulator:latest" > "${WORK}/images"
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"; calls="$(grep '^podman run' "${CALLS}")"
    expect_lacks "${sh}: server (podman): no :z without selinuxenabled" "${calls}" ".aws/emulator:z"
    srv_world; mkengine podman; echo "workbench-aws-emulator:latest" > "${WORK}/images"
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container WORKBENCH_AWS_EMULATOR_MEMORY=512m -- -b 127.0.0.1 -p 9400 -d)"; calls="$(grep '^podman run' "${CALLS}")"
    expect_has "${sh}: server (podman): WORKBENCH_AWS_EMULATOR_MEMORY sets both memory flags" "${calls}" "--memory=512m|--memory-swap=512m|"
    expect_has "${sh}: server (podman --detach): -d goes before the image" "${calls}" "--user|${SERVER_ID}|-d|workbench-aws-emulator:latest|-p|9400|"
    expect_has "${sh}: server (container --detach): waits for health and prints the endpoint" "${out}" "AWS Emulator on https://127.0.0.1:9400 — use it from a shell: aws-emulator-use 9400"
    expect_eq "${sh}: server (container --detach): the bind is recorded for use/list" "$(cat "${STATE_HOME}/workbench/cloud/aws-emulator/9400.bind")" "127.0.0.1"

    # docker rootless / rootful
    srv_world; mkengine docker; echo "workbench-aws-emulator:latest" > "${WORK}/images"
    echo "[name=seccomp,profile=builtin name=rootless name=cgroupns]" > "${WORK}/docker-secopts"
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"; calls="$(grep '^docker run' "${CALLS}")"
    expect_has "${sh}: server (rootless docker): --user 0:0" "${calls}" "--user|0:0|workbench-aws-emulator:latest|"
    echo "[name=seccomp,profile=builtin]" > "${WORK}/docker-secopts"
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"; calls="$(grep '^docker run' "${CALLS}")"
    expect_has "${sh}: server (rootful docker): --user <uid>:<gid>" "${calls}" "--user|${SERVER_ID}|workbench-aws-emulator:latest|"
    expect_lacks "${sh}: server (docker): no --userns" "${calls}" "--userns"

    # apple
    srv_world; mkengine container; echo "workbench-aws-emulator:latest" > "${WORK}/images"
    out="$(run_in "${sh}" WORKBENCH_OS=Mac WORKBENCH_DISTRO=unknown WORKBENCH_AWS_EMULATOR_ROUTE=container WORKBENCH_AWS_EMULATOR_ENGINE=apple -- 'aws-emulator-server -b 127.0.0.1 -p 9400; echo "rc=$?"')"
    calls="$(grep '^container run' "${CALLS}")"
    expect_has   "${sh}: server (apple): --memory 2g" "${calls}" "-e|HOME=${HOME_DIR}|-v|${HOME_DIR}/.aws/emulator:${HOME_DIR}/.aws/emulator|--memory|2g|workbench-aws-emulator:latest|-p|9400|"
    expect_lacks "${sh}: server (apple): no user flags, no memory-swap, no :z" "${calls}" "--user"
    expect_lacks "${sh}: server (apple): no --memory-swap" "${calls}" "--memory-swap"
    out="$(run_in "${sh}" WORKBENCH_OS=Mac WORKBENCH_DISTRO=unknown WORKBENCH_AWS_EMULATOR_ROUTE=container WORKBENCH_AWS_EMULATOR_ENGINE=apple -- 'aws-emulator-server -b 192.168.1.20 -p 9400; echo "rc=$?"')"
    expect_has "${sh}: server (apple): a non-loopback bind is refused" "${out}" "Apple's container CLI forwards ports from the loopback address only, so 192.168.1.20 is refused"
    expect_has "${sh}: ... with status 1" "${out}" "rc=1"

    # rejections and exposure
    srv_world
    for bad in "-p 9999" "--port 9999" "-b 127.0.0.1" "--bind 127.0.0.1" "--bind=127.0.0.1" "--port=9999"; do
        # shellcheck disable=SC2086 # the pair is split into two arguments on purpose
        out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -p 9400 -b 127.0.0.1 -- ${bad})"
        expect_has "${sh}: server: '${bad}' after -- is refused" "${out}" "use aws-emulator-server's own --bind/--port"
    done
    for off in "-a off" "--auth off" "--auth=off"; do
        srv_world
        # shellcheck disable=SC2086 # the pair is split into two arguments on purpose
        out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 192.168.1.20 -p 9400 -- ${off})"; calls="$(grep '^aws-emulator ' "${CALLS}")"
        expect_has "${sh}: server: '${off}' on a non-loopback bind is refused" "${out}" "refusing to listen on 192.168.1.20 with --auth off"
        expect_eq  "${sh}: ... and nothing is started" "${calls}" ""
    done
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 192.168.1.20 -p 9400 --allow-unauthenticated -- --auth off)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq  "${sh}: server: --allow-unauthenticated lets auth off through" "${calls}" "aws-emulator -b|192.168.1.20|-p|9400|--auth|off|"
    expect_has "${sh}: ... with the reachable-from-other-machines warning" "${out}" "192.168.1.20:9400 is reachable from other machines on that network"
    srv_world
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 127.0.0.1 -p 9400 -- --auth off)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq  "${sh}: server: auth off on loopback needs no flag" "${calls}" "aws-emulator -b|127.0.0.1|-p|9400|--auth|off|"
    srv_world; mkstub firewall-cmd 'echo running'
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b all -p 9400)"; calls="$(grep '^aws-emulator ' "${CALLS}")"
    expect_eq  "${sh}: server: 'all' binds 0.0.0.0" "${calls}" "aws-emulator -b|0.0.0.0|-p|9400|"
    expect_has "${sh}: server: running firewalld gets the firewall note" "${out}" "firewalld may block 9400/tcp; workbench doesn't change firewall rules (sudo firewall-cmd --add-port=9400/tcp to allow it until reboot)"
    expect_has "${sh}: server: 0.0.0.0 on the package route warns that AWS recommends it only in a container" "${out}" "AWS recommends binding 0.0.0.0 only inside a container"
    expect_has "${sh}: server: the endpoint for 0.0.0.0 is 127.0.0.1" "${out}" "AWS Emulator on https://127.0.0.1:9400"
    srv_world; rmstub aws-emulator; mkstub podman 'exit 0'
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=package -- -b 127.0.0.1 -p 9400)"
    expect_has "${sh}: server (package): a missing binary says how to install it" "${out}" "aws-emulator is not installed. Run: wb tools install aws-emulator"
    srv_world; mkengine podman
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"
    expect_has "${sh}: server (container): a missing image says how to build it" "${out}" "image workbench-aws-emulator:latest not found. Run: wb tools install aws-emulator"
    : > "${WORK}/engine-down"
    out="$(server "${sh}" WORKBENCH_AWS_EMULATOR_ROUTE=container -- -b 127.0.0.1 -p 9400)"
    expect_has "${sh}: server (container): an engine that isn't answering gets the start hint" "${out}" "podman is not answering — check 'podman info' for the error"
done

# ── 13. aws-emulator-use ─────────────────────────────────────────────────────
fake_instance() {
    # fake_instance <port> [with-creds]
    mkdir -p "${HOME_DIR}/.aws/emulator/$1"
    printf '[default]\nregion = us-east-1\nendpoint_url = https://127.0.0.1:%s\n' "$1" > "${HOME_DIR}/.aws/emulator/$1/config"
    : > "${HOME_DIR}/.aws/emulator/$1/ca.pem"
    [[ "${2:-}" == "nocreds" ]] || printf '[default]\naws_access_key_id = X\n' > "${HOME_DIR}/.aws/emulator/$1/emulator_credentials"
}
for sh in ${SHELLS}; do
    srv_world; mkengine podman; fake_instance 9300
    D="${HOME_DIR}/.aws/emulator/9300"
    out="$(run_in "${sh}" WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel AWS_ACCESS_KEY_ID=real-key AWS_SECRET_ACCESS_KEY=real-secret AWS_REGION=eu-west-1 AWS_CA_BUNDLE=/my/ca.pem -- '
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        aws-emulator-use 9300
        echo "ENDPOINT=$AWS_ENDPOINT_URL"; echo "CREDS=$AWS_SHARED_CREDENTIALS_FILE"; echo "CONFIG=$AWS_CONFIG_FILE"; echo "CA=$AWS_CA_BUNDLE"
        echo "META=$AWS_EC2_METADATA_DISABLED HOSTPFX=$AWS_DISABLE_HOST_PREFIX_INJECTION REGION=$AWS_REGION DEFREGION=$AWS_DEFAULT_REGION"
        echo "KEY=${AWS_ACCESS_KEY_ID-unset} SECRET=${AWS_SECRET_ACCESS_KEY-unset} TOKEN=${AWS_SESSION_TOKEN-unset} PROFILE=${AWS_PROFILE-unset}"
        echo "ACTIVE=$_AWSEMU_ACTIVE_PORT"
        echo "CHILD_SAVED=$(env | grep -c "^_AWSEMU_SAVED")"
        echo "CHILD_KEY=$(sh -c "echo \${AWS_ACCESS_KEY_ID-unset}")"
        echo "CHILD_ENDPOINT=$(sh -c "echo \$AWS_ENDPOINT_URL")"
        aws-emulator-use 9300 >/dev/null
        aws-emulator-use --off
        echo "AFTER KEY=${AWS_ACCESS_KEY_ID-unset} SECRET=${AWS_SECRET_ACCESS_KEY-unset} REGION=${AWS_REGION-unset} CA=${AWS_CA_BUNDLE-unset} ENDPOINT=${AWS_ENDPOINT_URL-unset} DEFREGION=${AWS_DEFAULT_REGION-unset} PROFILE=${AWS_PROFILE-unset}"
        echo "ACTIVE_AFTER=${_AWSEMU_ACTIVE_PORT-unset} SAVED_LEFT=$(set | grep -c "^_AWSEMU_SAVED\|^_AWSEMU_HAD")"')"
    expect_has "${sh}: use: AWS_ENDPOINT_URL" "${out}" "ENDPOINT=https://127.0.0.1:9300"
    expect_has "${sh}: use: AWS_SHARED_CREDENTIALS_FILE" "${out}" "CREDS=${D}/emulator_credentials"
    expect_has "${sh}: use: AWS_CONFIG_FILE" "${out}" "CONFIG=${D}/config"
    expect_has "${sh}: use: AWS_CA_BUNDLE replaces the user's own" "${out}" "CA=${D}/ca.pem"
    expect_has "${sh}: use: metadata off, host-prefix injection off, region us-east-1 (both variables)" "${out}" "META=true HOSTPFX=true REGION=us-east-1 DEFREGION=us-east-1"
    expect_has "${sh}: use: the credential variables that were set are now unset" "${out}" "KEY=unset SECRET=unset TOKEN=unset PROFILE=unset"
    expect_has "${sh}: use: the active port is remembered" "${out}" "ACTIVE=9300"
    expect_has "${sh}: use: saved originals are not exported to child processes" "${out}" "CHILD_SAVED=0"
    expect_has "${sh}: use: a child process sees no real key" "${out}" "CHILD_KEY=unset"
    expect_has "${sh}: use: a child process sees the endpoint" "${out}" "CHILD_ENDPOINT=https://127.0.0.1:9300"
    expect_has "${sh}: use: a second 'use' then --off restores the real originals, set and unset" "${out}" "AFTER KEY=real-key SECRET=real-secret REGION=eu-west-1 CA=/my/ca.pem ENDPOINT=unset DEFREGION=unset PROFILE=unset"
    expect_has "${sh}: use --off: clears the active port and every saved variable" "${out}" "ACTIVE_AFTER=unset SAVED_LEFT=0"
    expect_has "${sh}: use: says the credential variables are unset until --off" "${out}" "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_PROFILE are unset until aws-emulator-use --off"

    # 0.0.0.0 in .bind → the client uses 127.0.0.1; a specific address is kept
    mkdir -p "${STATE_HOME}/workbench/cloud/aws-emulator"
    echo "0.0.0.0" > "${STATE_HOME}/workbench/cloud/aws-emulator/9300.bind"
    out="$(run_in "${sh}" -- 'aws-emulator-use 9300 >/dev/null; echo "ENDPOINT=$AWS_ENDPOINT_URL"')"
    expect_has "${sh}: use: a 0.0.0.0 bind file gives https://127.0.0.1:9300" "${out}" "ENDPOINT=https://127.0.0.1:9300"
    echo "192.168.1.20" > "${STATE_HOME}/workbench/cloud/aws-emulator/9300.bind"
    out="$(run_in "${sh}" -- 'aws-emulator-use 9300 >/dev/null; echo "ENDPOINT=$AWS_ENDPOINT_URL"')"
    expect_has "${sh}: use: a specific bind address is used as the host" "${out}" "ENDPOINT=https://192.168.1.20:9300"
    rm -f "${STATE_HOME}/workbench/cloud/aws-emulator/9300.bind"
    sed -i.bak 's#https://127.0.0.1:9300#https://0.0.0.0:9300#' "${D}/config" && rm -f "${D}/config.bak"
    out="$(run_in "${sh}" -- 'aws-emulator-use 9300 >/dev/null; echo "ENDPOINT=$AWS_ENDPOINT_URL"')"
    expect_has "${sh}: use: with no bind file the host comes from the config (0.0.0.0 → 127.0.0.1)" "${out}" "ENDPOINT=https://127.0.0.1:9300"

    # auth off: no credentials file
    srv_world; mkengine podman; fake_instance 9301 nocreds
    out="$(run_in "${sh}" AWS_SHARED_CREDENTIALS_FILE=/my/creds -- 'aws-emulator-use 9301 >/dev/null; echo "CREDS=${AWS_SHARED_CREDENTIALS_FILE-unset}"; aws-emulator-use --off; echo "RESTORED=${AWS_SHARED_CREDENTIALS_FILE-unset}"')"
    expect_has "${sh}: use: without an emulator_credentials file the credentials-file variable is left alone" "${out}" "CREDS=/my/creds"
    expect_has "${sh}: ... and --off leaves it as it was" "${out}" "RESTORED=/my/creds"

    out="$(run_in "${sh}" -- 'aws-emulator-use 9302; echo "rc=$?"')"
    expect_has "${sh}: use: a port with no instance fails" "${out}" "no emulator running on 9302"
    expect_has "${sh}: ... with status 1" "${out}" "rc=1"
    out="$(run_in "${sh}" -- 'aws-emulator-use abc; echo "rc=$?"')"
    expect_has "${sh}: use: a non-numeric port is refused" "${out}" "'abc' is not a port number"
    out="$(run_in "${sh}" -- 'aws-emulator-use --off; echo "rc=$?"')"
    expect_has "${sh}: use --off without a prior use says so and succeeds" "${out}" "no AWS Emulator is in use in this shell"

    # no port: the only live instance, else a list and a failure
    srv_world; mkengine podman; fake_instance 9310
    out="$(run_in "${sh}" -- 'aws-emulator-use >/dev/null; echo "ENDPOINT=$AWS_ENDPOINT_URL"')"
    expect_has "${sh}: use (no port): the only live instance is used" "${out}" "ENDPOINT=https://127.0.0.1:9310"
    fake_instance 9311
    out="$(run_in "${sh}" -- 'aws-emulator-use; echo "rc=$?"')"
    expect_has "${sh}: use (no port): two live instances → lists them and fails" "${out}" "9311"
    expect_has "${sh}: ... asking for a port" "${out}" "say which port to use"
    : > "${WORK}/curl-fail"; mkstub curl 'exit 22'
    out="$(run_in "${sh}" -- 'aws-emulator-use; echo "rc=$?"')"
    expect_has "${sh}: use (no port): no live instance fails" "${out}" "rc=1"
done

# ── 14. stop, list ───────────────────────────────────────────────────────────
# A process whose name is aws-emulator: a copy of sleep.
PROC_BIN="${WORK}/procbin"
mkdir -p "${PROC_BIN}"
if cp "$(command -v sleep)" "${PROC_BIN}/aws-emulator" 2>/dev/null && "${PROC_BIN}/aws-emulator" 0 2>/dev/null; then
    for sh in ${SHELLS}; do
        srv_world; mkengine podman
        STATE_DIR="${STATE_HOME}/workbench/cloud/aws-emulator"
        mkdir -p "${STATE_DIR}"
        "${PROC_BIN}/aws-emulator" 300 &
        real_pid=$!
        echo "${real_pid}" > "${STATE_DIR}/9320.pid"; echo "127.0.0.1" > "${STATE_DIR}/9320.bind"
        fake_instance 9320
        out="$(run_in "${sh}" -- 'aws-emulator-list')"
        expect_has "${sh}: list: a detached instance shows port, bind, route, mode and state" "${out}" "9320   127.0.0.1       package    detached          healthy"
        expect_has "${sh}: list: has the header" "${out}" "PORT   BIND            ROUTE      MODE              STATE"
        out="$(run_in "${sh}" -- 'aws-emulator-stop 9320; echo "rc=$?"')"
        sleep 1
        if kill -0 "${real_pid}" 2>/dev/null; then fail "${sh}: stop: the process is still running"; kill "${real_pid}" 2>/dev/null; else ok "${sh}: stop: SIGTERM stops a detached instance"; fi
        expect_has "${sh}: stop: reports it" "${out}" "port 9320: stopped"
        if [[ ! -e "${STATE_DIR}/9320.pid" && ! -e "${STATE_DIR}/9320.bind" ]]; then
            ok "${sh}: stop: the pid and bind files are removed"
        else
            fail "${sh}: stop: tracking files remain"
        fi
        wait "${real_pid}" 2>/dev/null

        # a reused pid is never signalled
        sleep 300 &
        other_pid=$!
        echo "${other_pid}" > "${STATE_DIR}/9321.pid"
        out="$(run_in "${sh}" -- 'aws-emulator-stop 9321; echo "rc=$?"')"
        if kill -0 "${other_pid}" 2>/dev/null; then ok "${sh}: stop: a pid that is not an aws-emulator is left alone"; kill "${other_pid}" 2>/dev/null; else fail "${sh}: stop: signalled a process that is not aws-emulator"; fi
        wait "${other_pid}" 2>/dev/null
        if [[ ! -e "${STATE_DIR}/9321.pid" ]]; then
            ok "${sh}: stop: ... and its stale pid file is removed"
        else
            fail "${sh}: stale pid file remains"
        fi

        # an instance workbench didn't start
        fake_instance 9322
        out="$(run_in "${sh}" -- 'aws-emulator-stop 9322; echo "rc=$?"')"
        expect_has "${sh}: stop: a live instance workbench didn't start gets the explanation" "${out}" "port 9322: not started by aws-emulator-server --detach; stop it where it runs (Ctrl+C)"
        out="$(run_in "${sh}" -- 'aws-emulator-stop 9399; echo "rc=$?"')"
        expect_has "${sh}: stop: an unknown port says there is no instance" "${out}" "port 9399: no AWS Emulator instance"

        # containers
        srv_world; mkengine podman
        mkstub podman "case \"\$1\" in info) exit 0 ;; ps) echo workbench-aws-emulator-9330; echo workbench-aws-emulator-9331 ;; stop) exit 0 ;; esac; exit 0"
        out="$(run_in "${sh}" WORKBENCH_OS=Linux -- 'aws-emulator-stop 9330; echo "rc=$?"')"
        expect_has "${sh}: stop: a container is stopped by name" "$(cat "${CALLS}")" "podman stop|workbench-aws-emulator-9330|"
        : > "${CALLS}"
        out="$(run_in "${sh}" WORKBENCH_OS=Linux -- 'aws-emulator-stop --all; echo "rc=$?"')"
        expect_has "${sh}: stop --all: stops every container workbench started" "$(cat "${CALLS}")" "podman stop|workbench-aws-emulator-9331|"
        expect_has "${sh}: stop --all: ... both of them" "$(cat "${CALLS}")" "podman stop|workbench-aws-emulator-9330|"
        out="$(run_in "${sh}" WORKBENCH_OS=Linux -- 'aws-emulator-list')"
        expect_has "${sh}: list: a container shows as route container" "${out}" "9330"
        expect_has "${sh}: ... in container mode" "${out}" "container  container         not answering"

        # leftovers
        srv_world; mkengine podman
        mkdir -p "${HOME_DIR}/.aws/emulator/9340" "${HOME_DIR}/.aws/emulator/telemetry"
        out="$(run_in "${sh}" -- 'aws-emulator-list')"
        expect_eq "${sh}: list: an empty directory (what a clean stop leaves) and the telemetry directory are not instances" "${out}" "no AWS Emulator instances"
        fake_instance 9341; : > "${WORK}/curl-fail"; mkstub curl 'exit 22'
        out="$(run_in "${sh}" -- 'aws-emulator-list')"
        expect_has "${sh}: list: a directory with a config and nothing answering is stale files" "${out}" "9341   127.0.0.1       -          foreground/other  stale files (left by a crash)"
        mkdir -p "${STATE_DIR}"; echo 999999 > "${STATE_DIR}/9342.pid"; echo "127.0.0.1" > "${STATE_DIR}/9342.bind"; echo "127.0.0.1" > "${STATE_DIR}/9343.bind"
        run_in "${sh}" -- 'aws-emulator-list' >/dev/null
        if [[ ! -e "${STATE_DIR}/9342.pid" && ! -e "${STATE_DIR}/9342.bind" && ! -e "${STATE_DIR}/9343.bind" ]]; then
            ok "${sh}: list: removes pid and bind files whose process is gone"
        else
            fail "${sh}: list: stale tracking files remain"
        fi
    done
else
    echo "SKIP: cannot make a process named aws-emulator here — stop/list process checks not run"
fi

# ── 15. availability is declared before the guard ────────────────────────────
for sh in ${SHELLS}; do
    reset_world; rmstub aws-emulator
    rm -f "${WORK}/availability"
    run_in "${sh}" -- ':' >/dev/null
    got="$(cat "${WORK}/availability" 2>/dev/null)"
    want='--needs|aws-emulator (or a container engine with the image built)|--install|aws-emulator|_awsemu_runtime_present|aws-emulator-server|aws-emulator-stop|aws-emulator-list|aws-emulator-use|aws-emulator-update|'
    expect_eq "${sh}: the availability declaration is made, with a reason and --install aws-emulator, before the guard" "${got}" "${want}"
    out="$(run_in "${sh}" -- 'type aws-emulator-server >/dev/null 2>&1 && echo defined || echo not-defined')"
    expect_eq "${sh}: with no runtime on the host the guard returns before any function is defined" "${out}" "not-defined"
    mkstub podman 'exit 0'
    out="$(run_in "${sh}" -- 'type aws-emulator-server >/dev/null 2>&1 && echo defined || echo not-defined')"
    expect_eq "${sh}: a container engine alone is enough to define the functions" "${out}" "defined"
done
reset_world
out="$(run_in bash -- 'wb() { echo "wb $*"; }; aws-emulator-update')"
expect_eq "aws-emulator-update runs 'wb tools install aws-emulator'" "${out}" "wb tools install aws-emulator"

# ── 16. the manifest registers both files ────────────────────────────────────
if grep -q 'src: shell/aws-emulator.sh' "${REPO_ROOT}/workbench.yml" && grep -q 'src: shell/installers-aws-emulator.sh' "${REPO_ROOT}/workbench.yml"; then
    ok "workbench.yml registers shell/aws-emulator.sh and shell/installers-aws-emulator.sh"
else
    fail "workbench.yml does not register both AWS Emulator files"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
