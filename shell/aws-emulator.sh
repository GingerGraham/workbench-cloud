#!/usr/bin/env bash
# shell/aws-emulator.sh — workbench-cloud
# Run and use AWS Emulator instances (workbench-core D128). Registered at
# tier: tools; sourced unconditionally; self-guards below. Installed by
# `wb tools install aws-emulator` (shell/installers-aws-emulator.sh).
#
# Sourced by bash and zsh, so: no arrays (zsh arrays start at 1), command
# lines are built with `set --` and "$@", no [[ =~ ]], no `read -a`, no
# `type -P` outside _awsemu_bin_path, no unmatched globs, and no variable
# named like a zsh special (status, path, options, prompt, ...).

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

# Cheap presence check for listings and the guard: the native binary or any
# engine binary. Doesn't check that the image exists: on macOS that needs
# the engine VM running, too slow and too fragile for every shell start.
_awsemu_runtime_present() {
    [ -n "$(_awsemu_bin_path aws-emulator)" ] && return 0
    [ -n "$(_awsemu_bin_path podman)" ] && return 0
    [ -n "$(_awsemu_bin_path docker)" ] && return 0
    [ "${WORKBENCH_OS:-}" = "Mac" ] && [ -n "$(_awsemu_bin_path container)" ] && return 0
    return 1
}

# Declared before the guard, for the same reason as shell/aws.sh.
_wb_alias_availability --needs "aws-emulator (or a container engine with the image built)" \
    --install aws-emulator _awsemu_runtime_present \
    aws-emulator-server aws-emulator-stop aws-emulator-list aws-emulator-use aws-emulator-update

_awsemu_runtime_present || return 0

# ── private helpers ───────────────────────────────────────────────────────────

# Runtime state of detached instances: a pid, a log and a bind file per
# port. Only this file's functions read and write it (D128 item 8).
_awsemu_state_dir() {
    printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}/workbench/cloud/aws-emulator"
}

# The directory the emulator writes an instance's files into.
_awsemu_instance_dir() {
    printf '%s\n' "${HOME}/.aws/emulator/$1"
}

_awsemu_container_name() {
    printf 'workbench-aws-emulator-%s\n' "$1"
}

_awsemu_have_tty() { { : </dev/tty; } 2>/dev/null; }

# _awsemu_ipv4_list — "<address> <interface>" per line, loopback first.
_awsemu_ipv4_list() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show 2>/dev/null \
            | awk '{ split($4, a, "/"); print a[1], $2 }'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '
            /^[^ \t]/ { iface = $1; sub(":$", "", iface) }
            $1 == "inet" { addr = $2; sub("^addr:", "", addr); print addr, iface }'
    fi | awk '$1 ~ /^127\./ { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }'
}

# Port checks are the Core API's workbench_port_in_use and
# workbench_port_pick (CORE_API_VERSION 1.12), moved there from this file so
# workbench-containers can use them too (workbench-core D129).

# _awsemu_bind_valid <address> — 0.0.0.0, or an IPv4 address of this host.
_awsemu_bind_valid() {
    [ "$1" = "0.0.0.0" ] && return 0
    [ "$1" = "127.0.0.1" ] && return 0
    [ -n "$(_awsemu_ipv4_list | awk -v a="$1" '$1 == a { print; exit }')" ]
}

# _awsemu_choose_bind [<requested>] — prints the address to bind. Order of
# precedence: the argument (--bind), WORKBENCH_AWS_EMULATOR_BIND, a question,
# then 127.0.0.1. "all" means 0.0.0.0. The question is asked only when this
# host has a non-loopback IPv4 address and a person can answer.
_awsemu_choose_bind() {
    local requested="${1:-}" list others count tries answer pick
    [ -n "${requested}" ] || requested="${WORKBENCH_AWS_EMULATOR_BIND:-}"
    if [ -n "${requested}" ]; then
        [ "${requested}" = "all" ] && requested="0.0.0.0"
        if _awsemu_bind_valid "${requested}"; then
            printf '%s\n' "${requested}"
            return 0
        fi
        log_error "aws-emulator: ${requested} is not an address of this host. Valid: all, 0.0.0.0, $(_awsemu_ipv4_list | awk '{ printf "%s%s", sep, $1; sep = ", " }')"
        return 1
    fi

    list="$(_awsemu_ipv4_list)"
    others="$(printf '%s\n' "${list}" | awk '$1 !~ /^127\./ && $1 != "" { print; exit }')"
    if [ -z "${others}" ] || ! _awsemu_have_tty; then
        printf '127.0.0.1\n'
        return 0
    fi

    count="$(printf '%s\n' "${list}" | awk 'NF { n++ } END { print n + 0 }')"
    {
        printf 'Which address should the AWS Emulator listen on?\n'
        printf '%s\n' "${list}" | awk '
            NF {
                n++
                note = ""
                if ($1 ~ /^127\./) note = "this machine only"
                if (n == 1) note = (note == "" ? "(default)" : note " (default)")
                printf "  %d) %-15s %-9s %s\n", n, $1, $2, note
            }'
        printf '  a) all addresses (0.0.0.0)\n'
    } >&2

    tries=0
    while [ "${tries}" -lt 3 ]; do
        answer=""
        _read_prompt "Choice [1]: " answer
        [ -n "${answer}" ] || answer=1
        case "${answer}" in
            a|all)
                pick="0.0.0.0"
                ;;
            *[!0-9]*)
                pick=""
                ;;
            *)
                pick=""
                if [ "${answer}" -ge 1 ] && [ "${answer}" -le "${count}" ]; then
                    pick="$(printf '%s\n' "${list}" | awk -v n="${answer}" 'NF { i++ } i == n { print $1; exit }')"
                fi
                ;;
        esac
        if [ -n "${pick}" ]; then
            printf 'To skip this question: set WORKBENCH_AWS_EMULATOR_BIND=127.0.0.1 (or an address, or all) in ~/.config/workbench/local/settings.sh\n' >&2
            printf '%s\n' "${pick}"
            return 0
        fi
        printf "'%s' is not one of the choices.\n" "${answer}" >&2
        tries=$((tries + 1))
    done
    log_error "aws-emulator: no valid address chosen"
    return 1
}

# _awsemu_endpoint_host <bind> — the host a client connects to.
_awsemu_endpoint_host() {
    if [ "$1" = "0.0.0.0" ]; then
        printf '127.0.0.1\n'
    else
        printf '%s\n' "$1"
    fi
}

# _awsemu_health <port> <host> — 0 when the instance's health route answers
# "ok". Checked against the instance's own ca.pem, never with -k. --noproxy:
# a proxy variable in the environment must not carry this local request.
_awsemu_health() {
    local port="$1" host="$2" body
    body="$(curl -fsS -m 5 --noproxy '*' --cacert "$(_awsemu_instance_dir "${port}")/ca.pem" \
        "https://${host}:${port}/__admin/health" 2>/dev/null)" || return 1
    [ "${body}" = "ok" ]
}

# _awsemu_wait_healthy <port> <host> — up to 30 tries, one second apart.
# A first start takes about ten seconds.
_awsemu_wait_healthy() {
    local port="$1" host="$2" tries=0
    while [ "${tries}" -lt 30 ]; do
        _awsemu_health "${port}" "${host}" && return 0
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

# _awsemu_pid_of <port> — prints the pid in <state>/<port>.pid when that
# process is a live aws-emulator. A reused pid is never reported.
_awsemu_pid_of() {
    local file epid comm
    file="$(_awsemu_state_dir)/$1.pid"
    [ -f "${file}" ] || return 1
    epid="$(command cat "${file}" 2>/dev/null)"
    case "${epid}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    comm="$(ps -p "${epid}" -o comm= 2>/dev/null)"
    case "${comm}" in
        aws-emulator|*/aws-emulator)
            printf '%s\n' "${epid}"
            return 0
            ;;
    esac
    return 1
}

# _awsemu_container_ports <engine> — the ports of workbench's containers.
_awsemu_container_ports() {
    local cmd
    cmd="$(_awsemu_engine_cmd "$1")"
    case "$1" in
        apple) "${cmd}" list --quiet 2>/dev/null ;;
        *)     "${cmd}" ps --filter 'name=^workbench-aws-emulator-' --format '{{.Names}}' 2>/dev/null ;;
    esac | sed -n 's/^workbench-aws-emulator-\([0-9][0-9]*\)$/\1/p'
}

# _awsemu_container_engine — prints the engine that answers, for listing and
# stopping containers. Fails quietly when there is none.
_awsemu_container_engine() {
    local engine
    engine="$(_awsemu_engine 2>/dev/null)" || return 1
    _awsemu_engine_usable "${engine}" || return 1
    printf '%s\n' "${engine}"
}

# _awsemu_all_ports <engine|""> — every port workbench can see, one per line:
# detached pid files, containers of <engine> (none when empty), and
# directories under ~/.aws/emulator that hold a config. A directory without
# one is what a clean stop leaves behind.
_awsemu_all_ports() {
    local state engine="$1" dir
    state="$(_awsemu_state_dir)"
    {
        if [ -d "${state}" ]; then
            command find "${state}" -maxdepth 1 -name '*.pid' 2>/dev/null | sed -n 's#.*/\([0-9][0-9]*\)\.pid$#\1#p'
        fi
        [ -n "${engine}" ] && _awsemu_container_ports "${engine}"
        dir="${HOME}/.aws/emulator"
        if [ -d "${dir}" ]; then
            command find "${dir}" -mindepth 2 -maxdepth 2 -name config 2>/dev/null | sed -n 's#.*/\([0-9][0-9]*\)/config$#\1#p'
        fi
    } | sort -n -u
}

# _awsemu_instance_host <port> — the host a client uses for an instance:
# from the bind file when there is one, else from the endpoint in its config.
_awsemu_instance_host() {
    local port="$1" bindfile bind host
    bindfile="$(_awsemu_state_dir)/${port}.bind"
    if [ -f "${bindfile}" ]; then
        bind="$(command cat "${bindfile}" 2>/dev/null)"
        if [ -n "${bind}" ]; then
            _awsemu_endpoint_host "${bind}"
            return 0
        fi
    fi
    host="$(sed -n 's#^endpoint_url[[:space:]]*=[[:space:]]*https://\([^:/]*\).*#\1#p' "$(_awsemu_instance_dir "${port}")/config" 2>/dev/null | head -n 1)"
    [ -n "${host}" ] || return 1
    _awsemu_endpoint_host "${host}"
}

# _awsemu_server_usage
_awsemu_server_usage() {
    command cat <<'EOF'
Usage: aws-emulator-server [-b|--bind <ip>|all] [-p|--port <port>] [-d|--detach]
                           [--allow-unauthenticated] [-h|--help] [-- <emulator options>]

  -b, --bind <ip>|all       address to listen on (default: 127.0.0.1; "all" is 0.0.0.0).
                            Without this, WORKBENCH_AWS_EMULATOR_BIND, then a question
                            when the host has other addresses.
  -p, --port <port>         port, 1024-65535 (default: the first free port from 9297,
                            or from WORKBENCH_AWS_EMULATOR_PORT).
  -d, --detach              run in the background and wait until it answers.
  --allow-unauthenticated   allow a non-loopback address with --auth off.
  -- <emulator options>     passed on, e.g. -- --idle-timeout 600 -t off
EOF
}

# ── aws-emulator-server ───────────────────────────────────────────────────────
aws-emulator-server() {
    local bind_opt="" port_opt="" detach="" allow_open="" auth_off=""
    local route engine cmd port bind host state name mem vol arg prev rc

    while [ $# -gt 0 ]; do
        case "$1" in
            -b|--bind)
                [ $# -ge 2 ] || { log_error "aws-emulator-server: $1 needs a value"; return 2; }
                bind_opt="$2"
                shift 2
                ;;
            --bind=*) bind_opt="${1#--bind=}"; shift ;;
            -p|--port)
                [ $# -ge 2 ] || { log_error "aws-emulator-server: $1 needs a value"; return 2; }
                port_opt="$2"
                shift 2
                ;;
            --port=*) port_opt="${1#--port=}"; shift ;;
            -d|--detach) detach=1; shift ;;
            --allow-unauthenticated) allow_open=1; shift ;;
            -h|--help) _awsemu_server_usage; return 0 ;;
            --) shift; break ;;
            *)
                log_error "aws-emulator-server: unknown option '$1' (emulator options go after --)"
                return 2
                ;;
        esac
    done

    # What is left in "$@" goes to the emulator.
    prev=""
    for arg in "$@"; do
        case "${arg}" in
            -b|--bind|--bind=*|-p|--port|--port=*)
                log_error "aws-emulator-server: use aws-emulator-server's own --bind/--port, not '${arg}' after --"
                return 2
                ;;
            --auth=off|-a=off) auth_off=1 ;;
        esac
        case "${prev}:${arg}" in
            -a:off|--auth:off) auth_off=1 ;;
        esac
        prev="${arg}"
    done

    route="$(_awsemu_route)" || return 1

    if [ -n "${port_opt}" ]; then
        case "${port_opt}" in
            ''|*[!0-9]*)
                log_error "aws-emulator-server: --port must be a number from 1024 to 65535 (got '${port_opt}')"
                return 2
                ;;
        esac
        if [ "${port_opt}" -lt 1024 ] || [ "${port_opt}" -gt 65535 ]; then
            log_error "aws-emulator-server: --port must be from 1024 to 65535 (got ${port_opt}); 0 and privileged ports are not used"
            return 2
        fi
        port="${port_opt}"
        if workbench_port_in_use "${port}"; then
            log_error "aws-emulator-server: port ${port} is in use"
            return 1
        fi
    else
        port="$(workbench_port_pick "${WORKBENCH_AWS_EMULATOR_PORT:-9297}" aws-emulator)" || return 1
    fi

    bind="$(_awsemu_choose_bind "${bind_opt}")" || return 1
    host="$(_awsemu_endpoint_host "${bind}")"

    # Exposure: who can reach the instance.
    case "${bind}" in
        127.*) ;;
        *)
            if [ -n "${auth_off}" ] && [ -z "${allow_open}" ]; then
                log_error "aws-emulator-server: refusing to listen on ${bind} with --auth off: anyone who can reach that address could call the emulator without credentials. Pass --allow-unauthenticated if that is what you want."
                return 1
            fi
            log_warn "aws-emulator-server: ${bind}:${port} is reachable from other machines on that network"
            if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
                log_warn "firewalld may block ${port}/tcp; workbench doesn't change firewall rules (sudo firewall-cmd --add-port=${port}/tcp to allow it until reboot)"
            fi
            if [ "${bind}" = "0.0.0.0" ] && [ "${route}" = "package" ]; then
                log_warn "AWS recommends binding 0.0.0.0 only inside a container"
            fi
            ;;
    esac

    state="$(_awsemu_state_dir)"
    mkdir -p "${state}" && chmod 700 "${state}" 2>/dev/null
    name="$(_awsemu_container_name "${port}")"

    if [ "${route}" = "package" ]; then
        if [ -z "$(_awsemu_bin_path aws-emulator)" ]; then
            log_error "aws-emulator-server: aws-emulator is not installed. Run: wb tools install aws-emulator"
            return 1
        fi
        cmd="aws-emulator"
        set -- -b "${bind}" -p "${port}" "$@"
    else
        engine="$(_awsemu_engine)" || {
            log_error "aws-emulator-server: no container engine found. Run: wb tools install aws-emulator for the options"
            return 1
        }
        cmd="$(_awsemu_engine_cmd "${engine}")"
        if ! _awsemu_engine_usable "${engine}"; then
            log_error "aws-emulator-server: ${engine} is not answering — $(_awsemu_engine_start_hint "${engine}")"
            return 1
        fi
        if ! "${cmd}" image inspect "${_AWSEMU_IMAGE}:latest" >/dev/null 2>&1; then
            log_error "aws-emulator-server: image ${_AWSEMU_IMAGE}:latest not found. Run: wb tools install aws-emulator"
            return 1
        fi
        if [ "${engine}" = "apple" ]; then
            case "${bind}" in
                127.*) ;;
                *)
                    log_error "aws-emulator-server: Apple's container CLI forwards ports from the loopback address only, so ${bind} is refused (D128). Use podman or Docker for a non-loopback address."
                    return 1
                    ;;
            esac
        fi

        # ~/.aws/emulator is created here, as this user: an engine would
        # create a missing bind-mount source as root.
        if [ ! -d "${HOME}/.aws/emulator" ]; then
            mkdir -p "${HOME}/.aws/emulator" && chmod 700 "${HOME}/.aws/emulator"
        fi

        mem="${WORKBENCH_AWS_EMULATOR_MEMORY:-2g}"
        vol="${HOME}/.aws/emulator:${HOME}/.aws/emulator"
        # :z, not :Z: several instances share the directory, and :Z would
        # give it one container's private label.
        if [ "${WORKBENCH_OS:-}" = "Linux" ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
            vol="${vol}:z"
        fi

        # The argument list is built back to front, in front of the options
        # that were passed through.
        set -- "${_AWSEMU_IMAGE}:latest" -p "${port}" "$@"
        [ -n "${detach}" ] && set -- -d "$@"
        if [ "${WORKBENCH_OS:-}" = "Linux" ]; then
            case "${engine}" in
                podman)
                    set -- --userns=keep-id --user "$(id -u):$(id -g)" "$@"
                    ;;
                docker)
                    # Rootless Docker maps container root to this user and
                    # uid 1000 to a subuid, which couldn't read the 0600 files.
                    case "$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)" in
                        *rootless*) set -- --user 0:0 "$@" ;;
                        *)          set -- --user "$(id -u):$(id -g)" "$@" ;;
                    esac
                    ;;
            esac
        fi
        case "${engine}" in
            apple) set -- --memory "${mem}" "$@" ;;
            *)     set -- "--memory=${mem}" "--memory-swap=${mem}" "$@" ;;
        esac
        set -- -e "HOME=${HOME}" -v "${vol}" "$@"
        set -- run --rm --name "${name}" -p "${bind}:${port}:${port}" "$@"
    fi

    printf '%s\n' "${bind}" > "${state}/${port}.bind"

    if [ -z "${detach}" ]; then
        printf 'AWS Emulator on https://%s:%s — in another shell: aws-emulator-use %s   (Ctrl+C stops it)\n' "${host}" "${port}" "${port}"
        "${cmd}" "$@"
        rc=$?
        rm -f "${state}/${port}.bind"
        return "${rc}"
    fi

    # Detached. A native process is started in a subshell so that zsh prints
    # no job-control messages into the user's terminal.
    if [ "${route}" = "package" ]; then
        ( nohup aws-emulator "$@" > "${state}/${port}.log" 2>&1 & echo $! > "${state}/${port}.pid" )
    else
        "${cmd}" "$@" >/dev/null || {
            log_error "aws-emulator-server: ${cmd} could not start the container"
            rm -f "${state}/${port}.bind"
            return 1
        }
    fi

    if _awsemu_wait_healthy "${port}" "${host}"; then
        printf 'AWS Emulator on https://%s:%s — use it from a shell: aws-emulator-use %s\n' "${host}" "${port}" "${port}"
        return 0
    fi

    log_error "aws-emulator-server: the instance on port ${port} did not answer within 30 seconds"
    if [ "${route}" = "package" ]; then
        tail -n 20 "${state}/${port}.log" 2>/dev/null >&2
    else
        "${cmd}" logs "${name}" 2>&1 | tail -n 20 >&2
    fi
    _awsemu_stop_one "${port}" >/dev/null 2>&1
    rm -f "${state}/${port}.bind"
    return 1
}

# ── aws-emulator-stop ─────────────────────────────────────────────────────────
# _awsemu_stop_one <port> — stops one instance workbench started.
# 0 stopped, 1 not stopped, 3 not an instance workbench is tracking.
_awsemu_stop_one() {
    local port="$1" state epid tries engine cmd name running
    state="$(_awsemu_state_dir)"
    name="$(_awsemu_container_name "${port}")"

    epid="$(_awsemu_pid_of "${port}")"
    if [ -n "${epid}" ]; then
        kill -TERM "${epid}" 2>/dev/null
        tries=0
        while [ "${tries}" -lt 10 ] && kill -0 "${epid}" 2>/dev/null; do
            sleep 1
            tries=$((tries + 1))
        done
        if kill -0 "${epid}" 2>/dev/null; then
            log_error "aws-emulator-stop: port ${port} (pid ${epid}) is still running after 10 seconds"
            return 1
        fi
        rm -f "${state}/${port}.pid" "${state}/${port}.bind"
        printf 'port %s: stopped\n' "${port}"
        return 0
    fi
    # A pid file whose process is gone, or was reused by something else.
    rm -f "${state}/${port}.pid"

    engine="$(_awsemu_container_engine)" || engine=""
    if [ -n "${engine}" ]; then
        running="$(_awsemu_container_ports "${engine}" | awk -v p="${port}" '$1 == p { print; exit }')"
        if [ -n "${running}" ]; then
            cmd="$(_awsemu_engine_cmd "${engine}")"
            if "${cmd}" stop "${name}" >/dev/null 2>&1; then
                rm -f "${state}/${port}.bind"
                printf 'port %s: stopped\n' "${port}"
                return 0
            fi
            log_error "aws-emulator-stop: ${cmd} could not stop ${name}"
            return 1
        fi
    fi

    return 3
}

aws-emulator-stop() {
    local target port rc worst=0 found=0 engine
    case "${1:-}" in
        ''|-h|--help)
            printf 'Usage: aws-emulator-stop <port> | --all\n'
            [ -n "${1:-}" ] && return 0
            return 2
            ;;
        --all)
            engine="$(_awsemu_container_engine)" || engine=""
            for port in $(_awsemu_all_ports "${engine}"); do
                _awsemu_stop_one "${port}"
                rc=$?
                case "${rc}" in
                    0) found=1 ;;
                    3) ;;
                    *) found=1; worst=1 ;;
                esac
            done
            [ "${found}" -eq 0 ] && printf 'no AWS Emulator instances started by workbench\n'
            return "${worst}"
            ;;
    esac

    target="$1"
    case "${target}" in
        *[!0-9]*)
            log_error "aws-emulator-stop: '${target}' is not a port number"
            return 2
            ;;
    esac
    _awsemu_stop_one "${target}"
    rc=$?
    if [ "${rc}" -eq 3 ]; then
        if [ -f "$(_awsemu_instance_dir "${target}")/config" ]; then
            printf 'port %s: not started by aws-emulator-server --detach; stop it where it runs (Ctrl+C)\n' "${target}"
        else
            printf 'port %s: no AWS Emulator instance\n' "${target}"
        fi
        return 1
    fi
    return "${rc}"
}

# ── aws-emulator-list ─────────────────────────────────────────────────────────
aws-emulator-list() {
    local state port engine epid bind route mode instance_state host
    local container_ports found=0
    state="$(_awsemu_state_dir)"
    engine="$(_awsemu_container_engine)" || engine=""
    container_ports=""
    [ -n "${engine}" ] && container_ports="$(_awsemu_container_ports "${engine}")"

    # Tracking files whose process is gone: a pid file with no live
    # aws-emulator, and a bind file with nothing left behind it.
    if [ -d "${state}" ]; then
        for port in $(command find "${state}" -maxdepth 1 \( -name '*.pid' -o -name '*.bind' \) 2>/dev/null | sed -n 's#.*/\([0-9][0-9]*\)\.[a-z]*$#\1#p' | sort -n -u); do
            epid="$(_awsemu_pid_of "${port}")"
            if [ -z "${epid}" ] \
                && ! printf '%s\n' "${container_ports}" | grep -qx "${port}" \
                && [ ! -f "$(_awsemu_instance_dir "${port}")/config" ]; then
                rm -f "${state}/${port}.pid" "${state}/${port}.bind"
            fi
        done
    fi

    for port in $(_awsemu_all_ports "${engine}"); do
        epid="$(_awsemu_pid_of "${port}")"
        bind=""
        [ -f "${state}/${port}.bind" ] && bind="$(command cat "${state}/${port}.bind" 2>/dev/null)"
        if [ -n "${epid}" ]; then
            route="package"; mode="detached"
        elif printf '%s\n' "${container_ports}" | grep -qx "${port}"; then
            route="container"; mode="container"
        else
            route="-"; mode="foreground/other"
        fi
        [ -n "${bind}" ] || bind="$(_awsemu_instance_host "${port}" 2>/dev/null)"
        [ -n "${bind}" ] || bind="-"

        host="$(_awsemu_instance_host "${port}" 2>/dev/null)"
        if [ -n "${host}" ] && _awsemu_health "${port}" "${host}"; then
            instance_state="healthy"
        elif [ "${mode}" = "foreground/other" ]; then
            instance_state="stale files (left by a crash)"
        else
            instance_state="not answering"
        fi

        if [ "${found}" -eq 0 ]; then
            printf '%-6s %-15s %-10s %-17s %s\n' PORT BIND ROUTE MODE STATE
            found=1
        fi
        printf '%-6s %-15s %-10s %-17s %s\n' "${port}" "${bind}" "${route}" "${mode}" "${instance_state}"
    done

    [ "${found}" -eq 1 ] || printf 'no AWS Emulator instances\n'
    return 0
}

# ── aws-emulator-use ──────────────────────────────────────────────────────────
# The variables aws-emulator-use may change. Each is saved before the first
# change and restored by --off.
_awsemu_each_var() {
    local v
    for v in AWS_ENDPOINT_URL AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_CA_BUNDLE \
             AWS_EC2_METADATA_DISABLED AWS_DISABLE_HOST_PREFIX_INJECTION AWS_REGION AWS_DEFAULT_REGION \
             AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE; do
        "$1" "${v}"
    done
}

# Saved in unexported shell variables, so real credentials are not passed on
# to child processes.
_awsemu_save_var() {
    local v="$1"
    if eval "[ -n \"\${${v}+set}\" ]"; then
        eval "_AWSEMU_HAD_${v}=1; _AWSEMU_SAVED_${v}=\${${v}}"
    else
        eval "_AWSEMU_HAD_${v}=0; _AWSEMU_SAVED_${v}="
    fi
}

_awsemu_restore_var() {
    local v="$1"
    if eval "[ \"\${_AWSEMU_HAD_${v}:-0}\" = 1 ]"; then
        eval "export ${v}=\"\${_AWSEMU_SAVED_${v}}\""
    else
        eval "unset ${v}"
    fi
    eval "unset _AWSEMU_HAD_${v} _AWSEMU_SAVED_${v}"
}

aws-emulator-use() {
    local port dir host live count candidate engine
    case "${1:-}" in
        -h|--help)
            printf 'Usage: aws-emulator-use [<port>] | --off\n'
            return 0
            ;;
        --off)
            if [ -z "${_AWSEMU_ACTIVE_PORT:-}" ]; then
                printf 'no AWS Emulator is in use in this shell\n'
                return 0
            fi
            _awsemu_each_var _awsemu_restore_var
            port="${_AWSEMU_ACTIVE_PORT}"
            unset _AWSEMU_ACTIVE_PORT
            printf 'stopped using the AWS Emulator on port %s; your AWS variables are back as they were\n' "${port}"
            return 0
            ;;
    esac

    port="${1:-}"
    if [ -z "${port}" ]; then
        live=""
        engine="$(_awsemu_container_engine)" || engine=""
        for candidate in $(_awsemu_all_ports "${engine}"); do
            host="$(_awsemu_instance_host "${candidate}" 2>/dev/null)"
            if [ -n "${host}" ] && _awsemu_health "${candidate}" "${host}"; then
                live="${live}${candidate}
"
            fi
        done
        count="$(printf '%s' "${live}" | awk 'NF { n++ } END { print n + 0 }')"
        if [ "${count}" -eq 1 ]; then
            port="$(printf '%s' "${live}" | awk 'NF { print; exit }')"
        else
            aws-emulator-list
            log_error "aws-emulator-use: say which port to use (aws-emulator-use <port>)"
            return 1
        fi
    fi
    case "${port}" in
        *[!0-9]*)
            log_error "aws-emulator-use: '${port}' is not a port number"
            return 2
            ;;
    esac

    dir="$(_awsemu_instance_dir "${port}")"
    if [ ! -f "${dir}/config" ]; then
        log_error "aws-emulator-use: no emulator running on ${port}"
        return 1
    fi
    host="$(_awsemu_instance_host "${port}")" || {
        log_error "aws-emulator-use: can't read the endpoint of the emulator on ${port} from ${dir}/config"
        return 1
    }

    # Save the originals once: a second `use` must not save the emulator's own
    # values as the "originals".
    if [ -z "${_AWSEMU_ACTIVE_PORT:-}" ]; then
        _awsemu_each_var _awsemu_save_var
    fi

    export AWS_ENDPOINT_URL="https://${host}:${port}"
    # With auth off the emulator writes no credentials file.
    if [ -f "${dir}/emulator_credentials" ]; then
        export AWS_SHARED_CREDENTIALS_FILE="${dir}/emulator_credentials"
    fi
    export AWS_CONFIG_FILE="${dir}/config"
    export AWS_CA_BUNDLE="${dir}/ca.pem"
    export AWS_EC2_METADATA_DISABLED=true
    export AWS_DISABLE_HOST_PREFIX_INJECTION=true
    export AWS_REGION=us-east-1
    export AWS_DEFAULT_REGION=us-east-1
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
    _AWSEMU_ACTIVE_PORT="${port}"

    printf 'using the AWS Emulator on port %s (%s)\n' "${port}" "${AWS_ENDPOINT_URL}"
    printf 'AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_PROFILE are unset until aws-emulator-use --off\n'
    return 0
}

# ── aws-emulator-update ───────────────────────────────────────────────────────
# Same pattern as aws-update: installer files are never sourced into the
# interactive shell (workbench-core D94).
aws-emulator-update() {
    wb tools install aws-emulator
}
