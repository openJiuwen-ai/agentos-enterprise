#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: jiuwenswarm (函数 + gateway，whl 包已包含 gateway)
# 钩子函数: jiuwenswarm_up / jiuwenswarm_down / jiuwenswarm_install / jiuwenswarm_uninstall / jiuwenswarm_status
# ============================================================

# 构建时已将 jiuwenswarm submodule 中部署相关脚本文件拷贝到当前脚本执行目录中，故 deploy.sh 与 module.sh 同目录
JIUWENSWARM_DEPLOY_DIR="${SCRIPT_DIR}/jiuwenswarm"

# ===== 用户配置刷新 =====
# 直接把最新的 root 模板刷给存量用户，不做模板/用户判断。
# 失败只告警，不影响调用方结果（例如本机没有已初始化用户时脚本返回 1）。
jiuwenswarm_refresh_users() {
    AGENTOS_HOME_BASE="${AGENTOS_HOME_BASE:-/home/agentos/users}" \
    AGENTOS_SWARM_TEMPLATE="${AGENTOS_SWARM_TEMPLATE:-${AGENTOS_SWARM_TEMPLATE_DIR:-${HOME:-/root}/.jiuwenswarm}/config/config.yaml}" \
        bash "${JIUWENSWARM_DEPLOY_DIR}/refresh-user-config.sh" --all -y \
        || warning "用户配置刷新未完成，可手动重试: ${JIUWENSWARM_DEPLOY_DIR}/refresh-user-config.sh --all -y"
}

# ===== up/down: 调用 deploy.sh =====
# deploy.sh 使用相对路径 source，需在其所在目录下执行
jiuwenswarm_up() {
    jiuwenswarm_run_deploy up "$@"
}

jiuwenswarm_down() {
    jiuwenswarm_run_deploy down "$@"
}

jiuwenswarm_run_deploy() {
    local sub_cmd="$1"
    shift
    local jw_script="${JIUWENSWARM_DEPLOY_DIR}/deploy.sh"
    if [ ! -f "${jw_script}" ]; then
        error "jiuwenswarm deploy script not found: ${jw_script}"
    fi

    local custom_env="${JIUWENSWARM_DEPLOY_DIR}/.env.custom"
    if [ ! -f "${custom_env}" ]; then
        warning "No .env.custom found at ${custom_env}, deploy.sh will use defaults"
    fi

    info "Deploying jiuwenswarm in ${JIUWENSWARM_DEPLOY_DIR}: ${sub_cmd} $*"
    (
        cd "${JIUWENSWARM_DEPLOY_DIR}"
        bash ./deploy.sh ${sub_cmd} "$@"
    )
}

# ===== install/uninstall: 本机 pip 操作 =====
# 发行包名：0.2.8 起为 workswarm-<version>-py3-none-any.whl；日构建（agent_os 分支）
# 仍为 jiuwenswarm-<version>-py3-none-any.whl。两者包内路径和 console script 均不变，
# 只有 pip 发行包名不同。whl 已包含 gateway。

jiuwenswarm_install() {
    # 工具沙箱镜像检查：先于任何安装动作执行（fail-fast），不满足条件时直接中断，
    # 避免 whl 已装到一半、后续模块未装、无 install 汇总的半安装状态
    _jiuwenswarm_check_sandbox_image

    local local_host
    local_host="${BIND_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    [ -z "${local_host}" ] && local_host="127.0.0.1"

    local found_whl
    # 0.2.8 起官方发行包为 workswarm-*；日构建仍为 jiuwenswarm-*。workswarm 优先。
    # 注意：不能用单个 ls 合并两个 glob —— ls 会跨参数做字母序合并排序，而
    # jiuwenswarm 在任何 locale 下都排在 workswarm 之前，会让 "workswarm 优先" 失效。
    # 故先查 workswarm，仅当无匹配时再回退 jiuwenswarm。
    found_whl=$(ls "${AGENTOS_ROOT}"/workswarm-*-py3-none-any.whl 2>/dev/null || true)
    if [ -z "${found_whl}" ]; then
        found_whl=$(ls "${AGENTOS_ROOT}"/jiuwenswarm-*-py3-none-any.whl 2>/dev/null || true)
    fi
    if [ -n "${found_whl}" ]; then
        local jw_whl="${found_whl%%$'\n'*}"
        info "Found jiuwenswarm whl: ${jw_whl}"
        # 0.2.8 起发行包名改为 workswarm：新旧发行包的 RECORD 会同时声明同一批
        # jiuwenswarm/* 文件（包内路径不变），两份 dist-info 并存后 pip uninstall
        # 任一个都会删掉另一个仍在用的文件。
        # 顺序：先装新包（失败时旧包仍在，服务不中断），装成功后再定向删除旧发行包的
        # dist-info 目录（仅清元数据，不动 jiuwenswarm/* 共享文件），覆盖
        # workswarm→jiuwenswarm 与 jiuwenswarm→workswarm 两个方向。
        local new_dist other_dist
        if [[ "$(basename "${jw_whl}")" == workswarm-* ]]; then
            new_dist="workswarm"; other_dist="jiuwenswarm"
        else
            new_dist="jiuwenswarm"; other_dist="workswarm"
        fi
        if bash -c "python${YR_PYTHON_VERSION} -m pip install '${jw_whl}[ssh]' --quiet"; then
            # 加固：pip show 确认新发行包确实已注册到当前 Python 环境
            if python${YR_PYTHON_VERSION} -m pip show "${new_dist}" >/dev/null 2>&1; then
                success "jiuwenswarm installed on ${local_host} (${new_dist})"
            else
                error "pip install returned success but 'pip show ${new_dist}' failed on ${local_host} (wheel may be corrupted or installed to wrong env)"
            fi
            # 清理旧发行包残留的 dist-info 元数据（仅删 *.dist-info 目录，不动共享文件）。
            # 用 pip show 的 Location 定位 site-packages，避免 getsitepackages 在 venv 下取错索引。
            if python${YR_PYTHON_VERSION} -m pip show "${other_dist}" >/dev/null 2>&1; then
                local old_loc old_dis_arr=()
                old_loc=$(python${YR_PYTHON_VERSION} -m pip show "${other_dist}" 2>/dev/null \
                    | awk -F': ' '/^Location:/{print $2; exit}')
                # old_loc 为空时必须跳过：否则 "${old_loc}"/${other_dist}-*.dist-info 会
                # 退化成 /${other_dist}-*.dist-info 从根目录 glob（无 nullglob 下未匹配
                # 保留字面量，rm -f 虽不删东西但会打印误导性的 "Removed" 日志）。
                if [ -n "${old_loc}" ]; then
                    # 用 ls -d 把 glob 解析成实际路径，再用 mapfile 收进数组，最后
                    # rm -rf -- "${arr[@]}" 逐元素传递。不能写成 rm -rf ${old_dis}：
                    # old_loc 来自 pip show 的 Location，是 site-packages 绝对路径，可能
                    # 含空格（自定义 venv 如 /opt/agent os/venv/...）或通配符。含空格路径
                    # 不加引号会按 IFS 拆成残缺 token，rm -rf 递归删除真实存在的无关目录
                    # （root 执行，低概率但后果严重）；含 */? 还会被二次 glob 扩展。
                    mapfile -t old_dis_arr < <(ls -d "${old_loc}"/${other_dist}-*.dist-info 2>/dev/null || true)
                    if [ ${#old_dis_arr[@]} -gt 0 ]; then
                        if rm -rf -- "${old_dis_arr[@]}"; then
                            info "Removed orphaned ${other_dist} dist-info: ${old_dis_arr[*]}"
                        else
                            warning "Failed to remove orphaned ${other_dist} dist-info: ${old_dis_arr[*]}"
                        fi
                    fi
                fi
            fi
        else
            error "Failed to install jiuwenswarm on ${local_host}"
        fi
    else
        warning "No jiuwenswarm/workswarm whl found at ${AGENTOS_ROOT}/ (expected workswarm-<version>-py3-none-any.whl or jiuwenswarm-<version>-py3-none-any.whl), skipping jiuwenswarm install"
        warning "Please place the jiuwenswarm wheel in ${AGENTOS_ROOT}/ before install"
    fi

    # 安装完成后刷新存量用户配置
    # 放在 whl 分支之外：无 whl（已装好的环境）时同样可修复用户配置
    jiuwenswarm_refresh_users
}

# 读取 env 文件中 KEY=VALUE 的值，兼容值带双引号/单引号/不带引号三种写法
# 注意：不能用 cut -d'"' -f2 —— 值不带引号时会返回整行 "KEY=value"，导致检查被静默跳过
_jwsw_env_value() {
    local file="$1" key="$2" line
    line=$(grep -E "^${key}=" "${file}" 2>/dev/null | tail -n 1 || true)
    line="${line#*=}"
    line="${line#\"}"
    line="${line%\"}"
    line="${line#\'}"
    line="${line%\'}"
    printf '%s' "${line}"
}

# 把 .env.custom 中已有的 KEY= 行改成 KEY="value"；没有该行时追加
_jiuwenswarm_set_env_value() {
    local file="$1" key="$2" value="$3"
    local tmp found=0
    tmp=$(mktemp)
    while IFS= read -r line || [ -n "${line}" ]; do
        if [[ "${line}" == "${key}="* ]]; then
            printf '%s="%s"\n' "${key}" "${value}"
            found=1
        else
            printf '%s\n' "${line}"
        fi
    done < "${file}" > "${tmp}"
    if [ "${found}" -eq 0 ]; then
        printf '%s="%s"\n' "${key}" "${value}" >> "${tmp}"
    fi
    mv "${tmp}" "${file}"
}

# 当前机器对应的 Conch 镜像 tag：x86_64 -> latest-amd64，aarch64 -> latest-arm64
_jiuwenswarm_host_conch_tag() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)
            printf '%s' "latest-amd64"
            ;;
        aarch64|arm64)
            printf '%s' "latest-arm64"
            ;;
        *)
            error "Unsupported architecture '${arch}' for Conch sandbox image tag; expected x86_64 or aarch64."
            ;;
    esac
}

# 镜像最后一段（最后一个 / 之后）是否已经带 tag。registry:port 里的冒号不算 tag。
_jiuwenswarm_image_has_tag() {
    local image="$1" leaf
    leaf="${image##*/}"
    [[ "${leaf}" == *:* ]]
}

# 给没有 tag 的镜像补上 Conch tag。调用方需先确认没有 tag。
# swr.../tool-sandbox -> swr.../tool-sandbox:latest-arm64 / :latest-amd64
_jiuwenswarm_image_with_conch_tag() {
    local image="$1" tag="$2"
    printf '%s:%s' "${image}" "${tag}"
}

# 检查工具沙箱镜像
# TOOL_SANDBOX_ENABLE=true 且 TOOL_SANDBOX_EXECUTOR=docker 时，install 检测本地是否已有沙箱镜像。
# docker 命令缺失、守护进程不可达或镜像不存在时，均直接中断安装。
# TOOL_SANDBOX_EXECUTOR=conch 时不检查本地镜像。镜像已有 tag 则保持原样；
# 没有 tag 时按当前架构补上 latest-arm64 / latest-amd64，并写回 .env.custom。
_jiuwenswarm_check_sandbox_image() {
    local env_file="${JIUWENSWARM_DEPLOY_DIR}/.env.custom"
    local sandbox_type="" sandbox_enable="" sandbox_image="" sandbox_executor=""

    # 从 .env.custom 读取工具沙箱配置
    if [ -f "${env_file}" ]; then
        sandbox_type=$(_jwsw_env_value "${env_file}" 'TOOL_SANDBOX_TYPE')
        sandbox_enable=$(_jwsw_env_value "${env_file}" 'TOOL_SANDBOX_ENABLE')
        sandbox_image=$(_jwsw_env_value "${env_file}" 'TOOL_SANDBOX_IMAGE')
        sandbox_executor=$(_jwsw_env_value "${env_file}" 'TOOL_SANDBOX_EXECUTOR')
    fi
    sandbox_executor=$(printf '%s' "${sandbox_executor}" | tr '[:upper:]' '[:lower:]')

    # 仅当工具沙箱启用时处理
    if [ "${sandbox_enable}" = "true" ] && [ -n "${sandbox_image}" ]; then
        if [ "${sandbox_executor}" = "conch" ]; then
            if _jiuwenswarm_image_has_tag "${sandbox_image}"; then
                info "TOOL_SANDBOX_IMAGE already has a tag, leave it unchanged: ${sandbox_image}"
            else
                local conch_tag new_image
                conch_tag=$(_jiuwenswarm_host_conch_tag)
                new_image=$(_jiuwenswarm_image_with_conch_tag "${sandbox_image}" "${conch_tag}")
                _jiuwenswarm_set_env_value "${env_file}" "TOOL_SANDBOX_IMAGE" "${new_image}"
                success "TOOL_SANDBOX_EXECUTOR=conch: TOOL_SANDBOX_IMAGE=${new_image}"
            fi
            if [ -n "${sandbox_type}" ]; then
                info "Current TOOL_SANDBOX_TYPE: ${sandbox_type}"
            fi
            return 0
        fi

        if [ "${sandbox_executor}" != "docker" ]; then
            info "Skip sandbox image check: TOOL_SANDBOX_EXECUTOR=${sandbox_executor:-<empty>} (image inspect runs only for docker)."
            return 0
        fi

        # docker 命令不存在：提示后中断（error 会 exit 1，提示需全部先输出）
        if ! command -v docker >/dev/null 2>&1; then
            echo ""
            warning "Tool sandbox is enabled (TOOL_SANDBOX_ENABLE=true) but docker is not available on this host."
            warning "Please install docker first, then pull the sandbox image:"
            echo ""
            echo "    docker pull ${sandbox_image}"
            echo ""
            error "Install aborted: docker is required when TOOL_SANDBOX_ENABLE=true."
        fi

        # docker 守护进程不可达（未运行或当前用户无权限），需与"镜像不存在"区分开，避免误导用户去 pull
        if ! docker info >/dev/null 2>&1; then
            echo ""
            warning "Tool sandbox is enabled (TOOL_SANDBOX_ENABLE=true) but the docker daemon is not reachable."
            warning "Please make sure docker is running and the current user has permission to access it:"
            echo ""
            echo "    systemctl status docker"
            echo ""
            error "Install aborted: docker daemon is not reachable."
        fi

        # 精确检查镜像是否存在（docker image inspect 支持带 tag / digest 的完整引用，避免 grep 子串误判）
        if ! docker image inspect "${sandbox_image}" >/dev/null 2>&1; then
            echo ""
            warning "Tool sandbox is enabled (TOOL_SANDBOX_ENABLE=true) but sandbox image not found in docker images."
            warning "You MUST manually pull the image before install can proceed:"
            echo ""
            echo "    docker pull ${sandbox_image}"
            echo ""
            error "Install aborted. After pulling the image, re-run install. See deploy/README.md (Tool Sandbox Image section) for details."
        fi

        success "Tool sandbox image found: ${sandbox_image}"
        if [ -n "${sandbox_type}" ]; then
            info "Current TOOL_SANDBOX_TYPE: ${sandbox_type}"
        fi
    fi
}

# 停用并禁用 jiuwenswarm-gateway 和 jiuwenswarm-web 的 systemd 服务（本机），清理 unit 文件与 drop-in
# uninstall 是本机操作（与 install 对称），故仅处理本机 systemd 服务；
jiuwenswarm_disable_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || return 0
    local unit_file found=0
    # 枚举 gateway 和 web 两类 unit
    for unit_file in /etc/systemd/system/jiuwenswarm-gateway*.service /etc/systemd/system/jiuwenswarm-web*.service; do
        [ -f "${unit_file}" ] || continue
        found=1
        local svc_name
        svc_name=$(basename "${unit_file}" .service)
        info "Disabling systemd service ${svc_name}..."
        systemctl disable --now "${svc_name}" 2>/dev/null || true
        systemctl reset-failed "${svc_name}" 2>/dev/null || true
        rm -rf "${unit_file}" "/etc/systemd/system/${svc_name}.service.d"
    done

    systemctl daemon-reload 2>/dev/null || true
    if [ "${found}" -eq 1 ]; then
        success "jiuwenswarm systemd services disabled and cleaned up"
    else
        info "No jiuwenswarm systemd unit found, skipping"
    fi
}

jiuwenswarm_uninstall() {
    local local_host
    local_host="${BIND_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    [ -z "${local_host}" ] && local_host="127.0.0.1"

    # 先停用 systemd 服务，再卸载 pip 包，避免卸载后残留 unit 文件
    jiuwenswarm_disable_systemd

    # 0.2.8 起发行包名为 workswarm；旧环境/日构建为 jiuwenswarm，两者都尝试卸载
    local name removed="" openjiuwen_removed=0
    for name in workswarm jiuwenswarm; do
        if python${YR_PYTHON_VERSION} -m pip show "${name}" >/dev/null 2>&1; then
            if python${YR_PYTHON_VERSION} -m pip uninstall -y "${name}" >/dev/null 2>&1; then
                removed+="${name} "
            else
                warning "Failed to uninstall ${name} on ${local_host}"
            fi
        fi
    done
    # openjiuwen: 仅在已安装时卸载，退出码参与成败判定（不再用 || true 吞掉）。
    # 吞掉退出码会让下面 success 固定打印 "and openjiuwen uninstalled" 产生假成功，
    # 与本 PR 把 openjiuwen 升到 0.1.20 的诉求冲突（卸载失败需如实告警）。
    if python${YR_PYTHON_VERSION} -m pip show openjiuwen >/dev/null 2>&1; then
        if python${YR_PYTHON_VERSION} -m pip uninstall -y openjiuwen >/dev/null 2>&1; then
            openjiuwen_removed=1
        else
            warning "Failed to uninstall openjiuwen on ${local_host}"
        fi
    fi

    if [ -n "${removed}" ]; then
        if [ "${openjiuwen_removed}" -eq 1 ]; then
            success "jiuwenswarm (${removed% }) and openjiuwen uninstalled on ${local_host}"
        else
            success "jiuwenswarm (${removed% }) uninstalled on ${local_host}"
        fi
    else
        warning "jiuwenswarm/workswarm not installed on ${local_host}, nothing to uninstall"
    fi
}

# 只读探测本机 jiuwenswarm 运行状态
# 检测 jiuwenswarm-gateway 和 jiuwenswarm-web 两个服务
# 输出格式: jiuwenswarm|<service>|<state>|<detail>|<version>
jiuwenswarm_status() {
    local rc=0

    # 探测 jiuwenswarm 版本号：importlib.metadata 比 pip show 快约 30 倍
    # 发行包名随版本变化：0.2.8 起为 workswarm，旧包为 jiuwenswarm。
    # 两个包名在单个 Python 进程内按序探测，避免只有旧包的存量环境启动两个进程、
    # status 按节点 fanout 时耗时翻倍（与上面 "比 pip show 快 30 倍" 的优化意图相悖）。
    local jwsw_ver
    jwsw_ver=$(python${YR_PYTHON_VERSION} -c "
from importlib.metadata import version, PackageNotFoundError
for pkg in ('workswarm', 'jiuwenswarm'):
    try:
        print(version(pkg))
        break
    except PackageNotFoundError:
        continue
" 2>/dev/null || true)
    [ -z "${jwsw_ver}" ] && jwsw_ver="-"

    # systemd 模式：枚举 gateway 和 web 两类 unit
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        local unit_file found=0
        for unit_file in /etc/systemd/system/jiuwenswarm-gateway*.service /etc/systemd/system/jiuwenswarm-web*.service; do
            [ -f "${unit_file}" ] || continue
            found=1
            local svc_name
            svc_name=$(basename "${unit_file}" .service)

            # gateway 类 unit 受 ExecStartPre VIP 门控（agentos-check-ingress-master）：
            # 本机为 master_nodes 成员但未持有 ingress VIP 时，unit 拒启进入 failed 属预期待命形态，
            # 应与 agent-gateway_status 一致判 n/a（不计数 failed、不拉高 RC），而非误报故障。
            if [[ "${svc_name}" == jiuwenswarm-gateway* ]]; then
                if ! command -v /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1 \
                    || ! /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1; then
                    echo "jiuwenswarm|${svc_name}|n/a|not ingress master"
                    continue
                fi
            fi

            local state detail
            if systemctl is-active --quiet "${svc_name}" 2>/dev/null; then
                state="running"
                detail="active"
            elif systemctl is-failed --quiet "${svc_name}" 2>/dev/null; then
                state="failed"
                detail="failed"
                rc=1
            else
                state="stopped"
                detail="inactive"
            fi
            echo "jiuwenswarm|${svc_name}|${state}|${detail}|${jwsw_ver}"
        done
        if [ "${found}" -eq 1 ]; then
            return ${rc}
        fi
        # 无 unit 文件，落入进程模式
    fi

    # 进程模式：pgrep 检测 jiuwenswarm-gateway 和 jiuwenswarm-web
    _jwsw_pids_of() {
        local pat="$1"
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f "${pat}" 2>/dev/null || true
        else
            ps -ef 2>/dev/null | grep "${pat}" | grep -v grep | awk '{print $2}' || true
        fi
    }

    local gw_pids web_pids gw_alive=0 web_alive=0
    gw_pids=$(_jwsw_pids_of 'jiuwenswarm-gateway')
    [ -n "${gw_pids}" ] && gw_alive=1
    web_pids=$(_jwsw_pids_of 'jiuwenswarm-web')
    [ -n "${web_pids}" ] && web_alive=1

    # gateway 状态
    if [ "${gw_alive}" -eq 1 ]; then
        echo "jiuwenswarm|jiuwenswarm-gateway|running|active|${jwsw_ver}"
    else
        echo "jiuwenswarm|jiuwenswarm-gateway|stopped|no process|${jwsw_ver}"
    fi

    # web 状态
    if [ "${web_alive}" -eq 1 ]; then
        echo "jiuwenswarm|jiuwenswarm-web|running|active|${jwsw_ver}"
    else
        echo "jiuwenswarm|jiuwenswarm-web|stopped|no process|${jwsw_ver}"
    fi

    return ${rc}
}
