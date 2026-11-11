# 产业链与关键瓶颈

## 核心判断

可核实的主链是“DeepSeek API—扩展宿主—仓库配置—云端 Linux 容器/虚拟机—预构建与按量计费”：SLIPE 的潜在价值在于用 Flutter 跨端入口统一编排这些外部能力，关键依赖则是模型 token、扩展运行时、源码配置以及云计算和存储。上下文缓存与预构建分别改善重复输入的成本/响应和环境启动，但仍留下 token、Actions 分钟及模板存储费用，因此免费排队只能限制在制并发，必须与空闲停机、存储回收、配额和支出上限联动。[1][2][3][5][6]

VS Code 扩展需要区分 Node.js 与浏览器运行时、UI 与 workspace 运行位置；SLIPE 官方移植应逐插件适配和验收，而不应承诺全量插件直接运行。[3][4]

## 关键环节、价值与依赖

| 环节 | 已核实机制 | 对 SLIPE 的价值与依赖 |
|---|---|---|
| 模型 API | DeepSeek 按输入、输出 token 计费，缓存命中与未命中的输入价格不同。其当前价格页列示，deepseek-flash 高峰时段每百万输入 token 的缓存命中价为 0.006 美元、未命中价为 0.30 美元，输出为 1.20 美元；页面同时提示价格可能调整。[1] | SLIPE 可将稳定的系统提示和重复仓库上下文放在相同前缀中，并监控缓存命中/未命中 token；但模型价格、上下文窗口、并发额度和 API 可用性均是外部依赖，不能把缓存视为固定折扣。[1][2] |
| 编辑器内核与扩展 | VS Code 的扩展宿主可位于本地、浏览器或远程容器；本地和远程宿主使用 Node.js，Web 宿主使用 Browser WebWorker。Web 扩展保留 VS Code API 访问，但不能使用 Node.js API 和模块加载，并受浏览器沙箱限制。[3][4] | 跨端 UI 不等于扩展运行时兼容。自建生态应先定义稳定的 SLIPE API，再按“纯贡献点、浏览器可运行、必须 Node.js、依赖本地设备/UI”分类移植 VS Code 扩展；每一类需要不同适配层和测试范围。 |
| 源码托管与云环境 | Codespaces 可从仓库的分支或提交创建，仓库中的配置文件可形成可重复环境；每个 codespace 由 GitHub 托管在虚拟机上的 Docker 容器中，远程环境为 Linux，可从浏览器、VS Code 或 GitHub CLI 连接。[5] | SLIPE 的跨端入口可屏蔽本地操作系统差异，把项目配置、源码版本和云端会话连接起来；代价是依赖仓库访问权限、配置质量、Linux 工具链和外部云环境，而非仅靠 Flutter UI 就能完成云开发。 |
| 构建与启动加速 | 预构建按仓库、分支和 devcontainer 配置组装环境主要组件，大型或复杂仓库可更快创建 codespace；预构建工作流消耗 Actions 分钟，模板还按仓库和区域占用存储。[6] | SLIPE 可用预构建降低排队后的环境启动等待，但需把构建触发频率、模板大小、部署区域和旧版本保留数纳入成本治理，不能把“缓存”直接等同于净节省。[6] |
| 计费与支付责任 | Codespaces 可由组织、企业或个人账户支付；计算和存储按美元月结，并使用账户现有支付方式。个人账户额度用尽后，未配置支付方式和支出上限会阻止继续使用。[6] | SLIPE 必须显式区分“用户自带云账户”和“SLIPE 承担算力”两种账务路径。免费获客模式下应记录每个会话的资源归属、额度、超额和支付责任，不能把上游个人免费额度当作自身可持续补贴。 |

## 从源码到运行的成本传导

```visual
type: chain
title: 源码托管到云端构建与运行的成本传导
source: [6]
item: 仓库、分支与 devcontainer 配置 | 预构建按这一组合组装环境主要组件 | 项目配置需要版本化并纳入缓存键
item: Actions 预构建工作流 | 创建和更新消耗 Actions 分钟，不产生 Codespaces 计算费 | 启动加速仍产生构建成本
item: 预构建模板存储 | 费用受模板大小、区域数和保留版本数影响 | 需要区域选择与版本回收策略
item: Codespace 运行与留存 | 活跃时产生计算费，实例存续期间产生存储费 | 排队之外还需要停机和删除策略
```

## 免费队列、资源共享与自主算力的控制点

- **队列只控制并发，不是每日成本封顶。** Codespaces 在活跃时按机器核数和使用时长计计算费，停止后的实例仍可能计存储费；2 核机器列示为每小时 0.18 美元，存储为每 GB-month 0.07 美元。SLIPE 的免费层除排队外，还应设置单用户与全局并发、任务超时、空闲自动停止、环境保留期限和每日预算熔断，并分别监控核心小时与 GB-month。[6]
- **资源共享要同时核算峰值体验和闲置资产。** 当前资料没有证明共享或自主算力必然比按量云便宜。SLIPE 应先用实测的任务时长、峰谷利用率、构建等待、存储占用和运维投入比较外部按量、共享池与自有节点，只有在目标利用率和服务等级下单位任务成本更低时才扩大自有算力；这是一项待验证经营假设，而非已确认节省。
- **模型缓存和构建缓存需要分开度量。** DeepSeek 的磁盘上下文缓存只识别从第 0 个 token 开始的相同前缀，并按实际命中计费，不保证全部命中；Codespaces 预构建则把部分等待转化为 Actions 与模板存储成本。两者应分别跟踪模型缓存命中 token、每任务模型费用、预构建命中后的启动时间、Actions 分钟和模板 GB-month，避免用一个“缓存命中率”掩盖不同成本。[2][6]
- **降级路径应保住本地编辑。** 当免费队列满、预算熔断或外部 API 不可用时，跨端产品仍应明确区分可本地完成的编辑/同步与必须云端完成的模型、构建任务；云端不可用时的排队等待和功能降级需要进入产品验收，而不能只考核平均算力成本。

> 资料边界：公开页面能够核实上游机制和第三方价格，但未提供 SLIPE 的真实任务量、云账单、自有算力利用率、分发渠道及支付实现，因此本文不计算其单位任务成本，也不断言资源共享或自主算力已经能够摊薄成本；第三方价格仅用于说明成本结构，不是 SLIPE 的确定采购价。

## 参考资料

1. [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) — DeepSeek API Docs，日期不详
2. [DeepSeek API introduces Context Caching on Disk, cutting prices by an order of magnitude](https://api-docs.deepseek.com/news/news0802/) — DeepSeek API Docs，日期不详
3. [Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host) — Microsoft Visual Studio Code，2026-11-04
4. [Web Extensions](https://code.visualstudio.com/api/extension-guides/web-extensions) — Microsoft Visual Studio Code，日期不详
5. [What are GitHub Codespaces?](https://docs.github.com/en/codespaces/about-codespaces/what-are-codespaces) — GitHub Docs，日期不详
6. [About billing for GitHub Codespaces](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces) — GitHub Docs，日期不详
