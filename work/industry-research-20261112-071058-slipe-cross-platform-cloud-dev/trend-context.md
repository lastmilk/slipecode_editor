# 宏观与政策环境（macro.md）

## 核心判断
对 SLIPE 最实质的外部约束不是“免费云开发”的定价，而是账号同步、云端构建和 AI 代理会把账号信息、代码上下文、输入及使用日志带入云服务商、模型提供方乃至境外接收方，从而触发数据安全、个人信息保护、跨境传输和生成式 AI 义务。中国、欧盟及美国加州的已核实规则共同指向最小化收集、用户权利响应、接收方约束和区域化数据流设计；免费排队只能控制算力供给，不能替代这些上线门槛。

## 关键证据
《生成式人工智能服务管理暂行办法》适用于向中国境内公众提供生成文本等内容的服务；仅研发、应用生成式 AI 而未向境内公众提供服务的情形不适用。SLIPE 若向境内公众开放 AI 代码生成，应按公众生成文本服务评估合规，而不能把 AI 代理仅视为普通编辑器功能；通过 API 提供生成式 AI 服务的组织或个人也纳入“提供者”定义。[1]
《网络数据安全管理条例》自 2025 年 1 月 1 日起施行，进一步要求网络数据处理者采取加密、备份、访问控制、安全认证等措施。向其他处理者提供或委托处理个人信息、重要数据时，应通过合同约定处理目的、方式、范围和安全义务，监督接收方履约，并将相关处理记录至少保存三年；个人信息处理规则还须公开处理目的、方式、种类、保存期限及用户行权途径。[2] 因而 SLIPE 接入云算力、源码托管、模型 API 和构建服务时，应形成供应商数据流清单与合同约束，而不是只比较调用价格。

## 资料限制
专题稿未单列资料限制。

## 上述段落引用的参考资料
1. [生成式人工智能服务管理暂行办法](https://www.cac.gov.cn/2023-07/13/c_1690898327029107.htm) — 国家互联网信息办公室等七部门，2023-07-13
2. [网络数据安全管理条例](http://xzfg.moj.gov.cn/mobile/law/detail?LawID=1734) — 国务院（国家法律法规数据库），2024-09-24

# 市场规模测算（market.md）

## 核心判断
以“可通过浏览器访问，并整合代码编辑、调试、版本控制与部署流水线的云端集成开发平台”为主要参照口径，Morgan Reed Insights 估算 **2026 年全球市场规模为 155.4 亿美元**，并预测 **2035 年为 649.3 亿美元、2026—2035 年复合年增长率为 17.22%**；前者是商业机构估算而非实际统计，后两者是预测而非确定性经营目标。[1] 这一口径明显宽于 SLIPE 的 Flutter 跨端编辑器与免费云开发路线，只能说明云开发环境具有增长参照价值，不能直接视为 SLIPE 的 TAM、SAM 或收入空间。

## 资料限制
专题稿未单列资料限制。

## 上述段落引用的参考资料
1. [Cloud Integrated Development Platform (IDE) Market - Industry Analysis, Size, Share, Growth, Trends, and Forecast 2026-2035](https://www.morganreedinsights.com/cloud-integrated-development-platform-ide-market/) — Morgan Reed Insights，2026年6月

# 产业链与关键瓶颈（chain.md）

## 核心判断
可核实的主链是“DeepSeek API—扩展宿主—仓库配置—云端 Linux 容器/虚拟机—预构建与按量计费”：SLIPE 的潜在价值在于用 Flutter 跨端入口统一编排这些外部能力，关键依赖则是模型 token、扩展运行时、源码配置以及云计算和存储。上下文缓存与预构建分别改善重复输入的成本/响应和环境启动，但仍留下 token、Actions 分钟及模板存储费用，因此免费排队只能限制在制并发，必须与空闲停机、存储回收、配额和支出上限联动。[1][2][3][5][6]

VS Code 扩展需要区分 Node.js 与浏览器运行时、UI 与 workspace 运行位置；SLIPE 官方移植应逐插件适配和验收，而不应承诺全量插件直接运行。[3][4]

## 资料限制
专题稿未单列资料限制。

## 上述段落引用的参考资料
1. [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) — DeepSeek API Docs，日期不详
2. [DeepSeek API introduces Context Caching on Disk, cutting prices by an order of magnitude](https://api-docs.deepseek.com/news/news0802/) — DeepSeek API Docs，日期不详
3. [Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host) — Microsoft Visual Studio Code，2026-11-04
4. [Web Extensions](https://code.visualstudio.com/api/extension-guides/web-extensions) — Microsoft Visual Studio Code，日期不详
5. [What are GitHub Codespaces?](https://docs.github.com/en/codespaces/about-codespaces/what-are-codespaces) — GitHub Docs，日期不详
6. [About billing for GitHub Codespaces](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces) — GitHub Docs，日期不详

# 竞争格局分析（competition.md）

## 核心判断
截至 2026-11-12，可核实的竞争可分为免费通用桌面编辑器、订阅制 AI Agent 开发环境、带个人账户额度与组织结算的云开发环境，以及浏览器内“AI + 完整虚拟机 + 框架模板”路线；这不是同一指标下的份额竞争。SLIPE 应避免正面比拼通用桌面生态、前沿模型赠送额度和通用云虚拟机能力，把定位收窄到 Flutter 跨端一致体验、轻量编辑与受控云任务，但这些定位目前仍是待验证差异，而非已证实壁垒。

## 关键证据
Visual Studio Marketplace 上由第三方发布者 jandrewm 提供的 DeepSeek Harness for VS Code (English) 展示了两条集成路径：一是把 DSH Web GUI 原样嵌入 VS Code 侧栏或编辑器标签页，并自动检测、启动 DSH 服务；二是通过仍处于早期发布状态的 Copilot bridge，把 DSH 注册为聊天模型。页面同时列出 dsh 版本适配、浏览器认证、RPC 端点回退、Remote-SSH/Dev Containers 服务端运行及端口转发等处理。[5]
因此，SLIPE 的“兼容 DeepSeek Harness 插件生态”应至少拆成 DSH 版本、启动与认证、工作区注册、RPC、远程执行和界面嵌入等兼容项，并逐项建立测试矩阵。该扩展还使用伴随插件完成拖放插入、外部链接和 macOS 剪贴板等细节能力，说明生态兼容的主要成本在持续适配与端侧交互，而不只是接通模型 API。[5]

## 资料限制
专题稿未单列资料限制。

## 上述段落引用的参考资料
5. [DeepSeek Harness for VS Code (English)](https://marketplace.visualstudio.com/items?itemName=jandrewm.deepseek-harness-vscode-english) — jandrewm（Visual Studio Marketplace），日期不详

# 重点企业研究（companies.md）

## 核心判断
代表产品已经形成四种不同竞争单元：Microsoft 以免費桌面编辑器和扩展 API 守住通用开发入口，Cursor 把 Agent、云端自动化和团队治理打包为订阅，Replit 收费重点是集成工作区、AI 应用构建及移动应用交付，DeepSeek 则按 token 提供模型与工具调用能力。SLIPE 不宜把它们都视为“另一种编辑器”并正面复制；更可行的位置是以 Flutter 跨端一致性、轻量编辑和同步为入口，把云算力、模型与插件兼容做成边界清楚的适配层。

下表价格与功能均为 2026-11-12 页面所列，仅用于比较当前产品与收费方式，不代表近 30 日新增功能，也不支持市场份额、收入或活跃用户排名。

| 代表主体 | 行业位置与产品路线 | 已核实商业化方式 | 跨端、云端与生态边界 | 对 SLIPE 的直接启示 |
|---|---|---|---|---|
| Microsoft / VS Code | 免费通用桌面代码编辑器，覆盖调试、任务和版本控制，并将 Copilot 与第三方 AI 扩展纳入编辑体验[1] | 编辑器可供私人或商业免费使用；AI 可使用 Copilot 免费/付费计划，也可自带模型密钥[1] | 支持 Windows、macOS、Linux；Code-OSS 采用 MIT 许可，但 Microsoft 发行版另有产品许可并包含 Marketplace 集成等专有部分；稳定扩展 API 保持向后兼容[1] | 插件移植应按许可证、API、运行时与分发渠道逐项验收，不能把 Code-OSS 或稳定 API 等同于全部 VS Code 插件可直接运行 |
| Cursor | AI 原生编辑器，以 Agent 为核心，并向云端 Agent、自动化、代码审查和团队协作延伸[2] | 免费档为 0 美元/月；高级版 30 美元/月，团队版 30 美元起/用户/月，企业版定制；第三方模型用量另按 API 标价计费[2] | 高级版起提供云端 Agent 与自动化；团队及企业档提供集中计费、隐私控制，以及内部规则、技能和插件应用市场[2] | 竞争基准已是完整 Agent 工作流和团队治理，而非单次补全；SLIPE 应优先保证跨端任务连续性、透明额度和模型费用，而非盲目扩张模型与功能数量 |
| Replit | 一体化工作区与 AI 应用构建服务，并向原生移动应用开发、预览和发布流程延伸[3][4] | Core 月付 20 美元/月、年付折算 18 美元/月；Pro 月付 100 美元/月、年付折算 90 美元/月；Enterprise 定制。Core 和 Pro 分别包含 20 美元、100 美元模型额度[3] | 官方将原生移动应用列为独立 artifact，文档覆盖模拟器/仿真器预览、Expo Go、发布流程及客户端—服务器架构[4] | Replit 的竞争单元是从描述到应用交付；SLIPE 应以轻量编码、既有项目同步和可控免费队列错位竞争，而不是先复制完整应用生成与发布链 |
| DeepSeek | 模型与开发能力供应层，通过 OpenAI/Anthropic 格式 API、工具调用、Responses API 等支撑编码 Agent，而非完整桌面 IDE[5] | 按输入、输出 token 及 Search/Fetch 请求计费；模型价格区分缓存命中、缓存未命中及峰时/非峰时，非峰时模型价格为峰时的一半[5] | deepseek-flash 与 deepseek-v4-pro 均支持工具调用；FIM 补全仅在非思考模式提供。DeepSeek Harness 连接器则属于独立社区项目，不是 DeepSeek 官方发布或背书的产品[5][6] | 可延迟的免费云任务可利用非峰时价格，但模型 token 费与云算力费必须分别计量；Harness 兼容需要版本化适配与安全授权设计，不能预设官方稳定插件接口 |

## 资料限制
专题稿未单列资料限制。

## 上述段落引用的参考资料
1. [Visual Studio Code FAQ](https://code.visualstudio.com/docs/supporting/FAQ) — Microsoft，日期不详
2. [Cursor 定价](https://cursor.com/cn/pricing) — Cursor，日期不详
3. [Pricing](https://replit.com/pricing) — Replit，日期不详
4. [Native Mobile Apps](https://docs.replit.com/features/artifact-types/building-mobile-apps) — Replit，日期不详
5. [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) — DeepSeek，日期不详
6. [DeepSeek Harness Connector](https://open-vsx.org/extension/lucasliang/harness-connector-deepseek) — YichuAI（Open VSX），日期不详
