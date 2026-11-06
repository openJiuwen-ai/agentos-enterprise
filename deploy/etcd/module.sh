#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# Binary installation only; service lifecycle remains in deploy/etcd.sh.

# Resolve the install root once so init/deinit/status (separate processes) can
# reuse a custom AGENTOS_ETCD_ROOT chosen during install.
_agentos_etcd_resolve_root() {
    local root="${AGENTOS_ETCD_ROOT:-}" file
    if [ -z "${root}" ]; then
        for file in /etc/agentos/etcd-root "${HOME:-/root}/.agentos/etcd-root"; do
            if [ -r "${file}" ]; then
                root="$(cat "${file}")"
                if [ -n "${root}" ]; then
                    break
                fi
            fi
        done
    fi
    printf '%s' "${root:-/opt/agentos/etcd}"
}

_agentos_etcd_persist_root() {
    local root="$1" file
    for file in /etc/agentos/etcd-root "${HOME:-/root}/.agentos/etcd-root"; do
        mkdir -p "$(dirname "${file}")" || return 1
        printf '%s\n' "${root}" > "${file}" || return 1
        chmod 644 "${file}" 2>/dev/null || true
    done
}

AGENTOS_ETCD_ROOT="$(_agentos_etcd_resolve_root)"
export AGENTOS_ETCD_ROOT

etcd_install() {
    local py arch archive
    local -a args=(--root "${AGENTOS_ETCD_ROOT}")
    py=$(command -v "python${YR_PYTHON_VERSION}" || command -v python3) || return 1
    arch=$(uname -m)
    case "${arch}" in
        amd64) arch=x86_64 ;;
        arm64) arch=aarch64 ;;
    esac
    archive="${ETCD_ARCHIVE:-${SCRIPT_DIR}/../etcd-linux-${arch}.tar.gz}"
    if [ ! -f "${archive}" ]; then
        error_noexit "Bundled etcd archive not found: ${archive}; rebuild the Server package with build/build-v2.sh"
        return 1
    fi
    args+=(--archive "${archive}")
    "${py}" "${SCRIPT_DIR}/etcd/install.py" "${args[@]}" || return 1
    # Persist the install root so later init/deinit/status processes resolve the
    # same binary, and expose the matching etcdctl to workspace/autofs.
    _agentos_etcd_persist_root "${AGENTOS_ETCD_ROOT}" || {
        error_noexit "Failed to persist AGENTOS_ETCD_ROOT=${AGENTOS_ETCD_ROOT}"
        return 1
    }
    export ETCDCTL_PATH="${ETCDCTL_PATH:-${AGENTOS_ETCD_ROOT}/current/bin/etcdctl}"
}

etcd_uninstall() {
    # Application uninstall intentionally leaves etcd running and preserves its binaries/data.
    info "Standalone etcd retained; stop its service separately with agentos.sh deinit"
}
