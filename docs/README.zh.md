# AgentOS 文档

本目录是 AgentOS 的用户文档，按 Diátaxis 四类框架组织：Tutorial（教程）、How-to（操作指南）、Reference（参考）、Explanation（解释）。

- 中文文档位于 [zh/](zh/)（权威源），英文文档位于 [en/](en/)（跟随，目录结构对称）。
- 目录级深度文档仍保留在原处：[构建说明](../build/README.zh.md)、[构建说明 v2](../build/README-v2.zh.md)、[部署指南](../deploy/README.zh.md)。
- 各组件（agent-runtime、jiuwenswarm、agent-protocol）的专属文档见对应 submodule 仓库。

## 阅读建议

| 你想…… | 推荐入口 |
|--------|----------|
| 30 分钟在单机跑通 | [教程：快速开始](zh/tutorial/01-quick-start.md) |
| 构建自己的安装包 | [指南：构建安装包](zh/how-to/build-package.md) |
| 部署多机集群 | [指南：多机集群部署](zh/how-to/deploy-multi-node.md) |
| 扩展部署能力 | [指南：新增部署模块](zh/how-to/add-deploy-module.md) |
| 查命令用法 | [参考：agentos 命令](zh/reference/agentos-commands.md) |
| 查配置参数 | [参考：部署配置](zh/reference/cluster-config.md) |
| 理解架构设计 | [解释：部署架构](zh/explanation/architecture.md) |

## 文档分类

- **tutorial/**（教程）：带新手入门，"跟着我做一遍"，使用数字前缀表示推荐阅读顺序。
- **how-to/**（操作指南）：解决具体任务，"我要做 X 怎么做"，使用语义化名称。
- **reference/**（参考）：命令与配置的事实性描述，结构化、可检索。
- **explanation/**（解释）：讲清楚"为什么这样设计"，架构与设计决策。
