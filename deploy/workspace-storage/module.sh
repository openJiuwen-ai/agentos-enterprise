#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
WORKSPACE_STORAGE_DEPLOY_DIR="${SCRIPT_DIR}/workspace-storage"

# 内部工具：调用 deploy.sh
_ws_run() {
    local ws_script="${WORKSPACE_STORAGE_DEPLOY_DIR}/deploy.sh"
    if [ ! -f "${ws_script}" ]; then
        error "workspace-storage deploy script not found: ${ws_script}"
    fi
    bash "${ws_script}" "$@"
}

workspace-storage_up() {
    _ws_run up "$@"
}

workspace-storage_down() {
    _ws_run down "$@"
}

workspace-storage_install() {
    _ws_run install "$@"
}

workspace-storage_uninstall() {
    _ws_run uninstall "$@"
}

workspace-storage_status() {
    _ws_run status "$@"
}

# ===== migrate 数据迁移钩子（供 agentos.sh migrate 调用） =====
# 前提: 旧集群仍在运行，etcd 可用，/home/agentos/users 可读（旧 MooseFS 挂载中）
# 行为: 从 config.yaml 的 cluster_nodes 取节点列表 → HRW 归属 →
#       rsync 本机归属用户到 ${WORKSPACE_STORAGE_ROOT} → 写 etcd 归属记录
#       （一次完成，幂等可重跑）
workspace-storage-migrate() {
    _ws_run migrate "$@"
}
