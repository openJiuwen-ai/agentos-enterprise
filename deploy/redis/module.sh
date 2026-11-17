#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# Install-time verification only; service lifecycle remains in deploy/redis.sh.
# redis-server 二进制随 ADX 发布包（agent-runtime install 解压）交付：
# 这里只做可用性校验（install 阶段早失败），不重复安装；卸载不删任何文件（同 etcd）。

redis_install() {
    local bin
    if [ -n "${REDIS_BIN_PATH:-}" ]; then
        bin="${REDIS_BIN_PATH}"
    else
        bin="${ADX_PACKAGE_DIR:-/opt/adx/current}/bin/redis-server"
        [ -x "${bin}" ] || bin="$(command -v redis-server 2>/dev/null || true)"
    fi
    if [ -z "${bin}" ] || [ ! -x "${bin}" ]; then
        error_noexit "redis-server binary not found (tried: REDIS_BIN_PATH, ${ADX_PACKAGE_DIR:-/opt/adx/current}/bin/redis-server, PATH)"
        error_noexit "agent-runtime install 应随 ADX 发布包交付 redis-server；自备 redis 时请设置 REDIS_BIN_PATH"
        return 1
    fi
    info "redis-server ready at ${bin}; service starts with 'agentos.sh init' (deploy/redis.sh)"
    return 0
}

redis_uninstall() {
    # Application uninstall intentionally leaves redis running and preserves its data/password.
    info "Standalone redis retained; stop its service separately with agentos.sh deinit"
}
