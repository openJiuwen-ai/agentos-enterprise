#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# Bind prepared AgentOS configuration to the Swarm artifact's service handlers.

BUSINESS_PYTHON="${SWARM_PYTHON:-python3.11}"
SERVICE_SETTINGS="${SCRIPT_DIR}/../agent-runtime/configure.py"

swarm_service() {
    local -a args=("$@")
    [ -z "${SWARM_BINDINGS:-}" ] || args+=(--bindings "${SWARM_BINDINGS}")
    "${BUSINESS_PYTHON}" "${SERVICE_SETTINGS}" "${args[@]}"
}

get_local_ip() { echo "${BIND_IP:-127.0.0.1}"; }
check_cmds() { check_cmd "${BUSINESS_PYTHON}"; }
check_gateway_up_dependency() { check_cmds; }
check_web_up_dependency() { check_cmds; }
gateway_check_jiuwenswarm_home() { return 0; }
web_resolve_host() { get_local_ip; }

gateway_get_config_dir() {
    # configure.py has already resolved the instance-specific application home.
    printf '%s/.jiuwenswarm/config\n' "${DEPLOY_VARS[HOME]:-/root}"
}

swarm_export_environment() {
    export HOME="${DEPLOY_VARS[HOME]}" JIUWENSWARM_HOME="${DEPLOY_VARS[HOME]}"
    export JIUWENSWARM_DATA_DIR="$(gateway_data_directory)"
    export JIUWENSWARM_RUNTIME_PROFILE="${DEPLOY_VARS[RUNTIME_PROFILE]:-agentos}"
    export GATEWAY_HOST="${DEPLOY_VARS[GATEWAY_HOST]}" GATEWAY_PORT="${DEPLOY_VARS[GATEWAY_PORT]}"
    export WEB_HOST="${DEPLOY_VARS[WEB_HOST]}" WEB_PORT="${DEPLOY_VARS[WEB_PORT]}"
    local executable
    executable=$(command -v "${BUSINESS_PYTHON}") || return
    export PATH="$(dirname "${executable}"):${PATH}"
}

swarm_prepare_service_environment() {
    local host service temporary directory key value
    host=$(get_local_ip)
    gateway_has_systemd "${host}" || return 0
    for service in "$(gateway_service_name)" "$(web_service_name)"; do
        directory="/etc/systemd/system/${service}.service.d"
        temporary=$(mktemp)
        {
            printf '[Service]\n'
            for key in HOME JIUWENSWARM_HOME JIUWENSWARM_DATA_DIR JIUWENSWARM_RUNTIME_PROFILE GATEWAY_HOST GATEWAY_PORT WEB_HOST WEB_PORT; do
                value="${!key}"
                value="${value//\\/\\\\}"
                value="${value//\"/\\\"}"
                printf 'Environment="%s=%s"\n' "${key}" "${value}"
            done
            if [ "${service}" = "$(web_service_name)" ] && [ -n "${SWARM_SERVICE_PREFLIGHT:-}" ]; then
                printf 'ExecStartPre=%s\n' "${SWARM_SERVICE_PREFLIGHT}"
            fi
        } > "${temporary}"
        exec_on_host "${host}" "mkdir -p '${directory}'"
        copy_to_host "${host}" "${temporary}" "${directory}/zz-agentos.conf"
        rm -f "${temporary}"
    done
}

gateway_load_config() {
    local bindings
    bindings=$(swarm_service variables) || return
    eval "${bindings}"
    swarm_export_environment
    swarm_prepare_service_environment
    # Only the Web proxy uses loopback; the listener keeps the exported WEB_HOST.
    case "${DEPLOY_VARS[WEB_HOST]}" in
        0.0.0.0) DEPLOY_VARS[WEB_HOST]=127.0.0.1 ;;
        ::) DEPLOY_VARS[WEB_HOST]='[::1]' ;;
    esac
}

gateway_deploy_process() {
    local host service
    host=$(get_local_ip)
    service=$(gateway_service_name)
    if gateway_has_systemd "${host}" && exec_on_host "${host}" "systemctl is-active --quiet ${service}"; then
        warning "${service} already running; run 'down' first to redeploy"
        return 0
    fi
    if exec_on_host "${host}" "pgrep -f '[j]iuwenswarm-gateway' >/dev/null 2>&1"; then
        warning "Gateway process already running; run 'down' first to redeploy"
        return 0
    fi
    # agent-runtime has already prepared the configuration. Reuse Swarm startup
    # and health checks without initializing or overwriting the workspace again.
    if gateway_has_systemd "${host}"; then
        gateway_start_systemd "${host}" 0
    else
        gateway_start_nohup "${host}" ""
    fi
}

main() {
    local explicit=0 argument identity
    for argument in "$@"; do
        case "${argument}" in gateway|web|jiuwenswarm) explicit=1 ;; esac
    done
    if [ "${explicit}" -eq 0 ]; then set -- "$@" gateway web; fi
    parse_args "$@"
    check_dependency
    case "${CMD}" in
        down|restart)
            identity=$(swarm_service identity) || return
            eval "${identity}"
            process_down
            ;;
    esac
    case "${CMD}" in
        up|restart) gateway_load_config; process_up ;;
    esac
}
