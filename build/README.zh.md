# AgentOS 构建说明

`build.sh` 用于下载 JiuwenSwarm、openYuanrong、agent-gateway 依赖包，并与 `deploy/` 目录一起打包为可分发的 tar 包。

支持两种构建模式：

- **daily**（默认）：从 OBS 拉取每日构建产物
- **release**：从 gitcode / OBS release 路径拉取固定版本发布包

## 前置条件

- Bash 4.3+（并行下载使用 `wait -n`）
- `curl` 或 `wget`
- 可访问外网（华为云 OBS、gitcode.com）

## 使用方法

```bash
./build/build.sh [daily|release] [options]
```

常用示例：

```bash
# 每日构建（默认）
./build/build.sh
./build/build.sh daily

# 发布包构建
./build/build.sh release
./build/build.sh release --cp-tag cp311 --yuanrong-release-version 0.9.0 --jiuwenswarm-release-version 0.2.2 --jiuwenswarm-release-git-tag JiuwenSwarm0.2.2

# 指定 yuanrong 每日构建时间、包版本，降低并行数（网络不稳定时）
./build/build.sh daily --yr-schedule-time 202607101255 --yuanrong-daily-version 9.9.9 --download-jobs 1
```

查看全部参数：

```bash
./build/build.sh --help
```

## 构建参数

| 参数 | 命令行选项 | 默认值 | 说明 |
|------|-----------|--------|------|
| 构建模式 | `daily` / `release` | `daily` | 每日构建或发布包 |
| Python ABI | `--cp-tag` | `cp311` | yuanrong wheel 的 cp tag |
| 架构 | （脚本内 `ARCH`） | `uname -m` | 影响 openyuanrong 包路径、wheel 文件名与服务端 tar 包名 |
| yuanrong 发布版本 | `--yuanrong-release-version` | `0.9.0` | 仅 `release` 模式 |
| jiuwenswarm 发布版本 | `--jiuwenswarm-release-version` | `0.2.2` | 仅 `release` 模式，wheel 文件名中的版本号 |
| jiuwenswarm release git tag | `--jiuwenswarm-release-git-tag` | `JiuwenSwarm0.2.2` | 仅 `release` 模式，对应 `JIUWENSWARM_RELEASE_GIT_TAG` |
| yuanrong 每日包版本 | `--yuanrong-daily-version` | `9.9.9` | 仅 `daily` 模式，wheel 文件名中的版本号 |
| yuanrong 每日构建时间 | `--yr-schedule-time` | 自动获取 | 仅 `daily` 模式，OBS 路径中的时间戳 |
| yuanrong release 下载路径 | `--yr-release-download-base` | 自动拼接 | 仅 `release` 模式，对应 `YR_RELEASE_DOWNLOAD_BASE` |
| 并行下载数 | `--download-jobs` | `3` | 同时下载的最大文件数 |
| agent-gateway 版本 | （脚本内 `REGISTRY_RELEASE_TAG` / `REGISTRY_WHL_VERSION` / `RQLITE_VERSION`）| 见 `build.sh` 顶部 | 无命令行选项 |
也可在 `build.sh` 顶部 `# build parameters` 区域直接修改默认值。

## 构建流程

| 步骤 | 函数 | 说明 |
|------|------|------|
| 1 | `parse_args` | 解析命令行参数 |
| 2 | `configure_build` | 按模式生成下载 URL 与包列表 |
| 3 | `clean` | 清理 `build/dist/` |
| 4 | `build_openyuanrong` | 下载 openYuanrong 包 |
| 5 | `build_jiuwenswarm` | clone jiuwenswarm 源码并下载 wheel 包 |
| 6 | `build_agent_gateway` | 下载 agent-gateway 依赖包 |
| 7 | `pack` | 打包 `AgentOS-Client.tgz` 与 `AgentOS-Server-${ARCH}.tgz` |

任一步骤失败时，脚本会因 `set -e` 立即退出。

## daily 模式

### JiuwenSwarm

- wheel 版本号：`YYYYMMDD02`（当天日期 + `02`）
- 源码分支：`develop`（clone 到 `build/dist/downloads/jiuwenswarm_src/`）
- wheel 来源：`https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/jiuwenswarm/package/daily/dist/<version>/`

| 文件 |
|------|
| `jiuwenswarm-<version>-py3-none-any.whl` |
| `jiuwenswarm_tui-<version>-py3-none-linux_aarch64.whl` |
| `jiuwenswarm_tui-<version>-py3-none-linux_x86_64.whl` |
| `jiuwenswarm_tui-<version>-py3-none-win_amd64.whl` |
| `jiuwenswarm_tui-<version>-py3-none-macosx_11_0_arm64.whl` |

### openYuanrong

- 包版本（`yr_ver`）：默认 `9.9.9`，可通过 `--yuanrong-daily-version` 修改
- 构建时间（`yr_schedule_time`）：
  - 默认从 [daily build 索引页](https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/index.html) 解析 **openeuler** 区块下最新的 `Build Number`
  - 也可通过 `--yr-schedule-time` 手动指定，如 `202607101255`
- 来源：`https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/<yr_schedule_time>/openeuler/<arch>/`

| 文件 |
|------|
| `openyuanrong-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl` |
| `openyuanrong_sdk-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_runtime-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_datasystem-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_functionsystem-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl` |
| `openyuanrong_faas-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |

## release 模式

### JiuwenSwarm

- wheel 版本：默认 `0.2.2`，可通过 `--jiuwenswarm-release-version` 修改
- release git tag：默认 `JiuwenSwarm0.2.2`，可通过 `--jiuwenswarm-release-git-tag` 修改（对应构建参数 `JIUWENSWARM_RELEASE_GIT_TAG`）
- 源码 clone：按 `JIUWENSWARM_RELEASE_GIT_TAG` checkout 到 `build/dist/downloads/jiuwenswarm_src/`
- wheel 来源：`https://gitcode.com/openJiuwen/jiuwenswarm/releases/download/<release_git_tag>/`
- 打包时，`jiuwenswarm_src/deploy/yuanrong/` 会拷贝到 `AgentOS-Server-${ARCH}.tgz` 的 `deploy/jiuwenswarm/`（供 `deploy/jiuwenswarm/module.sh` 调用）

| 文件 |
|------|
| `jiuwenswarm-<version>-py3-none-any.whl` |
| `jiuwenswarm_tui-<version>-py3-none-macosx_11_0_arm64.whl` |
| `jiuwenswarm_tui-<version>-py3-none-win_amd64.whl` |

### openYuanrong

- 版本：默认 `0.9.0`，可通过 `--yuanrong-release-version` 修改
- 下载路径：默认 `https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/release/<version>/openeuler/<arch>/`，可通过 `--yr-release-download-base` 覆盖（`YR_RELEASE_DOWNLOAD_BASE`）

| 文件 |
|------|
| `openyuanrong-<version>-py3-none-manylinux_2_34_<arch>.whl` |
| `openyuanrong_sdk-<version>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_runtime-<version>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_datasystem-<version>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |
| `openyuanrong_functionsystem-<version>-py3-none-manylinux_2_34_<arch>.whl` |
| `openyuanrong_faas-<version>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl` |

## 下载机制

- **并行下载**：同一模块内多个 wheel 并行拉取，并发数由 `--download-jobs` 控制（默认 3）
- **断点续传**：使用 `.part` 临时文件，curl `-C -` / wget `-c` 支持续传
- **自动重试**：单文件最多重试 5 次，递增等待
- **跳过已存在**：本地已有同名文件时输出 `skip (exists)`
- **静默下载**：curl 使用 `--no-progress-meter`，不显示进度条

下载与源码保存在：

```
build/dist/downloads/jiuwenswarm/       # wheel 包
build/dist/downloads/jiuwenswarm_src/   # jiuwenswarm git 源码
build/dist/downloads/openyuanrong/      # openyuanrong wheel 包
build/dist/downloads/agent-gateway/     # 注册中心 wheel、rqlite rpm
```

## 输出产物

产物位于 `build/dist/`：

### `AgentOS-Client.tgz`

客户端 TUI 包：

| 模式 | 包含内容 |
|------|----------|
| daily | macOS / Windows / linux aarch64 / linux x86_64 共 4 个 TUI wheel |
| release | macOS / Windows 共 2 个 TUI wheel |

### `AgentOS-Server-${ARCH}.tgz`

服务端包，文件名随构建机器架构变化，例如 `AgentOS-Server-x86_64.tgz`、`AgentOS-Server-aarch64.tgz`（`ARCH` 来自 `uname -m`）。包含：

- `jiuwenswarm-<version>-py3-none-any.whl`
- 上述 openYuanrong wheel（daily 6 个 / release 6 个）
- agent-gateway 依赖包（注册中心 wheel、rqlite rpm）
- `deploy/` 目录（来自仓库 `deploy/`）
- `deploy/jiuwenswarm/` 部署脚本（来自 `jiuwenswarm_src/deploy/yuanrong/`，与仓库 `deploy/jiuwenswarm/` 合并）

## 目录结构示例

### 构建工作区

```
build/
├── build.sh
├── README.zh.md
└── dist/
    ├── AgentOS-Client.tgz
    ├── AgentOS-Server-<arch>.tgz   # 如 AgentOS-Server-x86_64.tgz
    ├── downloads/
    │   ├── jiuwenswarm/        # wheel 包
    │   ├── jiuwenswarm_src/    # jiuwenswarm git 源码
    │   └── openyuanrong/
    └── staging/          # 打包中间目录，可忽略
        ├── client/
        └── server/
```

### `AgentOS-Server-${ARCH}.tgz` 解压后结构

#### daily 模式

`<jw_ver>` = `YYYYMMDD02`，`<yr_ver>` 默认 `9.9.9`（`--yuanrong-daily-version`），`<arch>` = `uname -m`，`<cp_tag>` 默认 `cp311`。

```
AgentOS-Server/
├── jiuwenswarm-<jw_ver>-py3-none-any.whl
├── openyuanrong-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl
├── openyuanrong_sdk-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_runtime-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_datasystem-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_functionsystem-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl
├── openyuanrong_faas-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
└── deploy/
    ├── agentos.sh
    ├── deploy.sh
    ├── README.zh.md
    ├── jiuwenswarm/
    │   ├── deploy.sh           # 来自 jiuwenswarm_src/deploy/yuanrong/
    │   ├── ...                 # 来自 jiuwenswarm_src/deploy/yuanrong/
    │   ├── module.sh           # 来自 agentos/deploy/jiuwenswarm/
    │   └── .env.custom
    └── yuanrong/
        ├── module.sh
        └── yuanrong_deploy.sh
```

示例（`jw_ver=2026071002`，`arch=aarch64`，`cp_tag=cp311`）：

```
AgentOS-Server/
├── jiuwenswarm-2026071002-py3-none-any.whl
├── openyuanrong-9.9.9-py3-none-manylinux_2_34_aarch64.whl
├── openyuanrong_sdk-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_runtime-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_datasystem-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_functionsystem-9.9.9-py3-none-manylinux_2_34_aarch64.whl
├── openyuanrong_faas-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
└── deploy/
    └── ...
```

#### release 模式

`<jw_ver>` 默认 `0.2.2`，`<yr_ver>` 默认 `0.9.0`。

```
AgentOS-Server/
├── jiuwenswarm-<jw_ver>-py3-none-any.whl
├── openyuanrong-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl
├── openyuanrong_sdk-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_runtime-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_datasystem-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
├── openyuanrong_functionsystem-<yr_ver>-py3-none-manylinux_2_34_<arch>.whl
├── openyuanrong_faas-<yr_ver>-<cp_tag>-<cp_tag>-manylinux_2_34_<arch>.whl
└── deploy/
    ├── agentos.sh
    ├── deploy.sh
    ├── README.zh.md
    ├── jiuwenswarm/
    │   ├── deploy.sh           # 来自 jiuwenswarm_src/deploy/yuanrong/
    │   ├── ...                 # 来自 jiuwenswarm_src/deploy/yuanrong/
    │   ├── module.sh           # 来自 agentos/deploy/jiuwenswarm/
    │   └── .env.custom
    └── yuanrong/
        ├── module.sh
        └── yuanrong_deploy.sh
```

示例（默认版本，`arch=aarch64`，`cp_tag=cp311`）：

```
AgentOS-Server/
├── jiuwenswarm-0.2.2-py3-none-any.whl
├── openyuanrong-0.9.0-py3-none-manylinux_2_34_aarch64.whl
├── openyuanrong_sdk-0.9.0-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_runtime-0.9.0-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_datasystem-0.9.0-cp311-cp311-manylinux_2_34_aarch64.whl
├── openyuanrong_functionsystem-0.9.0-py3-none-manylinux_2_34_aarch64.whl
├── openyuanrong_faas-0.9.0-cp311-cp311-manylinux_2_34_aarch64.whl
└── deploy/
    └── ...
```

`build/dist/` 已加入 `.gitignore`，不会提交到 Git。

## 下载失败时的报错

失败时终端会输出：

1. 正在下载的文件名与 URL
2. `curl` / `wget` 原始错误（如 HTTP 404、`transfer closed`）
3. 重试信息：`retry (n/5): <文件名>`
4. 汇总错误：`error: failed to download <文件名>` 及 `url:`

若下载到空文件，会报：`error: downloaded file is empty: <文件名>`。

## 常见问题

**并行下载大文件时出现 `curl: (18) transfer closed`**

OBS 大包（如 `openyuanrong_runtime`）并行过多时容易断连。可降低并发：

```bash
./build/build.sh daily --download-jobs 1
```

**怀疑本地 wheel 已损坏，想重新下载**

脚本每次构建会 `clean` 整个 `build/dist/`。若中途中断，可手动删除损坏文件：

```bash
rm -f build/dist/downloads/openyuanrong/*.part
```

**打包时报 `deploy directory not found`**

确认仓库根目录存在 `deploy/` 目录。

**手动指定 yuanrong 每日构建时间**

在 [daily build 索引页](https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/index.html) 查找 openeuler 区块下最新的 `Build Number` 后：

```bash
./build/build.sh daily --yr-schedule-time 202607101255
```

**手动指定 yuanrong 每日包版本**

daily 构建的 wheel 文件名版本号（如 `openyuanrong-9.9.9-...`）可通过：

```bash
./build/build.sh daily --yuanrong-daily-version 9.9.9
```

或在 `build.sh` 顶部修改 `YUANRONG_DAILY_VERSION`。

**手动指定 jiuwenswarm release git tag**

wheel 版本号（`--jiuwenswarm-release-version`）与 release git tag（`--jiuwenswarm-release-git-tag` / `JIUWENSWARM_RELEASE_GIT_TAG`）可能不同，例如：

```bash
./build/build.sh release \
  --jiuwenswarm-release-version 0.2.2 \
  --jiuwenswarm-release-git-tag JiuwenSwarm0.2.2
```

或在 `build.sh` 顶部修改 `JIUWENSWARM_RELEASE_GIT_TAG`。

**手动指定 yuanrong release 下载路径**

适用于jiuwenswarm是release包而yuanrong是daily包的情况。

```bash
./build.sh release --jiuwenswarm-release-version 0.2.3 \
                   --jiuwenswarm-release-git-tag release_0.2.3 \
                   --yuanrong-release-version 9.9.9 \
                   --yr-release-download-base https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/202607132210
```

未指定时，默认拼接为 `release/<version>/openeuler/<arch>`。
