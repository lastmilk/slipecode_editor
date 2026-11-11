# 重点企业研究

## 核心判断

代表产品已经形成四种不同竞争单元：Microsoft 以免費桌面编辑器和扩展 API 守住通用开发入口，Cursor 把 Agent、云端自动化和团队治理打包为订阅，Replit 收费重点是集成工作区、AI 应用构建及移动应用交付，DeepSeek 则按 token 提供模型与工具调用能力。SLIPE 不宜把它们都视为“另一种编辑器”并正面复制；更可行的位置是以 Flutter 跨端一致性、轻量编辑和同步为入口，把云算力、模型与插件兼容做成边界清楚的适配层。

下表价格与功能均为 2026-11-12 页面所列，仅用于比较当前产品与收费方式，不代表近 30 日新增功能，也不支持市场份额、收入或活跃用户排名。

| 代表主体 | 行业位置与产品路线 | 已核实商业化方式 | 跨端、云端与生态边界 | 对 SLIPE 的直接启示 |
|---|---|---|---|---|
| Microsoft / VS Code | 免费通用桌面代码编辑器，覆盖调试、任务和版本控制，并将 Copilot 与第三方 AI 扩展纳入编辑体验[1] | 编辑器可供私人或商业免费使用；AI 可使用 Copilot 免费/付费计划，也可自带模型密钥[1] | 支持 Windows、macOS、Linux；Code-OSS 采用 MIT 许可，但 Microsoft 发行版另有产品许可并包含 Marketplace 集成等专有部分；稳定扩展 API 保持向后兼容[1] | 插件移植应按许可证、API、运行时与分发渠道逐项验收，不能把 Code-OSS 或稳定 API 等同于全部 VS Code 插件可直接运行 |
| Cursor | AI 原生编辑器，以 Agent 为核心，并向云端 Agent、自动化、代码审查和团队协作延伸[2] | 免费档为 0 美元/月；高级版 30 美元/月，团队版 30 美元起/用户/月，企业版定制；第三方模型用量另按 API 标价计费[2] | 高级版起提供云端 Agent 与自动化；团队及企业档提供集中计费、隐私控制，以及内部规则、技能和插件应用市场[2] | 竞争基准已是完整 Agent 工作流和团队治理，而非单次补全；SLIPE 应优先保证跨端任务连续性、透明额度和模型费用，而非盲目扩张模型与功能数量 |
| Replit | 一体化工作区与 AI 应用构建服务，并向原生移动应用开发、预览和发布流程延伸[3][4] | Core 月付 20 美元/月、年付折算 18 美元/月；Pro 月付 100 美元/月、年付折算 90 美元/月；Enterprise 定制。Core 和 Pro 分别包含 20 美元、100 美元模型额度[3] | 官方将原生移动应用列为独立 artifact，文档覆盖模拟器/仿真器预览、Expo Go、发布流程及客户端—服务器架构[4] | Replit 的竞争单元是从描述到应用交付；SLIPE 应以轻量编码、既有项目同步和可控免费队列错位竞争，而不是先复制完整应用生成与发布链 |
| DeepSeek | 模型与开发能力供应层，通过 OpenAI/Anthropic 格式 API、工具调用、Responses API 等支撑编码 Agent，而非完整桌面 IDE[5] | 按输入、输出 token 及 Search/Fetch 请求计费；模型价格区分缓存命中、缓存未命中及峰时/非峰时，非峰时模型价格为峰时的一半[5] | deepseek-flash 与 deepseek-v4-pro 均支持工具调用；FIM 补全仅在非思考模式提供。DeepSeek Harness 连接器则属于独立社区项目，不是 DeepSeek 官方发布或背书的产品[5][6] | 可延迟的免费云任务可利用非峰时价格，但模型 token 费与云算力费必须分别计量；Harness 兼容需要版本化适配与安全授权设计，不能预设官方稳定插件接口 |

## 企业简析

### Microsoft / VS Code：通用入口与扩展标准

VS Code 将自身定位为精简代码编辑器，核心编辑无需账号，桌面覆盖 Windows、macOS 和 Linux。免费编辑器降低入口门槛，Copilot 免费及付费计划、组织订阅和自带模型密钥构成多层次 AI 供给；Copilot 后端服务仍保持闭源[1]。

其生态优势不仅来自扩展数量，也来自稳定 API 的向后兼容，以及 Language Model、Tools、Shell Execution 等面向 AI 扩展的接口。与此同时，Microsoft 明确区分 MIT 许可的 Code-OSS 与包含专有资产、Marketplace 集成及部分远程开发能力的正式发行版[1]。因此，SLIPE 官方移植主流插件时，应建立“许可证允许—所需 API 已实现—扩展宿主与节点依赖可用—分发权限明确”的四项验收，不宜宣传全量兼容。

### Cursor：Agent 工作流订阅化

Cursor 的价格页显示，其产品商业化以共享 AI 用量池为核心：免费档提供有限 Agent 与聊天请求，高级版增加云端 Agent、自动化、代码托管和 AI 代码审查，Super 与 Ultra 继续提高用量；第三方模型不包含在订阅额度内，而是按 API 标价另行计费。团队和企业层再加入集中计费、用量分析、统一隐私设置、SSO、支出控制与审计等治理能力[2]。

这说明 AI IDE 的付费点已经从编辑器本体转向 Agent 用量、自动化和组织控制。SLIPE 的免费云开发若要形成可信差异，应把每次任务可用模型、排队位置、配额、超时、取消和超额费用写清楚；仅靠“免费”无法替代 Cursor 已提供的端到端工作流，但跨端连续任务与可预期成本可以成为独立比较维度。

### Replit：集成工作区与移动应用交付

Replit 的 Core 和 Pro 将订阅与模型额度组合，Pro 还面向商业及专业构建增加协作、支持和数据库恢复能力，企业档提供 SSO、SCIM、审计日志、隐私控制及私有网络选项[3]。原生移动应用文档则把开发流程扩展到模拟器或仿真器预览、Expo Go、发布和客户端—服务器架构，表明其目标并非单纯在浏览器中编辑代码，而是覆盖应用交付过程[4]。

对 SLIPE 而言，Replit 的边界同样重要：移动应用构建、签名、预览和商店发布是一条重服务链，不会因 Flutter 跨端界面一致而自动获得。近期更合理的比较指标应是项目打开与同步耗时、跨端编辑一致性、云任务完成率和单位任务成本，而不是功能列表总量。

### DeepSeek 与 Harness 社区连接器：模型供应和会话复用

DeepSeek 官方 API 当前列出 deepseek-flash 与 deepseek-v4-pro，提供 OpenAI 与 Anthropic 两种接口格式、工具调用和 Responses API；两者上下文长度均标为 1M，FIM 补全则限定在非思考模式。价格按每百万 token 计，且缓存状态、输入/输出、模型和峰谷时段均影响费用，Search 与 Fetch 还按成功请求单独收费[5]。因此，SLIPE 做免费队列时不能只设并发上限，还需按任务记录模型 token、检索请求与云运行资源，分别设置预算熔断。

Open VSX 上的 DeepSeek Harness Connector 已提供实际客户端形态：连接本机已有 `dsh web`，在 VS Code 中延续同一工作区和会话，并处理审批、问题及差异审查；页面显示 4.2K 下载，版本要求为 VS Code 1.85 及以上，且 Harness 必须与 VS Code 窗口位于同一机器[6]。这证明“浏览器—编辑器共享 Agent 会话”已有可运行实现，但下载量不能外推为活跃用户或收入。

该连接器明确声明为独立、非官方社区项目，Open VSX 还提示发布账号未获对应命名空间验证。其默认 `auto` 模式可能读取同时保存模型 API 密钥的 `$DSH_HOME/.credentials.yaml`；页面提供的 `managed` 和 `paste` 模式则通过启动流程或每次进程令牌避免读取该文件[6]。SLIPE 若兼容 Harness，应锁定已测试的 Harness 与连接器版本，优先采用 `managed`/`paste` 所代表的最小权限授权路径，并把会话协议、审批、差异和撤销能力列为兼容测试项。

> 资料边界：DeepSeek 官方 API 页面未提供 Harness 的归属、插件规模或兼容承诺，现有连接器又明示非官方，因此不能把 DeepSeek Harness 描述为 DeepSeek 官方插件市场，也不能据此假设其接口长期稳定。

## 参考资料

1. [Visual Studio Code FAQ](https://code.visualstudio.com/docs/supporting/FAQ) — Microsoft，日期不详
2. [Cursor 定价](https://cursor.com/cn/pricing) — Cursor，日期不详
3. [Pricing](https://replit.com/pricing) — Replit，日期不详
4. [Native Mobile Apps](https://docs.replit.com/features/artifact-types/building-mobile-apps) — Replit，日期不详
5. [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) — DeepSeek，日期不详
6. [DeepSeek Harness Connector](https://open-vsx.org/extension/lucasliang/harness-connector-deepseek) — YichuAI（Open VSX），日期不详
