# AgentOS b050 构建脚本说明

`build/build-v2.sh` 用于打包 AgentOS b050 产品线交付产物。

## 产物清单

输出到 `build/dist/`，client 不区分架构打一个包，server 按 `${ARCH}` 打一个包：

| 产物 | 说明 |
|------|------|
| `AgentOS-Client.tgz` | 客户端 TUI（含全平台 jiuwenswarm_tui，不区分架构；daily/release 同逻辑） |
| `AgentOS-Server-${ARCH}.tgz` | 服务端（`deploy/` + jiuwenswarm + openyuanrong + a2x_registry wheels） |
| `AgentOS-Buildinfo.tgz` | 各部件构建信息汇总（收集 jiuwenswarm/openyuanrong/agent-protocol/conch/credential_router 各 archive 内名字含 buildinfo 关键字的文件，归入 `AgentOS-Buildinfo/` 目录后压缩；保留源文件时间戳，与 AgentOS-Server/Client 同级目录） |

脚本只在 linux 上运行（无交叉编译）。client 包内含 OBS 预编译的全平台 wheel（macosx/win/linux_aarch64/linux_x86_64），server 包仅 linux 平台。

## daily/release 共用 jiuwenswarm/openyuanrong/agent-protocol 获取逻辑

两个模式都从 OBS `last_successful_build` 下载 `archive.tar.gz` 解压取 wheel（和 jiuwenswarm 的 deploy），不再 git clone、不再逐包下载、不再依赖版本号/git tag/时间戳、不再逐小时探测。

### OBS archive 路径规则

```
jiuwenswarm:     https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/jiuwenswarm/package/<build_type>/<build_target>/last_successful_build/archive.tar.gz
openyuanrong:    https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/<build_type>/<build_target>/last_successful_build/archive.tar.gz
agent-protocol:  https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-protocol/package/<build_type>/<build_target>/last_successful_build/archive.tar.gz
conch:           https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/conch/package/<build_type>/<build_target>/last_successful_build/archive.tar.gz
```

- `<build_type>`/`<daily|release>` = `daily` 或 `release`
- `<build_target>` = `BUILD_TARGET`（默认 `agentos_b050`，可用 `--build-target=` 覆盖）

### archive.tar.gz 内部结构

pack 阶段按此取用：

**jiuwenswarm archive**：
```
archive/jiuwenswarm-*-py3-none-any.whl                        -> server 包（平台无关 wheel）
archive/<x86_64|aarch64>/jiuwenswarm_tui-*.whl                 -> client 包（不区分架构，两个目录下所有 jiuwenswarm_tui wheel 一并打入）
archive/deploy.tar.gz                                        -> 解压后取 deploy/yuanrong 合入 server 的 deploy/jiuwenswarm
```

**openyuanrong archive**：
```
archive/<x86_64|aarch64>/*.whl                  -> server 包（平台相关：openyuanrong/sdk/runtime/datasystem/functionsystem/faas）
archive/agent_dx_executor-*-py3-none-any.whl   -> server 包（平台无关，在 archive 根目录）
```

**agent-protocol archive**：
```
archive/a2x_registry-*-py3-none-any.whl   -> server 包（平台无关 wheel，在 archive 根目录）
```

**conch archive**：
```
archive/<x86_64|aarch64>/*.rpm   -> server 包（平台相关 rpm，按 ${ARCH} 取对应架构；必有）
archive/<x86_64|aarch64>/oe2203{,sp1~sp4}/erofs.ko -> server 包（openEuler 22.03 各版本 EROFS 内核模块，按 ${ARCH} 取对应架构；如有则一并打入）
archive/*.rpm                    -> server 包（平台无关 none rpm，在 archive 根目录；如有则一并打入）
```

**注意**：OBS 按 CPU 架构族归类，jiuwenswarm archive 的 `x86_64/` 目录还含 `win_amd64`、`aarch64/` 还含 `macosx_arm64`。client 包按用户要求不区分架构，两个目录下所有 `jiuwenswarm_tui-*.whl` 一并打入 `AgentOS-Client.tgz`（与 build.sh 一致，含 macosx/win/linux_aarch64/linux_x86_64 四平台）。

## daily 与 release 的唯一差异

- `BUILD_TYPE` 拼 OBS archive 路径（`daily` vs `release` 段）
- 四个 archive（jiuwenswarm/openyuanrong/agent-protocol/conch）路径里该段分别为 `daily`/`release`

## 命令行参数

统一 `--key=value` 形式（不支持位置参数和 `--key value` 空格形式）。

### 常用参数

| 参数 | 说明 |
|------|------|
| `--build-type=` | 必填，`daily` 或 `release` |
| `--build-target=` | 必填，交付产品线分支，拼 OBS archive 路径 |
| `-h, --help` | 显示帮助 |

### 示例

```bash
# daily
  ./build-v2.sh --build-type=daily

  # release
  ./build-v2.sh --build-type=release --build-target=agentos_b050

  # 指定目标架构 aarch64（x86_64 主机上出 aarch64 产物）
  ARCH=aarch64 ./build-v2.sh --build-type=release --build-target=agentos_b050
```

## ARCH 环境变量

`ARCH` 默认取执行机器 `uname -m`，可用环境变量覆盖以指定目标产物架构（如 `ARCH=aarch64`）。

脚本只下载对应 arch 的预编译 wheel 并打包，**无平台编译过程（不是交叉编译）**。client 包不区分架构（含全平台 jiuwenswarm_tui），server 包按 ${ARCH} 一次只出一个 arch；要出另一个 arch 的 server 包，再跑一次（设不同 `ARCH`）。

## 重构要点（相对原始 build.sh）

- jiuwenswarm release/daily 都改从 OBS archive 获取，删 git clone 和逐包下载
- openyuanrong release/daily 都改从 OBS archive 获取，删逐包下载和版本号/cp_tag 拼文件名逻辑
- agent-protocol/a2x_registry release/daily 都改从 OBS archive 获取，删逐小时探测（72h）和版本号拼文件名逻辑
- 删 `--jiuwenswarm-release-version` / `--jiuwenswarm-release-git-tag` / `--yuanrong-release-version` / `--yuanrong-daily-version` / `--yr-schedule-time` / `--yr-release-download-base` / `--cp-tag` 等死参数及相关死数组
- daily 删时间戳拼路径逻辑（`$(date +%Y%m%d)17`）和 yuanrong index 解析（`fetch_latest_yr_schedule_time`），jiuwenswarm/openyuanrong/agent-protocol 都改用 `last_successful_build`
- Client 包不区分架构，全平台 jiuwenswarm_tui 打到一起，命名同 build.sh 的 `AgentOS-Client.tgz`（原按 ${ARCH} 一次只出一个 linux 平台、带 `-TUI_${ARCH}` 后缀）
- 命令行统一 `--key=value` 形式，`BUILD_MODE` 重命名为 `BUILD_TYPE`
- archive 解压后删 `archive.tar.gz` 省磁盘空间
- tar 加 `--atime-preserve`、wheel cp 加 `-p` 保留原始 mtime 可回溯
- 随远端 client 迁移删除 `tui-launcher` 本地构建逻辑（`TUI_LAUNCHER_VERSION`/`TUI_LAUNCHER_PACKAGES`/`build_tui_launcher`），client 包不再包含 `agentos_tui_launcher`
- 新增 conch 沙箱模块：daily/release 都从 OBS archive 获取 rpm（平台相关按 `${ARCH}` 取 + 平台无关 none）与 erofs.ko 版本目录（openEuler 22.03 各版本，如有则一并打入），打入 server 包根目录与各 whl 同级
- 新增 credential_router：daily/release 都从 OBS archive 获取平台相关 `credential-router*.tar.gz`（按 `${ARCH}` 取 + 平台无关 none），打入 server 包根目录与各 whl/rpm 同级

## 依赖

- 本地目录：`deploy/`（server deploy 来源）
- 工具：`curl` 或 `wget`、`git`、`tar`
- 网络：访问 OBS（openjiuwen-ci、openyuanrong）

## 构建流程（main 顺序）

1. `clean` — 清空 `build/dist/`（含 downloads 和 staging）
2. `build_openyuanrong` — 下载并解压 OBS `archive.tar.gz`（openyuanrong wheels）
3. `build_jiuwenswarm` — 下载并解压 OBS `archive.tar.gz`（jiuwenswarm wheels + deploy）
4. `build_agent_gateway` — 下载并解压 OBS `archive.tar.gz`（a2x_registry wheel）
5. `build_conch` — 下载并解压 OBS `archive.tar.gz`（conch 沙箱模块 rpm：平台相关按 `${ARCH}` 取 + 平台无关 none；erofs.ko 版本目录如有则一并打入，均进 server 包根目录与各 whl 同级）
6. `build_credential_router` — 下载并解压 OBS `archive.tar.gz`（credential-router 平台相关 tar.gz）
7. `pack` — 组装 client/server 两个 tgz 产物
8. `collect_buildinfo` — 收集各部件 archive 内名字含 buildinfo 关键字的构建信息文件，以及 `build/` 目录顶层名字含 buildinfo 关键字的文件（agent-os 主仓 buildinfo 由 CI 流水线生成于此），到 `AgentOS-Buildinfo/` 目录，`cp -p` + `tar --atime-preserve` 保留源文件时间戳，压缩为 `AgentOS-Buildinfo.tgz`（与 AgentOS-Server/Client 同级；须在 pack 之后，pack 会清空 staging）

> agent-os 主仓 buildinfo 文件由 CI 流水线单独生成，放 `build/` 目录顶层（不受脚本 `clean` 影响，`clean` 只删 `build/dist/`）。`build-v2.sh` 不生成该文件，仅在 `collect_buildinfo` 阶段模糊匹配 `build/` 下所有含 `buildinfo` 关键字的文件纳入打包。

# v2版本日构建，release发布构建主要方案如下

# 1、AgentOS-Server打包逻辑，要解决的问题
- 1.1、当前总体打包要等待部件构建，耦合验证，要做到总体打包可以手动，定时触发各个部件CI出包，不依赖人
- 1.2、总体打包脚本硬编码太多路径适配，版本号等信息，每次改动总体打包要修改，+分，合入比较麻烦，出包效率低，要通过last_successful_build解耦

# 2、解决方案打包和组件打包的关系：
## 2.1、涉及到主线日构建/主线relase，分支日构建/release，都要支持日构建，release构建，手动临时构建
## 2.2、项目路径，分支切换，版本号变化，要无复杂脚本适配修改，要修改的只能通过CI构建的传参，禁止硬编码
## 2.3、需要支持一下特性
- 1、支持：定时出包，手动出包，成功的构建都放到：last_successful_build目录底下，触发之后先删除（***注意***，否则会导致拉去旧包），最后有产物之后再归档
- 2、解决方案触发11:00，17:00,5:00等定时触发各个组件构建，组件构建在obs归档编译产物，解决方案拉去各个last_successful_build归档编译产物
- 3、手动构建出包：通过解决方案手动点击，不定时间，组件构建在obs归档编译产物，解决方案拉去各个last_successful_build归档编译产物
- 4、各个部件也要支持定时出包，手动出包，区分日构建，release构建，构建的分支支持通过参数传递，禁止硬编码
- 5、部件编译目录时间戳到分钟例如：202608222314（年月日时分，其中：年占位4字符，其他月，日，时，分占位2字符）
- 6、部件编译启动首先清理last_successful_build，在例如部件目录：202608222314归档成功之后，拷贝一份全量文件到到archive目录，压缩成tar.gz文件，保留原始文件时间戳，把压缩archive.tar.gz上传到last_successful_build目录底下
- 6、部件编译归档${sub_module_name}_buildinfor文件信息，sub_module_name是各个部件名称，例如：jiuwenswarm

# 3、触发关系
```
AgentOS-Server日构建/release构建（定时或者手动启动之后）
  |会传递2个参数：build_target=agentos_b050(传给部件需要构建的产品分支名称，也是obs编译产物归档地址)，
  |另外一个参数：build_type=daily（如果是发布传release）
---------------------
jiuwenswarm yuanrong  agent-protocol 等部件CI工程
```

## 3.1、build_target和代码仓分支的关系
- 1、build_target业务含义就是要交付产品线分支意思，构建产物在obs此以build_target的值例如：agentos_b050为为目录结构归档
- 2、如果部件交付里程代码配套分支例如：agentos_b050，在CI构建编辑任务，流水线源里面可以配置分支（如：agentos_b050），注意到下个里程修改CI工程配置
- 3、如果部件每个里程都会创建对应分支例如：agentos_b050，部件编译通过git命令指定分支拉去代码，根据传入的agentos_b050值拉去分支代码，并且归档到以此对应obs目录，比较推荐的方式
- 4、如果部件只在一个分支上持续构建不换分支，build_target传入值agentos_b050只是obs归档里程碑打结作用
- 5、无论部件的代码仓，分支，版本号，代码Tag如何管理规划，各个部件的CI工程都要向build_target传入值例如：agentos_b050对应的obs目录里面归档archive.tar.gz编译产物

## 3.2、build_type=daily日构建/release发布构建关系
- 1、在${build_type}/${build_target}底下，根据具体日构建/release构建地下的交付产品线分支例如：agentos_b050底下归档

# 4、${sub_module_name}_buildinfor文件内容举例如下，主要为了方便版本追溯用，能够支撑排查分支错误，tag错误，PR是否漏合，构建的链接，构建参数，归档地方等
```
repository: https://gitcode.com/openJiuwen/jiuwenswarm.git,
branch: agent_os,
commit: ce21a9b7cfcce28923fba6c47758d60c624b69be,
pr:
build_url: 
build_env:
build_storage: obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/202608291035/

repository 代码仓信息
branch 分支信息
commit 当前构建checkout代码commit id
pr 合入的pr信息列表
build_url 构建连接
build_env 构建参数
build_storage 归档编译产物过程产物obs路径，注意：通过build_type和build_target拼接的
```

# 5、目录规则：
- 5.1、（下载共享）obs->组件->产物类型(package/报告/扫描等)->构建类型（daily/release构建）->交付产品线_版本(分支名)->last_successful_build（最新一次构建结果的全部打包archive.tar.gz）
- 5.2、（过程产物归档）obs->组件->产物类型(package/报告/扫描等)->构建类型（daily/release构建）->交付产品线_版本(分支名)->具体到分时间戳文件夹

# 6、各个部件目录规划
## 6.1、jiuwenswarm agentos B050构建规划
1、agentos_b050 obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/last_successful_build/archive.tar.gz (把最新202608271448构建里面x86_64，aarch64，deploy压缩到一起，命名为：archive.tar.gz)
obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/202608271448/x86_64/xxx.whl
obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/202608271448/aarch64/xxx.whl
obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/202608271448/deploy.tar.gz
obs://openjiuwen-ci/jiuwenswarm/package/daily/agentos_b050/202608271448/xxx.whl

2、agentos_b050 obs://openjiuwen-ci/jiuwenswarm/package/release/agentos_b050/last_successful_build/archive.tar.gz (把最新202608271448构建里面x86_64，aarch64，deploy压缩到一起，命名为：archive.tar.gz)
obs://openjiuwen-ci/jiuwenswarm/package/release/agentos_b050/202608271448/x86_64/xxx.whl
obs://openjiuwen-ci/jiuwenswarm/package/release/agentos_b050/202608271448/aarch64/xxx.whl
obs://openjiuwen-ci/jiuwenswarm/package/release/agentos_b050/202608271448/deploy.tar.gz
obs://openjiuwen-ci/jiuwenswarm/package/release/agentos_b050/202608271448/xxx.whl

```
过程产物归档例如：
202608271448
  |-archive
    |-x86_64
    | |-xxx_x86_64.whl
    | |-xxx_x86_64.whl
    | |-xxx_x86_64.whl
    |-aarch64
    | |-xxx_aarch64.whl
    | |-xxx_x86_64.whl
    | |-xxx_x86_64.whl
    |-xxx_none.whl
    |-deploy.tar.gz
 
```

```
下载共享产物archive.tar.gz归档例如：
archive
  |-x86_64
  | |-xxx_x86_64.whl
  | |-xxx_x86_64.whl
  | |-xxx_x86_64.whl
  |-aarch64
  | |-xxx_aarch64.whl
  | |-xxx_x86_64.whl
  | |-xxx_x86_64.whl
  |-xxx_none.whl
  |-deploy.tar.gz
tar -czf archive.tar.gz archive/ --atime-preserve，压缩之后上传到last_successful_build
```

下载路径固定
"https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/jiuwenswarm/package/${BUILD_TYPE}/${BUILD_TARGET}/last_successful_build"


## 6.2、yuanrong agentos B050构建计划归档成
1、releae： https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/release/agentos_b050/last_successful_build/archive.tar.gz
2、daily：  https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily/agentos_b050/last_successful_build/archive.tar.gz

```
archive.tar.gz解压出来文件应该是
archive
  |-aarch64
  | |-openyuanrong_datasystem-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
  | |-openyuanrong_faas-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
  | |-openyuanrong_functionsystem-9.9.9-py3-none-manylinux_2_34_aarch64.whl
  | |-openyuanrong_runtime-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
  | |-openyuanrong_sdk-9.9.9-cp311-cp311-manylinux_2_34_aarch64.whl
  | |-openyuanrong-9.9.9-py3-none-manylinux_2_34_aarch64.whl
  |-x86_64
  | |-openyuanrong_datasystem-9.9.9-cp311-cp311-manylinux_2_34_x86_64.whl
  | |-openyuanrong_faas-9.9.9-cp311-cp311-manylinux_2_34_x86_64.whl
  | |-openyuanrong_functionsystem-9.9.9-py3-none-manylinux_2_34_x86_64.whl
  | |-openyuanrong_runtime-9.9.9-cp311-cp311-manylinux_2_34_x86_64.whl
  | |-openyuanrong_sdk-9.9.9-cp311-cp311-manylinux_2_34_x86_64.whl
  | |-openyuanrong-9.9.9-py3-none-manylinux_2_34_x86_64.whl
  |-agent_dx_executor-9.9.9-py3-none-any.whl
  |

/daily/agentos_b050/
  |-202608281153
    |-archive
      | |-x86_64
      | |-aarch64
      | |-XXX.whl
  |-last_successful_build
    |-archive.tar.gz
    
    
    
/release/agentos_b050/
  |-202608281153
    |-archive
      | |-x86_64
      | |-aarch64
      | |-XXX.whl
  |-last_successful_build
    |-archive.tar.gz

#创建archive目录
mkdir archive

#拷贝不同平台whl包和deploy压缩文件到archive
cp -fr x86_64 aarch64 *.whl ./archive

#压缩archive.tar.gz文件，保持源文件时间，保证可追溯
tar -czf archive.tar.gz archive/ --atime-preserve
```


## 6.3、agent-protocol agentos B050构建计划
1、obs://openjiuwen-ci/agent-protocol/package/daily/agentos_b050/last_successful_build/archive.tar.gz
2、obs://openjiuwen-ci/agent-protocol/package/release/agentos_b050/last_successful_build/archive.tar.gz 

 
```
archive.tar.gz解压出来文件应该是
archive
  |-aarch64
  | |-XXX_aarch64.whl
  |-x86_64
  | |-XXX_x86_64.whl
  |-a2x_registry-0.3.3-py3-none-any.whl
  
#创建archive目录
mkdir archive

#拷贝不同平台whl包和deploy压缩文件到archive
cp -fr x86_64 aarch64 *.whl ./archive

#压缩archive.tar.gz文件，保持源文件时间，保证可追溯
tar -czf archive.tar.gz archive/ --atime-preserve
```


## 6.4、conch沙箱归档目录
1、obs://openjiuwen-ci/conch/package/daily/agentos_b050/last_successful_build/archive.tar.gz
2、obs://openjiuwen-ci/conch/package/release/agentos_b050/last_successful_build/archive.tar.gz

共享下载：
https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/conch/package/daily/agentos_b050/last_successful_build/archive.tar.gz
https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/conch/package/release/agentos_b050/last_successful_build/archive.tar.gz

```
daily和release编译的产品分支过程产物归档
/agentos_b050/
  |-202608281153
    |-archive
      |-x86_64
      | |-xxx_x86_64.rpm
      | |-oe2203、oe2203sp1~sp4（各含 erofs.ko）
      |-aarch64
      | |-xxx_aarch64.rpm
      | |-oe2203、oe2203sp1~sp4（各含 erofs.ko）
      |-XXX_.noarch.rpm
  |-last_successful_build
    |-archive.tar.gz
    
    
下载共享last_successful_build归档archive.tar.gz 
archive.tar.gz
  |-archive
    |-x86_64
    | |-xxx_x86_64.rpm
    | |-oe2203、oe2203sp1~sp4（各含 erofs.ko）
    |-aarch64
    | |-xxx_aarch64.rpm
    | |-oe2203、oe2203sp1~sp4（各含 erofs.ko）
    |-XXX_.noarch.rpm
```


## 6.5 credential_router归档目录
1、obs://openjiuwen-ci/credential_router/package/daily/agentos_b050/last_successful_build/archive.tar.gz
2、obs://openjiuwen-ci/credential_router/package/release/agentos_b050/last_successful_build/archive.tar.gz



```
daily和release编译的产品分支过程产物归档
/agentos_b050/
  |-202608281153
    |-archive
      |-x86_64
      | |-xxx
      |-aarch64
      | |-xxx
      |-XXX_none
  |-last_successful_build
    |-archive.tar.gz
    
    
下载共享last_successful_build归档archive.tar.gz 
archive.tar.gz
  |-archive
    |-x86_64
      | |-xxx
    |-aarch64
        | |-xxx
        |-XXX_none
```
