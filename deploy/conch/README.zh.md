# Conch 部署补充说明：EROFS 内核模块

deploy/conch 的整体部署流程（模块编排、生命周期、RPM 安装顺序）见上级目录 [README.zh.md](../README.zh.md) 的 conch 模块说明。本文档补充：

1. agentos 部署包中 Conch 相关内容的构成
2. 部署包附带 erofs.ko 的约束与限制
3. erofs.ko 的生成方法与脚本用法

## 1. agentos 部署包中的 Conch 内容

`AgentOS-Server-<arch>.tgz` 解压后，Conch 相关文件位于包根目录（即部署脚本中的 `AGENTOS_ROOT`），与各 whl 包同级：

```text
AgentOS-Server/
├── <其他组件 whl 包>
├── erofs-utils-<版本>.<arch>.rpm      # mkfs.erofs 等 EROFS 镜像制作工具
├── stratovirt-<版本>.<arch>.rpm       # 沙箱使用的轻量虚拟机
├── conch-<版本>.<arch>.rpm            # conchd / conch CLI（RPM 内置 Python wheel）
├── virtiofsd-<版本>.<arch>.rpm        # openEuler 22.03 / Ubuntu 22.04 部署需要
├── oe2203/erofs.ko                    # openEuler 22.03 各版本的 EROFS 内核模块（见第 2 节）
├── oe2203sp1/erofs.ko
├── oe2203sp2/erofs.ko
├── oe2203sp3/erofs.ko
├── oe2203sp4/erofs.ko
└── deploy/
    └── conch/
        ├── module.sh                  # deploy 框架钩子
        ├── conch_deploy.sh            # install / up / down / uninstall / status
        ├── build-erofs-oe2203.sh      # erofs.ko 生成脚本（见第 3 节）
        └── README.zh.md               # 本文档
```

RPM 安装顺序及各操作系统差异（openeuler-2403/2203、ubuntu-2404/2204）见 `conch_deploy.sh -h`。

## 2. erofs.ko 约束与限制

openEuler 22.03 部分官方 5.10 内核未启用 `CONFIG_EROFS_FS`，Conch 依赖 EROFS 文件系统，因此 `conch_deploy.sh up` 启动 conchd 前会检查 EROFS 模块：

1. 模块已加载（`/proc/modules`）或 `modprobe erofs` 成功（内核自带模块或已内置，如 24.03，或用户已自行适配），直接继续启动，不改动系统
2. `modprobe` 报 `Module erofs not found` 时，从 `uname -r`（如 `5.10.0-216.0.0.115.oe2203sp4.aarch64`）识别 oe2203 后缀得到具体版本——LTS 为 `oe2203`，LTS-SP1~SP4 为 `oe2203sp1`~`oe2203sp4`——并打印识别结果
3. 从部署包根目录与 RPM 同级的同名目录取 `erofs.ko`，安装到 `/lib/modules/$(uname -r)/extra/` 并执行 `depmod`，再用 `modprobe erofs` 加载；`libcrc32c` / `lz4_decompress` 等模块依赖由 modprobe 经 modules.dep 自动解析
4. 加载成功后写 `/etc/modules-load.d/agentos-erofs.conf`（同时以 `# agentos: <内核版本>` 注释行记录安装过 ko 的内核，供 `uninstall` 清理），重启后由 systemd-modules-load 自动执行 `modprobe erofs`，conchd 开机自启不受影响；`up` 可重复执行
5. 安装后 `modprobe` 仍失败（如 Secure Boot 拒绝未签名模块、依赖模块缺失）时，回滚刚安装的 ko（本次新建的 `/lib/modules/<内核版本>` 目录一并删除）并报错（附 modprobe 输出与两侧内核版本），系统恢复到 `up` 前状态

### 示例 ko 的编译目标内核

部署包内五个目录的示例 `erofs.ko` 分别基于以下内核版本编译：

| 目录 | 对应 openEuler 版本 | 示例 ko 编译目标内核（aarch64） |
| --- | --- | --- |
| `oe2203` | 22.03 LTS | `5.10.0-60.139.0.166.oe2203.aarch64` |
| `oe2203sp1` | 22.03 LTS SP1 | `5.10.0-136.108.0.188.oe2203sp1.aarch64` |
| `oe2203sp2` | 22.03 LTS SP2 | `5.10.0-153.56.0.134.oe2203sp2.aarch64` |
| `oe2203sp3` | 22.03 LTS SP3 | `5.10.0-243.0.0.145.oe2203sp3.aarch64` |
| `oe2203sp4` | 22.03 LTS SP4 | `5.10.0-243.0.0.142.oe2203sp4.aarch64` |

x86_64 部署包的示例 ko 为同版本号的 `x86_64` 内核（如 `5.10.0-243.0.0.145.oe2203sp3.x86_64`）。

### 内核支持边界

SP3、SP4 官方内核从以下版本起已默认配置 `CONFIG_EROFS_FS=m`（边界已对照官方 ARM64 开发包 `.config` 确认）：

- SP3：`5.10.0-244.0.0.146.oe2203sp3` 起；上一版本 `5.10.0-243.0.0.145` 仍是最后一个默认关闭 EROFS 的版本
- SP4：`5.10.0-244.0.0.143.oe2203sp4` 起；上一版本 `5.10.0-243.0.0.142` 仍是最后一个默认关闭 EROFS 的版本

即 SP3/SP4 较新内核（244 及以后）的机器 `modprobe erofs` 直接成功，用不到附带的 ko；只有默认关闭 EROFS 的版本（如上表示例版本及更早）才需要插入 ko。

限制：

- 包内每个版本目录当前只包含上表示例内核版本编译的 `erofs.ko`。ko 与架构强绑定；内核版本兼容性由内核按符号 CRC（kABI）判定，openEuler 同 SP 流内 kABI 稳定，跨内核版本通常可直接加载，跨 SP 或 CRC 漂移时 `modprobe` 报不兼容（如 `Invalid module format`、`disagrees about version of symbol`），需按第 3 节重新生成并替换包内 ko
- 内核升级后需重新执行 `up` 为新内核重新安装 ko；同 SP 内通常无需重编，跨 SP 需重编
- aarch64 与 x86_64 的 ko 互不通用（部署包本身按架构分发）
- 附带 ko 机制仅针对 openEuler 22.03；Ubuntu 与 24.03 内核自带 EROFS 模块，无需附带

`up` 加载包内 ko 时写入系统的文件，`uninstall` 按 `/etc/modules-load.d/agentos-erofs.conf` 中记录的内核版本逐一清理；modprobe 直接成功的机器 `up` 零写入，`uninstall` 也不做清理，用户自行放入 `/lib/modules` 的 erofs.ko 不受影响：

- `/lib/modules/<内核版本>/extra/erofs.ko`
- `/lib/modules/<内核版本>/` 下 `modules.dep` 等 depmod 生成文件（随内核包重新生成）
- `/etc/modules-load.d/agentos-erofs.conf`（`# agentos:` 注释行不影响 systemd 读取）

## 3. erofs.ko 如何生成

生成脚本 `build-erofs-oe2203.sh` 位于本目录，支持为 openEuler 22.03 LTS / SP1~SP4 的 aarch64 / x86_64 官方 5.10 内核编译 EROFS 模块，完整参数说明见脚本 `--help`。

### 前置条件

- 编译机与目标机架构一致（仅支持原生编译，不支持交叉编译）；编译机运行的系统可以不同（如 24.03）
- 编译机安装依赖：

```bash
dnf install -y bash git gcc make binutils curl rpm rpm-build cpio tar python3 kmod
```

- 内核源码仓库（默认 `/home/kernel`，可用 `EROFS_SOURCE_REPO` 指定）：正式构建时仓库不存在会自动从 `https://atomgit.com/openeuler/kernel.git` 下载，已有仓库缺少目标 tag 时自动补拉；`--check` 预检查不下载源码，需事先备好本地仓库

### 使用步骤

1. 在目标机执行 `uname -r` 记录完整版本号（须含 RPM 发布号），例如 `5.10.0-216.0.0.115.oe2203sp4.aarch64`
2. 预检查（可选，校验版本格式与源码配置项，不下载、不编译）：

```bash
bash build-erofs-oe2203.sh --check 5.10.0-216.0.0.115.oe2203sp4.aarch64
```

3. 正式编译。无需设置环境变量，压缩等选项沿用目标内核开发包的实际配置：

```bash
bash build-erofs-oe2203.sh 5.10.0-216.0.0.115.oe2203sp4.aarch64
```

4. 产物位于独立构建目录（默认 `~/erofs-oe2203-builds/<完整版本号>.<随机后缀>/`），校验全部通过后目录内只保留 `erofs.ko`，临时文件自动清理；构建失败时显示末尾错误并清理本次构建目录
5. 将 `erofs.ko` 放入部署包根目录对应的 `<oe2203|oe2203sp1~sp4>/` 目录（替换示例 ko）后重新执行 `up`，模块被安装到 `/lib/modules` 并开机自动加载；直接在目标机 `insmod` 仅当次生效，重启后仍需重新执行 `up`

脚本会自动选择并下载与目标版本、架构完全匹配的官方 `kernel-devel` 开发包，构建后校验版本、架构、vermagic 与导入符号 CRC。
