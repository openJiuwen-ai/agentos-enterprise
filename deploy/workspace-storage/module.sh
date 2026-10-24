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

# ===== upgrade 迁移钩子（供 agentos.sh upgrade 调用） =====

# Phase 0 + Phase 1: 检测是否需要迁移 + 数据迁移
# 前提: 旧集群仍在运行，etcd 可用，/home/agentos/users 可读
# 输出: 子进程变量无法回传，通过 stdout 协议行传递 ——
#       WORKSPACE_MIGRATION_NEEDED=yes/no
#       yes 时同时输出 WORKSPACE_NODE_IPS_FILE=<节点 IP 列表文件>
#       （由 agentos.sh upgrade 逐行解析）
workspace-storage-upgrade_migrate() {
    _ws_run upgrade_migrate "$@"
}

# Phase 3.3: 写 etcd 归属记录
# 前提: 新集群 install + init 完成，etcd 可用
# 输入: WORKSPACE_NODE_IPS_FILE（Phase 1 保存的节点 IP 列表）
workspace-storage-upgrade_write_etcd() {
    _ws_run upgrade_write_etcd "$@"
}
