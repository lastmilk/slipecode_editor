import path from "node:path";
import PptxGenJS from "pptxgenjs";
import {
  W, H, M, CW, C, F, T,
  text, token, panel, rect, hairline, kicker, bulletList, table, frame, notes,
  getWarnings, wrapLines,
} from "./theme.mjs";

const OUT = "/workspace/slipe-strategy-2026-11-12.pptx";
const total = 15;
const pptx = new PptxGenJS();
pptx.defineLayout({ name: "SLIPE_WIDE", width: W, height: H });
pptx.layout = "SLIPE_WIDE";
pptx.author = "SLIPE Strategy";
pptx.title = "SLIPE 跨端代码编辑器战略演示 2026-11-12";
pptx.subject = "跨端连续性、受控云开发与 90 天验证";

const s = () => pptx.addSlide();
const B = C.bg;

/* ------------------------------------------------------------------ 01 cover */
{
  const slide = s();
  slide.background = { color: B };
  token(slide, "SLIPE / STRATEGY 2026", { x: M, y: 0.52, w: 2.6, h: 0.22, fs: 9, color: C.accent });
  token(slide, "CROSS-DEVICE CONTINUITY / CONTROLLED CLOUD", {
    x: W - M - 4.6, y: 0.53, w: 4.6, h: 0.2, fs: 7.6, color: C.dim, align: "right",
  });
  text(slide, "换个设备，\n接着把任务做完。", {
    x: M, y: 1.28, w: 7.4, h: 2.1, fs: T.cover, bold: true, color: C.ink, lh: 55, page: 1,
  });
  rect(slide, M, 3.52, 2.2, 0.018, { fill: C.accent, line: null });
  text(slide, [
    { text: "以 Flutter 跨端连续性为入口，用轻量编辑、项目同步与透明配额的云任务形成差异；", options: { color: C.muted } },
    { text: "不复制更免费的 VS Code，也不参与补贴更多的 Cursor。", options: { color: C.ink, bold: true } },
  ], { x: M, y: 3.78, w: 7.0, h: 1.05, fs: 12.5, lh: 19, page: 1 });

  const metas = [
    ["研究截止", "2026-11-12", 1.45],
    ["覆盖范围", "全球竞品 · 中国获客与合规", 3.05],
    ["数字性质", "建议目标 / 情景假设", 2.55],
  ];
  let mx = M;
  for (const [label, value, width] of metas) {
    text(slide, label, { x: mx, y: 5.62, w: width, h: 0.18, fs: 7.2, color: C.dim, page: 1 });
    text(slide, value, { x: mx, y: 5.83, w: width, h: 0.24, fs: 9.2, color: C.ink, page: 1 });
    mx += width + 0.28;
  }
  hairline(slide, M, 5.5, 7.3, { color: C.ruleSoft, pt: 0.5 });
  text(slide, "本稿为战略建议：经营数字均为建议目标或情景假设，不是历史业绩、市场预测或交付承诺。", {
    x: M, y: 6.55, w: 7.3, h: 0.3, fs: 7.4, color: C.dim, page: 1,
  });

  panel(slide, 8.55, 1.28, 4.16, 4.62, { topRule: C.accent, page: 1 });
  kicker(slide, "DECISION / 03", { x: 8.85, y: 1.52, w: 1.6, fs: 7.6 });
  text(slide, "先验证三个闭环，\n再扩大补贴", {
    x: 8.85, y: 1.76, w: 3.55, h: 0.78, fs: 14.5, bold: true, color: C.ink, lh: 20, page: 1,
  });
  const dec = [
    ["01", "连续性闭环", "同一项目跨两类设备完成编辑、同步、云任务与结果恢复。"],
    ["02", "成本闭环", "排队之外有配额、超时、取消、停机、回收与全局熔断。"],
    ["03", "生态闭环", "DSH 锁版本适配；VS Code 插件逐项审查、移植与验收。"],
  ];
  dec.forEach(([no, name, body], i) => {
    const y = 2.72 + i * 1.05;
    token(slide, no, { x: 8.85, y, w: 0.4, h: 0.2, fs: 9, color: C.pop });
    text(slide, name, { x: 9.26, y: y - 0.015, w: 3.1, h: 0.22, fs: 9.6, bold: true, color: C.ink, page: 1 });
    text(slide, body, { x: 9.26, y: y + 0.24, w: 3.1, h: 0.56, fs: 8.1, color: C.muted, lh: 11.4, page: 1 });
    if (i < 2) hairline(slide, 8.85, y + 0.9, 3.55, { color: C.ruleSoft, pt: 0.5 });
  });

  notes(slide, [
    "封面：一句话主张——跨设备任务连续性，而不是更便宜的通用 IDE。",
    "三项闭环来自主报告第 00 章：连续性、成本、生态。红线策略：门槛未通过不释放后续预算。",
    "证据边界：项目真实用户、留存、收入、性能与云账单均未提供；所有经营数字为建议目标或情景假设。",
    "来源：SLIPE pubspec.yaml；backend/README.md；主报告参考资料 [1][2]。",
  ]);
}

/* ------------------------------------------------------------- 02 decisions */
{
  const slide = s();
  frame(pptx, slide, {
    no: 2, total, section: "00 / 决策摘要",
    claim: "先验证三个闭环，再把预算释放挂在门槛上",
    source: "决策与释放节奏为本报告建议；30% / 40% / 30% 是预算释放纪律，不是既有支出节奏。",
  });
  const cards = [
    {
      no: "01", title: "连续性闭环",
      desc: "同一项目跨两类设备完成编辑、同步、云任务与结果恢复。",
      items: ["第二设备恢复、冲突处理与失败降级可复现。", "云任务结果可回传，未知状态可解释。"],
      gate: "D30 关键任务可重复完成；同步与云任务事件覆盖 100%。",
    },
    {
      no: "02", title: "成本闭环",
      desc: "排队之外，同时执行配额、超时、取消、停机、回收与全局熔断。",
      items: ["模型、计算、存储与流量分开计量。", "每成功任务全成本可核算、可对账。"],
      gate: "零超预算天数；每次熔断都能追到任务与账单。",
    },
    {
      no: "03", title: "生态闭环",
      desc: "DSH 锁版本做适配；VS Code 插件逐项审查、移植、验收与维护。",
      items: ["先过许可证、API、运行时与分发权限。", "公开兼容等级、已测版本与限制。"],
      gate: "六项 DSH 测试通过；首批 3 个插件候选完成准入。",
    },
  ];
  cards.forEach((card, i) => {
    const x = M + i * 4.11;
    panel(slide, x, 1.66, 3.87, 3.28, { topRule: C.accent, page: 2 });
    token(slide, card.no, { x: x + 0.22, y: 1.86, w: 0.5, h: 0.34, fs: 21, color: C.pop });
    text(slide, card.title, { x: x + 0.22, y: 2.32, w: 3.4, h: 0.26, fs: 13, bold: true, page: 2 });
    text(slide, card.desc, { x: x + 0.22, y: 2.65, w: 3.38, h: 0.5, fs: 8.5, color: C.muted, lh: 11.8, page: 2 });
    kicker(slide, "要证明", { x: x + 0.22, y: 3.22, w: 1.2, color: C.dim, fs: 7 });
    bulletList(slide, card.items, {
      x: x + 0.22, y: 3.42, w: 3.35, fs: 8.2, gap: 0.07, color: C.muted, page: 2,
    });
    hairline(slide, x + 0.22, 4.26, 3.42, { color: C.ruleSoft, pt: 0.5 });
    token(slide, "门槛", { x: x + 0.22, y: 4.35, w: 0.42, h: 0.18, fs: 7.2, color: C.pop });
    text(slide, card.gate, { x: x + 0.7, y: 4.33, w: 2.95, h: 0.5, fs: 7.6, color: C.ink, lh: 10.2, page: 2 });
  });

  text(slide, "90 天增量预算释放", { x: M, y: 5.3, w: 1.95, h: 0.22, fs: 8.4, bold: true, color: C.ink, page: 2 });
  text(slide, "6 万验证 / 18 万标准", { x: M, y: 5.55, w: 1.95, h: 0.4, fs: 7.8, color: C.muted, lh: 10.4, page: 2 });
  const ladder = [
    ["30%", "D0 启动", "只释放验证情景 6 万，先做真实项目、成本埋点与合规底座。"],
    ["40%", "连续性门槛通过", "D30 关键任务可重复、同步与云任务事件覆盖 100% 后释放。"],
    ["30%", "留存与成本门槛通过", "W4 留存、任务成功与单位成本同时达标后释放。"],
  ];
  ladder.forEach(([pct, label, desc], i) => {
    const x = 2.78 + i * 3.3;
    token(slide, pct, { x, y: 5.22, w: 0.9, h: 0.42, fs: 23, color: C.pop });
    text(slide, label, { x: x + 0.92, y: 5.27, w: 2.2, h: 0.2, fs: 8.6, bold: true, page: 2 });
    text(slide, desc, { x: x + 0.92, y: 5.49, w: 2.2, h: 0.66, fs: 7.5, color: C.muted, lh: 10, page: 2 });
    if (i > 0) hairline(slide, x - 0.16, 5.24, 0, { color: C.rule, pt: 0.5 });
  });
  hairline(slide, M, 6.44, CW, { color: C.ruleSoft, pt: 0.5 });
  text(slide, "未达标时优先修产品，不以增加投放掩盖问题。", {
    x: M, y: 6.53, w: 8, h: 0.22, fs: 7.8, color: C.muted, page: 2,
  });

  notes(slide, [
    "三张卡片对应三个闭环，每张卡片有一句要证明的事和一条硬门槛。",
    "释放顺序：D0 只释放 30%；连续性门槛通过释放 40%；留存与成本门槛通过再释放 30%。",
    "标准情景 18 万不是默认预算，只有门槛通过后才启用。",
    "来源：主报告第 00 章与第 05 章预算表 [1][2]。",
  ]);
}

/* --------------------------------------------------------- 03 assets/market */
{
  const slide = s();
  frame(pptx, slide, {
    no: 3, total, section: "01 / 起点与市场",
    claim: "现有资产足以做验证，但不足以证明市场优势",
    source: "来源：SLIPE pubspec.yaml、backend/README.md [1][2]；Morgan Reed Insights 2026-06 商业估算 [23]；BairesDev 引 SlashData 2026-08 [24]。",
  });
  kicker(slide, "VERIFIED ASSETS", { x: M, y: 1.62, w: 2.2, fs: 7.2 });
  text(slide, "已核实的项目资产", { x: M, y: 1.82, w: 5.2, h: 0.26, fs: 11, bold: true, page: 3 });
  bulletList(slide, [
    "产品描述为 “Flutter code editor with cloud builds”；依赖含代码编辑、GitHub OAuth 与云同步网络策略。",
    "后端已有账号、偏好/项目/对话同步、GitHub/Gitee OAuth、OpenAI 兼容 LLM 代理、社区与微信支付接口。",
    "资产能缩短闭环验证时间，但不能推定生产可用性、全端一致、用户规模或商业转化。",
  ], { x: M, y: 2.14, w: 5.5, fs: 8.5, gap: 0.09, page: 3 });

  kicker(slide, "MISSING FOUNDATION", { x: M, y: 3.78, w: 2.6, fs: 7.2 });
  text(slide, "必须先补的扩张底座", { x: M, y: 3.98, w: 5.2, h: 0.26, fs: 11, bold: true, page: 3 });
  bulletList(slide, [
    "单实例 JSON 存储：多实例需数据库与共享会话密钥；规模化前完成迁移、备份与恢复验证。",
    "建立同项目、同网络、同任务的性能基线：启动、内存、同步成功率、冲突恢复与大项目响应。",
    "建立任务级成本日志：token、核心小时、构建分钟、存储、流量、失败重试与运维分摊。",
  ], { x: M, y: 4.3, w: 5.5, fs: 8.5, gap: 0.09, page: 3 });

  kicker(slide, "MARKET REFERENCE / NOT TAM", { x: 6.45, y: 1.62, w: 3.0, fs: 7.2 });
  text(slide, "宽口径云 IDE 市场只作方向参照", { x: 6.45, y: 1.82, w: 6.0, h: 0.26, fs: 11, bold: true, page: 3 });
  const nums = [
    ["15.54", "2026 · 十亿美元", "商业估算"],
    ["64.93", "2035 · 十亿美元", "同一机构预测"],
    ["17.22%", "2026—2035", "CAGR 预测"],
  ];
  nums.forEach(([value, l1, l2], i) => {
    const x = 6.45 + i * 2.1;
    token(slide, value, { x, y: 2.14, w: 1.85, h: 0.4, fs: 23, color: C.ink });
    text(slide, l1, { x, y: 2.55, w: 1.9, h: 0.18, fs: 7.2, color: C.muted, page: 3 });
    text(slide, l2, { x, y: 2.72, w: 1.9, h: 0.18, fs: 7.2, color: C.dim, page: 3 });
  });
  text(slide, "口径含完整浏览器开发、调试、版本控制与部署，明显宽于 SLIPE。不得写成 SLIPE 的 TAM / SAM / SOM；三者也应从可触达用户、激活、留存、净收入与任务成本自下而上建立。", {
    x: 6.45, y: 2.98, w: 6.15, h: 0.72, fs: 8.1, color: C.muted, lh: 11.4, page: 3,
  });
  slide.addChart(pptx.ChartType.bar, [{
    name: "宽口径云 IDE 市场规模", labels: ["2026 估算", "2035 预测"], values: [15.54, 64.93],
  }], {
    x: 6.45, y: 3.78, w: 6.1, h: 1.62,
    barDir: "col", barGapWidthPct: 60,
    chartColors: [C.accent],
    chartArea: { fill: { color: C.panel }, border: { color: C.rule, pt: 0.5 }, roundedCorners: false },
    plotArea: { fill: { color: C.panel }, border: { type: "none" } },
    showLegend: false, showValue: true,
    dataLabelColor: C.ink, dataLabelFontSize: 8, dataLabelFontFace: F.mono,
    dataLabelFormatCode: "0.00", dataLabelPosition: "outEnd",
    catAxisLabelColor: C.muted, catAxisLabelFontSize: 7.5, catAxisLabelFontFace: F.cjk,
    catAxisLineShow: false, valAxisHidden: true, valAxisLineShow: false,
    valGridLine: { style: "none" },
  });
  text(slide, "另一二手归因称 2025 Q3 全球活跃软件开发者约 4,840 万，为广义人口参照，不能直接乘付费转化率。", {
    x: 6.45, y: 5.46, w: 6.15, h: 0.42, fs: 7.3, color: C.dim, lh: 10, page: 3,
  });

  panel(slide, M, 6.06, CW, 0.6, { leftRule: C.pop, page: 3 });
  text(slide, "证据边界：项目真实用户、留存、收入、性能与云账单均未提供。Firebase Studio 2027-03-22 弃用可作迁移话题窗口，但不代表其用户会流向 SLIPE。", {
    x: M + 0.2, y: 6.14, w: CW - 0.4, h: 0.44, fs: 7.8, color: C.muted, lh: 10.6, page: 3,
  });

  notes(slide, [
    "左侧是项目真实资产与必须先补的底座，右侧是市场参照与证据边界。",
    "155.4 亿美元（2026）与 649.3 亿美元（2035）是 Morgan Reed Insights 的宽口径云 IDE 商业估算，不是 SLIPE 的 TAM/SAM/SOM。",
    "4,840 万开发者是二手归因的广义人口，不可直接乘付费转化率。",
    "Firebase Studio 官方页面已宣布 2027-03-22 弃用并限制新用户，这只提供内容窗口，不是护城河。",
  ]);
}

/* ------------------------------------------------------------ 04 six units */
{
  const slide = s();
  frame(pptx, slide, {
    no: 4, total, section: "02 / 竞品格局",
    claim: "竞品不是同一赛道里的六个替代品，而是六种竞争单元",
    source: "价格与规则为截至 2026-11-12 的官方页面公开标价或资源规则，不是成交价、采购价、市场份额或用户排名；结构化数据见 slipe-competitors-2026-11-12.csv。",
  });
  const data = [
    ["主体 / 竞争单元", "公开价格或资源约束（截至 2026-11-12）", "平台 · 生态 · 边界", "SLIPE 的应对"],
    [
      { text: "VS Code｜免费通用桌面", options: { bold: true, color: C.ink } },
      "编辑器免费；AI 与云服务另计",
      "Windows / macOS / Linux；Code-OSS 为 MIT，但 Microsoft 发行版与 Marketplace 集成另有边界",
      "不以免费桌面或三大系统作差异；证明跨端续接与特定任务效率",
    ],
    [
      { text: "Cursor｜AI Agent 开发环境", options: { bold: true, color: C.ink } },
      "Free $0；Pro $30/月；团队 $30 起/席/月；第三方模型用量另计",
      "Agent、Cloud Agents、自动化、代码审查与团队治理",
      "不补贴通用 Agent 用量；强调跨端恢复、透明队列与配额",
    ],
    [
      { text: "Codespaces｜托管云开发环境", options: { bold: true, color: C.ink } },
      "个人含固定免费量；计算、存储、预构建分别计费，并区分付款主体与支出控制",
      "仓库配置、Linux 容器 / 虚拟机；浏览器、VS Code 或 CLI 接入",
      "不做无差别云 VM；先做受控异步任务与硬配额",
    ],
    [
      { text: "Replit｜一体化工作区与交付", options: { bold: true, color: C.ink } },
      "Core $20/月；Pro $100/月；分别含模型额度",
      "从描述到应用构建、协作与原生移动应用预览 / 发布",
      "只服务既有项目轻量续接，不复制重交付链",
    ],
    [
      { text: "Firebase Studio｜浏览器 AI + VM", options: { bold: true, color: C.ink } },
      "现有工作区免费；停新用户 / 新工作区；2027-03-22 弃用",
      "Code OSS、Google Cloud VM、Nix、Open VSX、Flutter 模板",
      "迁移内容窗口；不把大厂免费路线或 Flutter 模板当护城河",
    ],
    [
      { text: "DeepSeek｜模型与工具调用层", options: { bold: true, color: C.ink } },
      "按 token、缓存状态、峰谷计费；Search / Fetch 另计",
      "API 而非完整 IDE；Harness 连接器为独立社区项目，不是官方背书",
      "模型费与算力费分开计量；版本化最小权限适配",
    ],
  ];
  table(slide, {
    x: M, y: 1.62, w: CW, colW: [2.35, 3.1, 3.6, 3.04],
    data, rowH: [0.38, 0.7, 0.7, 0.7, 0.66, 0.7, 0.7],
    fs: 8.3, pad: 0.055, page: 4, label: "competition",
  });
  text(slide, "六种单元分别守入口、卖工作流、卖环境、卖交付、卖模板与卖模型；SLIPE 只能错位组合。", {
    x: M, y: 6.52, w: 8.4, h: 0.22, fs: 8.2, color: C.muted, page: 4,
  });
  token(slide, "CSV / 18 COLUMNS", { x: W - M - 2.0, y: 6.53, w: 2.0, h: 0.2, fs: 7, color: C.dim, align: "right" });

  notes(slide, [
    "六种竞争单元：通用桌面入口、AI Agent 工作流、托管云环境、一体化交付、模板化云 IDE、模型供应层。",
    "价格均为 2026-11-12 可访问的官方公开页面，非成交价、采购价、份额或排名。",
    "Cursor $30/月为高级版；Replit Core $20/月、Pro $100/月；Codespaces 的计算、存储、预构建分别计费。",
    "DeepSeek Harness 连接器是独立社区项目，不能描述为 DeepSeek 官方插件或背书 [15][16]。",
  ]);
}

/* --------------------------------------------------------- 05 what to win */
{
  const slide = s();
  frame(pptx, slide, {
    no: 5, total, section: "02 / 竞品格局 · 含义",
    claim: "要赢的是四次具体续接，而不是一张功能对照表",
    source: "“跨端、轻量、同步”目前均为待实测命题；本页禁用词清单用于对外内容审核。",
  });
  const leftItems = [
    ["与 VS Code 比免费下载与插件总数", "用户没有迁移理由，且许可与 Marketplace 边界复杂。"],
    ["与 Cursor 比通用 Agent 赠送额度", "补贴不可持续，模型成本无法封顶。"],
    ["与 Codespaces 比无限制通用云 VM", "成本结构不支持，等待与滥用会失控。"],
    ["与 Replit 比完整生成、签名与发布", "维护半径过大，偏离跨端续接主线。"],
  ];
  const rightItems = [
    ["手机上查看或修改，桌面继续同一项目", "项目、上下文与会话恢复，是最短的价值证明。"],
    ["低配置设备轻量编辑，重任务进云队列", "队列位置、预计等待、配额与取消必须可见。"],
    ["云任务失败或熔断，本地仍可编辑同步", "降级路径本身就是差异化承诺。"],
    ["既有 Harness 会话与精选插件按边界迁移", "公开已测版本、权限、限制与退出条件。"],
  ];
  const drawRegion = (x, label, title, items, gate) => {
    kicker(slide, label, { x, y: 1.66, w: 3, color: gate ? C.pop : C.accent, fs: 7.2 });
    text(slide, title, { x, y: 1.88, w: 5.6, h: 0.3, fs: 13, bold: true, page: 5 });
    let y = 2.32;
    items.forEach(([head, body], i) => {
      token(slide, String(i + 1).padStart(2, "0"), { x, y: y + 0.01, w: 0.28, h: 0.18, fs: 7.6, color: gate ? C.pop : C.accent });
      text(slide, head, { x: x + 0.34, y, w: 5.25, h: 0.22, fs: 9.8, bold: true, page: 5 });
      text(slide, body, { x: x + 0.34, y: y + 0.24, w: 5.25, h: 0.36, fs: 8.2, color: C.muted, lh: 11.2, page: 5 });
      y += 0.66;
      if (i < items.length - 1) hairline(slide, x, y - 0.12, 5.55, { color: C.ruleSoft, pt: 0.5 });
    });
  };
  drawRegion(M, "AVOID / 正面战场", "避开的四场正面战", leftItems, false);
  drawRegion(6.79, "WIN / 具体场景", "必须赢下的四次续接", rightItems, true);

  hairline(slide, M, 5.18, CW, { color: C.rule });
  kicker(slide, "LANGUAGE GUARD / 对外禁用", { x: M, y: 5.28, w: 3.0, color: C.pop, fs: 7.2 });
  text(slide, "跨端、轻量、同步目前都是待实测命题。", {
    x: M, y: 5.5, w: 6.0, h: 0.28, fs: 11, bold: true, page: 5,
  });
  const banned = [["最轻", 0.78], ["零等待", 0.9], ["无缝", 0.78], ["全兼容", 0.9], ["全量插件兼容", 1.45], ["DeepSeek 官方背书", 1.72]];
  let bx = M;
  banned.forEach(([label, bw]) => {
    rect(slide, bx, 5.9, bw, 0.3, { fill: C.panel, line: C.rule, linePt: 0.5 });
    text(slide, `× ${label}`, { x: bx, y: 5.95, w: bw, h: 0.2, fs: 7.4, color: C.muted, align: "center", page: 5 });
    bx += bw + 0.1;
  });
  text(slide, "对外只展示可复现的项目与任务：同一项目、同网络、可取消、可恢复、可对账。", {
    x: M, y: 6.36, w: 11.9, h: 0.24, fs: 8.4, color: C.muted, page: 5,
  });

  notes(slide, [
    "左列是明确不打的四场正面战，右列是必须赢下的四次续接。",
    "禁用词：最轻、零等待、无缝、全兼容、全量插件兼容、DeepSeek 官方背书。",
    "本次没有 SLIPE 与同口径竞品的内存、启动时延、同步成功率或功能一致率数据，传播只用可复现证据。",
    "来源：主报告第 02 章；VS Code 扩展宿主与 Web 扩展边界 [13][14]。",
  ]);
}

/* ------------------------------------------------------------- 06 SWOT/TOWS */
{
  const slide = s();
  frame(pptx, slide, {
    no: 6, total, section: "03 / SWOT · TOWS",
    claim: "技术资产是起点，成本与维护纪律决定能否放大",
    source: "SWOT 与 TOWS 为本报告建议；项目资产与后端约束见 pubspec.yaml、backend/README.md [1][2]。",
  });
  const swot = [
    ["S", "优势 / 可用资产", C.accent, [
      "Flutter 单代码库与多端工程，为连续体验提供技术基础。",
      "账号、同步、OAuth、LLM 代理、社区与支付后端可缩短闭环。",
    ]],
    ["W", "劣势 / 当前缺口", C.muted, [
      "缺真实性能、留存、收入、云成本与桌面交互数据。",
      "单实例 JSON 存储限制多实例；跨端 UI ≠ 插件运行时与 Git 工作流。",
    ]],
    ["O", "机会 / 可验证窗口", C.accent, [
      "通用桌面、Agent 与云 VM 之间仍有跨端连续任务切口。",
      "Firebase Studio 弃用与 DSH 适配提供迁移话题窗口。",
    ]],
    ["T", "威胁 / 外部约束", C.muted, [
      "免费 VS Code、Agent 订阅与云额度持续抬高用户预期。",
      "模型 / 云价格、协议、数据跨境与插件分发许可随时变化。",
    ]],
  ];
  swot.forEach(([letter, title, letterColor, items], i) => {
    const x = M + (i % 2) * 6.17;
    const y = 1.62 + Math.floor(i / 2) * 1.55;
    panel(slide, x, y, 5.92, 1.43, { page: 6 });
    rect(slide, x + 0.2, y + 0.16, 0.3, 0.3, { fill: i === 0 || i === 2 ? C.accent : C.panel2, line: C.rule });
    text(slide, letter, {
      x: x + 0.2, y: y + 0.2, w: 0.3, h: 0.22, fs: 9, bold: true, align: "center",
      color: i === 0 || i === 2 ? C.bg : C.accent, page: 6,
    });
    text(slide, title, { x: x + 0.6, y: y + 0.2, w: 4.9, h: 0.24, fs: 9.6, bold: true, page: 6 });
    bulletList(slide, items, {
      x: x + 0.2, y: y + 0.56, w: 5.5, fs: 8.1, gap: 0.04, color: C.muted, page: 6,
    });
  });

  kicker(slide, "TOWS / 四组动作", { x: M, y: 4.72, w: 2.4, color: C.accent, fs: 7.2 });
  const tows = [
    ["SO", "用资产抢场景", "发布“移动发起—桌面续接—云端构建”真实演示；开放模板与示例插件。", "第二设备激活、跨端任务成功率、模板复用项目数。"],
    ["WO", "用免费补验证", "用有限异步任务换真实项目测试与跨端激活，不换注册量；同步采集成本。", "每跨端激活项目成本、W4 留存、回收路径。"],
    ["ST", "用边界抗复制", "保持模型 / 云适配层、透明配额、可恢复会话与公开兼容等级。", "供应切换时间、任务恢复率、价格变化影响。"],
    ["WT", "用纪律控风险", "数据库迁移、最小权限、区域数据流、预算熔断与插件退出先于规模化。", "零超预算天数、删除链路覆盖、恢复演练。"],
  ];
  tows.forEach(([code, name, action, signal], i) => {
    const x = M + i * 3.06;
    panel(slide, x, 4.92, 2.91, 1.78, { topRule: code === "SO" || code === "WO" ? C.accent : C.rule, page: 6 });
    token(slide, code, { x: x + 0.16, y: 5.02, w: 0.42, h: 0.2, fs: 9, color: C.accent });
    text(slide, name, { x: x + 0.62, y: 5.02, w: 2.1, h: 0.2, fs: 8.3, bold: true, page: 6 });
    text(slide, action, { x: x + 0.16, y: 5.3, w: 2.6, h: 0.68, fs: 7.5, color: C.muted, lh: 9.6, page: 6 });
    hairline(slide, x + 0.16, 6.02, 2.58, { color: C.ruleSoft, pt: 0.5 });
    text(slide, [
      { text: "验证 · ", options: { color: C.dim } },
      { text: signal, options: { color: C.ink } },
    ], { x: x + 0.16, y: 6.08, w: 2.6, h: 0.56, fs: 7.2, lh: 9.2, page: 6 });
  });

  notes(slide, [
    "SWOT 的判断：技术资产真实存在，但缺少性能、留存、收入与云成本证据；成本与维护纪律决定能否放大。",
    "TOWS 把分析转成四组动作：SO 抢场景、WO 用免费补验证、ST 用边界抗复制、WT 用纪律控风险。",
    "每组动作都配可验证结果，避免只写策略口号。",
  ]);
}

/* ----------------------------------------------------------- 07 positioning */
{
  const slide = s();
  frame(pptx, slide, {
    no: 7, total, section: "04 / 定位与客群",
    claim: "定位是跨端代码工作区，不是另一个全功能 AI IDE",
    source: "定位、ICP 与传播主线为本报告建议；不含对 SLIPE 现有用户规模或付费能力的判断。",
  });
  panel(slide, M, 1.62, CW, 1.3, { leftRule: C.pop, page: 7 });
  kicker(slide, "POSITIONING STATEMENT", { x: M + 0.26, y: 1.76, w: 3.2, color: C.accent, fs: 7.2 });
  text(slide, [
    { text: "面向在移动与桌面之间切换的开发者，SLIPE 是", options: { color: C.ink } },
    { text: "轻量跨端代码工作区", options: { color: C.pop, bold: true } },
    { text: "：保留项目上下文，接续编辑与受控云任务。相比通用桌面 AI IDE 或浏览器云 VM，更重视任务恢复与透明配额，而非功能总量。", options: { color: C.ink } },
  ], { x: M + 0.26, y: 1.99, w: 11.55, h: 0.78, fs: 13.5, bold: true, lh: 19, page: 7 });

  const icp = [
    ["PRIMARY / ICP-A", "跨端个人与独立开发者", "已有项目，在通勤或临时场景查看、修改，回到桌面继续；首要证明任务恢复与同步可信。", "优先获客", C.pop],
    ["SECONDARY / ICP-B", "学生与低配置设备用户", "需要轻量编辑和偶尔云构建；以受控异步任务服务，不承诺替代完整本地开发环境。", "验证付费与成本", C.rule],
    ["LATER / ICP-C", "小型项目团队", "需要共享插件清单、集中配额与审计；待个人连续性、成本与桌面体验稳定后进入。", "后续阶段", C.rule],
  ];
  icp.forEach(([label, title, desc, tag, tagColor], i) => {
    const x = M + i * 4.11;
    panel(slide, x, 3.08, 3.87, 2.02, { topRule: i === 0 ? C.pop : C.accent, page: 7 });
    kicker(slide, label, { x: x + 0.22, y: 3.22, w: 3.0, color: i === 0 ? C.pop : C.accent, fs: 6.9 });
    text(slide, title, { x: x + 0.22, y: 3.43, w: 3.4, h: 0.28, fs: 11.5, bold: true, page: 7 });
    text(slide, desc, { x: x + 0.22, y: 3.74, w: 3.4, h: 0.82, fs: 8.2, color: C.muted, lh: 11.2, page: 7 });
    rect(slide, x + 0.22, 4.62, Math.max(0.9, tag.length * 0.145 + 0.16), 0.26, { fill: C.panel2, line: tagColor, linePt: 0.6 });
    text(slide, tag, { x: x + 0.22, y: 4.665, w: Math.max(0.9, tag.length * 0.145 + 0.16), h: 0.2, fs: 7.2, color: i === 0 ? C.pop : C.muted, align: "center", page: 7 });
  });

  hairline(slide, M, 5.32, CW, { color: C.rule });
  kicker(slide, "NOT NOW / 第一阶段明确不服务", { x: M, y: 5.42, w: 4.2, color: C.dim, fs: 7.2 });
  text(slide, "需要全部 VS Code 插件直接运行、无限免费 Agent / VM、复杂企业私有化治理或完整移动商店发布的用户，不应成为首期获客承诺对象。", {
    x: M, y: 5.64, w: 6.15, h: 0.7, fs: 8.5, color: C.muted, lh: 11.8, page: 7,
  });
  kicker(slide, "MESSAGES / 传播主线", { x: 6.98, y: 5.42, w: 3.0, color: C.accent, fs: 7.2 });
  const msgs = ["换个设备，接着把任务做完。", "轻任务在本地，重任务有边界地上云。", "插件按已测等级兼容，公开版本与限制。"];
  msgs.forEach((m, i) => {
    text(slide, m, { x: 6.98, y: 5.66 + i * 0.3, w: 5.6, h: 0.26, fs: 8.8, bold: true, page: 7 });
  });

  notes(slide, [
    "定位语句：轻量跨端代码工作区，保留项目上下文，接续编辑与受控云任务；不比功能总量。",
    "ICP-A 跨端个人与独立开发者是首期获客；ICP-B 验证付费与成本；ICP-C 后续阶段。",
    "第一阶段明确不服务：全量插件直接运行、无限免费 Agent/VM、企业私有化治理、完整移动商店发布。",
    "传播主线三句都要求可复现证据支撑，避免绝对词。",
  ]);
}

/* -------------------------------------------------------------- 08 90d GTM */
{
  const slide = s();
  frame(pptx, slide, {
    no: 8, total, section: "05 / 90 天推广",
    claim: "90 天用真实项目漏斗替代下载量漏斗",
    source: "漏斗、门槛与节奏为本报告建议目标（用于 gate，不是业绩预测）；D30 取得基线后可调整阈值。",
  });
  const stages = ["触达", "首个有效项目", "第二设备激活", "云任务成功", "W4 留存", "付费"];
  stages.forEach((label, i) => {
    const x = M + i * 2.02;
    rect(slide, x, 1.62, 1.84, 0.62, { fill: C.panel, line: i >= 2 && i <= 4 ? C.accent : C.rule, linePt: i >= 2 && i <= 4 ? 0.9 : 0.5 });
    token(slide, String(i + 1).padStart(2, "0"), { x: x + 0.12, y: 1.7, w: 0.3, h: 0.16, fs: 6.4, color: C.dim });
    text(slide, label, { x: x + 0.12, y: 1.88, w: 1.62, h: 0.24, fs: 8.6, bold: i >= 2 && i <= 4, color: i >= 2 && i <= 4 ? C.ink : C.muted, page: 8 });
  });

  const phases = [
    ["D01—D30 / PROVE", "证明任务链与埋点", "30 名目标用户深访、20 个真实项目测试；打通第二设备恢复、异步云任务、取消 / 超时 / 降级与任务成本日志；发布 3 个可复现演示，暂不扩大付费投放。", "关键任务可重复完成；同步与云任务事件覆盖 100%；形成首轮性能与成本基线。"],
    ["D31—D60 / REPEAT", "小范围可复制获客", "在 Flutter/Dart、掘金、知乎、B 站、GitHub/Gitee 与开发者社群发布教程与模板；2 场小型工作坊；A/B 测试三种信息，以跨端激活排序。", "至少一种渠道能重复带来有效项目；队列透明实验降低取消；成本未越界。"],
    ["D61—D90 / SCALE OR STOP", "只放大通过门槛的路径", "累计 12 个演示/教程、3 场工作坊、2 个开放模板、1 个示例插件；高留存渠道小额付费放大；启动 Pro 价格访谈与落地页测试。", "留存、任务成功、成本与支持负担同时达标，才进入桌面与生态扩张。"],
  ];
  phases.forEach(([label, title, body, gate], i) => {
    const x = M + i * 4.11;
    panel(slide, x, 2.52, 3.87, 2.62, { topRule: C.accent, page: 8 });
    kicker(slide, label, { x: x + 0.22, y: 2.66, w: 3.4, fs: 6.8 });
    text(slide, title, { x: x + 0.22, y: 2.86, w: 3.42, h: 0.26, fs: 11.2, bold: true, page: 8 });
    text(slide, body, { x: x + 0.22, y: 3.18, w: 3.42, h: 1.08, fs: 8, color: C.muted, lh: 10.8, page: 8 });
    hairline(slide, x + 0.22, 4.3, 3.42, { color: C.ruleSoft, pt: 0.5 });
    token(slide, "门槛", { x: x + 0.22, y: 4.4, w: 0.42, h: 0.18, fs: 7, color: C.pop });
    text(slide, gate, { x: x + 0.7, y: 4.38, w: 2.95, h: 0.62, fs: 7.3, color: C.ink, lh: 9.6, page: 8 });
  });

  kicker(slide, "D90 建议目标 / GATE", { x: M, y: 5.3, w: 3.4, color: C.pop, fs: 7.2 });
  const metrics = [
    ["≥ 30", "跨端活跃项目 / 周"],
    ["≥ 100", "有效项目累计"],
    ["≥ 95%", "同步任务成功率"],
    ["≥ 90%", "云任务成功率"],
    ["≤ 15min", "异步任务 P95 等待"],
    ["≥ 20%", "W4 跨端项目留存"],
    ["0 次", "超预算天数"],
  ];
  metrics.forEach(([value, label], i) => {
    const x = M + i * 1.726;
    rect(slide, x, 5.52, 1.67, 0.82, { fill: C.panel, line: C.ruleSoft, linePt: 0.5 });
    token(slide, value, { x: x + 0.08, y: 5.6, w: 1.51, h: 0.28, fs: 13.5, color: C.ink, align: "center" });
    text(slide, label, { x: x + 0.08, y: 5.92, w: 1.51, h: 0.34, fs: 6.8, color: C.muted, align: "center", lh: 8.6, page: 8 });
  });
  text(slide, "每个渠道按“每跨端激活项目成本”比较，而不是点击或注册；未达标渠道停止，不用云额度奖励刷量。", {
    x: M, y: 6.48, w: 11.9, h: 0.24, fs: 7.9, color: C.muted, page: 8,
  });

  notes(slide, [
    "漏斗：触达 → 首个有效项目 → 第二设备激活 → 云任务成功 → W4 留存 → 付费。",
    "三段分别是证明、复制、放大或停止；每段写清门槛，避免用投放掩盖产品问题。",
    "D90 建议目标：≥30 跨端活跃项目/周、≥100 有效项目、≥95% 同步、≥90% 云任务、≤15 分钟 P95、≥20% W4 留存、0 次超预算。",
    "这些是首轮建议阈值，不是业绩预测。",
  ]);
}

/* --------------------------------------------------------------- 09 budget */
{
  const slide = s();
  frame(pptx, slide, {
    no: 9, total, section: "05 / 90 天预算",
    claim: "6 万验证、18 万标准：先释放 30%，按门槛再加码",
    source: "预算为情景假设，不是已批准预算或历史支出；不含既有人员薪酬与自购硬件；分项合计 6.0 / 18.0 万元。",
  });
  const budgetRows = [
    ["用途", "验证（万元）", "标准（万元）", "控制原则"],
    ["云计算与模型", "1.8", "4.5", "独立硬预算"],
    ["内容与演示", "0.8", "3.0", "可复用证据"],
    ["社区与活动", "0.6", "2.4", "自带项目"],
    ["渠道实验", "0.9", "3.6", "按激活排序"],
    ["研究与用户激励", "0.6", "1.5", "拒绝刷量"],
    ["合规、安全与工具", "0.8", "1.8", "不可削减"],
    ["预备金", "0.5", "1.2", "只对已验证风险"],
    [{ text: "合计", options: { bold: true, color: C.ink } }, { text: "6.0", options: { bold: true, color: C.pop } }, { text: "18.0", options: { bold: true, color: C.pop } }, { text: "30 / 40 / 30 释放", options: { color: C.muted } }],
  ];
  table(slide, {
    x: M, y: 1.62, w: 6.6, colW: [2.35, 1.25, 1.25, 1.75],
    data: budgetRows, rowH: [0.36, 0.34, 0.34, 0.34, 0.34, 0.34, 0.36, 0.34, 0.4],
    fs: 8.2, pad: 0.05, page: 9, label: "budget",
  });
  text(slide, "90 天增量预算 / 万元", { x: 7.45, y: 1.6, w: 4.8, h: 0.2, fs: 7.6, color: C.muted, page: 9 });
  slide.addChart(pptx.ChartType.bar, [
    { name: "验证情景", labels: ["云与模型", "内容演示", "社区活动", "渠道实验", "研究与预备", "合规工具"], values: [1.8, 0.8, 0.6, 0.9, 1.1, 0.8] },
    { name: "标准情景", labels: ["云与模型", "内容演示", "社区活动", "渠道实验", "研究与预备", "合规工具"], values: [4.5, 3.0, 2.4, 3.6, 2.7, 1.8] },
  ], {
    x: 7.45, y: 1.8, w: 5.26, h: 3.05,
    barDir: "bar", barGrouping: "clustered", barGapWidthPct: 45,
    chartColors: [C.accent, C.neutralBar],
    chartArea: { fill: { color: C.panel }, border: { color: C.rule, pt: 0.5 }, roundedCorners: false },
    plotArea: { fill: { color: C.panel }, border: { type: "none" } },
    showLegend: true, legendPos: "b", legendColor: C.muted, legendFontSize: 7, legendFontFace: F.cjk,
    showValue: true, dataLabelColor: C.ink, dataLabelFontSize: 6.8, dataLabelFontFace: F.mono,
    dataLabelFormatCode: "0.0", dataLabelPosition: "outEnd",
    catAxisLabelColor: C.muted, catAxisLabelFontSize: 7, catAxisLabelFontFace: F.cjk,
    catAxisLineShow: false, valAxisHidden: true, valAxisLineShow: false,
    valGridLine: { style: "none" },
  });

  const steps = [
    ["30%", "D0", "验证情景 6 万", "云成本、合规与可复用内容先行"],
    ["40%", "连续性门槛", "D30 通过后", "关键任务可重复、事件覆盖 100% 才扩渠道"],
    ["30%", "留存与成本门槛", "D60—D90", "W4 留存与单位经济同时达标后释放"],
  ];
  hairline(slide, M, 5.18, CW, { color: C.rule });
  steps.forEach(([pct, label, when, desc], i) => {
    const x = M + i * 4.11;
    token(slide, pct, { x, y: 5.3, w: 0.95, h: 0.4, fs: 24, color: C.pop });
    text(slide, label, { x: x + 1.0, y: 5.3, w: 2.8, h: 0.2, fs: 8.8, bold: true, page: 9 });
    token(slide, when, { x: x + 1.0, y: 5.52, w: 2.0, h: 0.18, fs: 7.2, color: C.dim });
    text(slide, desc, { x: x + 1.0, y: 5.72, w: 2.85, h: 0.46, fs: 7.6, color: C.muted, lh: 9.8, page: 9 });
  });
  text(slide, "标准情景 18 万只在门槛通过后启用，不是默认预算；未达标时优先修产品，不以投放掩盖问题。", {
    x: M, y: 6.35, w: 11.9, h: 0.24, fs: 8, color: C.muted, page: 9,
  });

  notes(slide, [
    "验证情景 6.0 万、标准情景 18.0 万，均为增量现金预算的情景假设，不含人员薪酬与自购硬件。",
    "分项：云与模型 1.8/4.5；内容 0.8/3.0；社区 0.6/2.4；渠道 0.9/3.6；研究 0.6/1.5；合规 0.8/1.8；预备 0.5/1.2。",
    "释放节奏：30% / 40% / 30%，分别对应启动、连续性门槛、留存与成本门槛。",
  ]);
}

/* ----------------------------------------------------------- 10 free cloud */
{
  const slide = s();
  frame(pptx, slide, {
    no: 10, total, section: "06 / 免费云经济",
    claim: "排队只控制并发，硬控制才控制成本",
    source: "上游机制：活跃计算、滞留存储、预构建、模型 token 与检索请求可能分别计费 [9][11]；本页规则为本报告建议。",
  });
  panel(slide, M, 1.62, CW, 0.62, { fill: C.panel, page: 10 });
  text(slide, "单位成功任务全成本 =（计算 + 模型 + 存储/流量 + 预构建 + 失败任务 + 可分摊运维）÷ 成功任务数", {
    x: M + 0.22, y: 1.73, w: 11.6, h: 0.36, fs: 9.4, color: C.accent, lh: 12, page: 10,
  });

  const phases = [
    ["任务前 / BEFORE", "先允许，再分配", [
      "类型白名单与资源规格；不开放任意镜像。",
      "用户与全局并发、配额、优先券。",
      "预计等待与队列位置对用户可见。",
      "模型与云费用归属、授权范围。",
    ]],
    ["任务中 / DURING", "任何一项都能单独止损", [
      "硬超时与用户主动取消。",
      "空闲停机、异常检测与速率限制。",
      "token / 核心小时限额。",
      "全局预算熔断，按日与月双阈值。",
    ]],
    ["任务后 / AFTER", "回收与对账决定下一轮配额", [
      "结果回传与环境保留期限。",
      "存储回收、临时层清理。",
      "失败重试上限与退避。",
      "本地编辑降级、成本对账与归因。",
    ]],
  ];
  phases.forEach(([label, title, items], i) => {
    const x = M + i * 4.11;
    panel(slide, x, 2.48, 3.87, 2.42, { topRule: i === 1 ? C.accent : C.rule, page: 10 });
    kicker(slide, label, { x: x + 0.22, y: 2.62, w: 3.2, fs: 6.9 });
    text(slide, title, { x: x + 0.22, y: 2.83, w: 3.42, h: 0.24, fs: 10.5, bold: true, page: 10 });
    bulletList(slide, items, {
      x: x + 0.22, y: 3.16, w: 3.4, fs: 8.1, gap: 0.06, color: C.muted, page: 10,
    });
  });

  panel(slide, M, 5.06, 5.9, 1.52, { page: 10 });
  kicker(slide, "TWO PATHS / 两种成本承担", { x: M + 0.2, y: 5.16, w: 3.4, fs: 6.9 });
  text(slide, [
    { text: "用户云账户（BYO 云 / BYOK）", options: { bold: true, color: C.ink } },
    { text: "  → 仍需硬配额与撤权；\n", options: { color: C.muted } },
    { text: "SLIPE 承担（免费队列）", options: { bold: true, color: C.ink } },
    { text: "  → 必须把失败、闲置与存储一起计价。", options: { color: C.muted } },
  ], { x: M + 0.2, y: 5.4, w: 5.5, h: 0.98, fs: 8.4, lh: 12.2, page: 10 });

  panel(slide, 6.79, 5.06, 5.92, 1.52, { leftRule: C.pop, page: 10 });
  kicker(slide, "熔断时 / CIRCUIT BREAK", { x: 6.99, y: 5.16, w: 3.2, color: C.pop, fs: 6.9 });
  text(slide, "停新任务、缩配额与类型、回收环境；本地编辑与同步继续可用。", {
    x: 6.99, y: 5.38, w: 5.5, h: 0.44, fs: 9.2, bold: true, color: C.ink, lh: 12.4, page: 10,
  });
  text(slide, "免费不等于无限：不承诺无限 Agent / VM，也不以“免费”作为唯一卖点。", {
    x: 6.99, y: 5.9, w: 5.5, h: 0.4, fs: 7.8, color: C.muted, lh: 10.4, page: 10,
  });

  notes(slide, [
    "排队只控制瞬时并发，不能控制滞留存储、失败重试、预构建与模型 token。",
    "任务前、中、后各有硬控制点；全局预算熔断按日与月双阈值。",
    "两种成本承担路径都需要硬配额：用户自带云账户与 SLIPE 承担免费队列。",
    "熔断时保证本地编辑与同步仍可用，这是连续性承诺的底线。",
  ]);
}

/* ---------------------------------------------------------- 11 unit economics */
{
  const slide = s();
  frame(pptx, slide, {
    no: 11, total, section: "06 / 单位经济",
    claim: "0.24 / 1.00 / 4.25 元：免费边界由规格与成功率决定",
    source: "全部为情景假设：混合计算 ¥1.20/核心小时、模型与其他费用均为假设，不是 SLIPE 采购价或报价；未计研发、支付、税费、退款与客服。",
  });
  const rows = [
    ["情景", "原始成本构成（假设）", "原始合计", "成功率", "每成功任务"],
    [{ text: "轻量检查", options: { bold: true, color: C.ink } }, "0.10 核时 × ¥1.20 + 模型 ¥0.08 + 其他 ¥0.03", "¥0.23", "95%", { text: "¥0.24", options: { bold: true, color: C.pop } }],
    [{ text: "标准构建", options: { bold: true, color: C.ink } }, "0.50 核时 × ¥1.20 + 模型 ¥0.20 + 其他 ¥0.10", "¥0.90", "90%", { text: "¥1.00", options: { bold: true, color: C.pop } }],
    [{ text: "重型构建", options: { bold: true, color: C.ink } }, "2.00 核时 × ¥1.20 + 模型 ¥0.60 + 其他 ¥0.40", "¥3.40", "80%", { text: "¥4.25", options: { bold: true, color: C.pop } }],
  ];
  table(slide, {
    x: M, y: 1.62, w: 7.1, colW: [1.35, 2.9, 0.95, 0.7, 1.2],
    data: rows, rowH: [0.4, 0.62, 0.62, 0.62], fs: 8.2, pad: 0.06, page: 11, label: "cost",
  });
  text(slide, "“其他”含存储、流量与日志；每成功任务 = 原始合计 ÷ 成功率（轻量四舍五入）。", {
    x: M, y: 4.0, w: 7.0, h: 0.34, fs: 7.3, color: C.dim, lh: 9.6, page: 11,
  });

  text(slide, "元 / 每成功任务", { x: 7.95, y: 1.6, w: 4.3, h: 0.2, fs: 7.4, color: C.muted, page: 11 });
  slide.addChart(pptx.ChartType.bar, [{
    name: "每成功任务成本", labels: ["轻量检查", "标准构建", "重型构建"], values: [0.24, 1.0, 4.25],
  }], {
    x: 7.95, y: 1.8, w: 4.76, h: 2.62,
    barDir: "col", barGapWidthPct: 55,
    chartColors: [C.accent],
    chartArea: { fill: { color: C.panel }, border: { color: C.rule, pt: 0.5 }, roundedCorners: false },
    plotArea: { fill: { color: C.panel }, border: { type: "none" } },
    showLegend: false, showValue: true,
    dataLabelColor: C.ink, dataLabelFontSize: 9, dataLabelFontFace: F.mono,
    dataLabelFormatCode: "¥0.00", dataLabelPosition: "outEnd",
    catAxisLabelColor: C.muted, catAxisLabelFontSize: 7.6, catAxisLabelFontFace: F.cjk,
    catAxisLineShow: false, valAxisHidden: true, valAxisLineShow: false,
    valGridLine: { style: "none" },
  });

  const rec = [
    ["16%", "4 次标准构建 / 月", "免费成本 ¥4；月净收入假设 ¥25，需 16% 付费转化才能覆盖。", "RECOVERY / HIGH USAGE"],
    ["4%", "1 次标准构建 / 月", "免费成本 ¥1；同一净收入假设下，所需转化约 4%。", "RECOVERY / LOW USAGE"],
  ];
  rec.forEach(([pct, title, body, label], i) => {
    const x = M + i * 6.19;
    panel(slide, x, 4.62, 5.9, 1.76, { topRule: C.accent, page: 11 });
    kicker(slide, label, { x: x + 0.22, y: 4.74, w: 3.4, fs: 6.8 });
    token(slide, pct, { x: x + 0.22, y: 4.98, w: 1.05, h: 0.48, fs: 30, color: C.ink });
    text(slide, title, { x: x + 1.35, y: 4.98, w: 4.2, h: 0.22, fs: 9.2, bold: true, page: 11 });
    text(slide, body, { x: x + 1.35, y: 5.24, w: 4.25, h: 0.5, fs: 8.2, color: C.muted, lh: 11, page: 11 });
    text(slide, "数学情景，不是转化预测；配额与任务类型比“免费”标签更关键。", {
      x: x + 0.22, y: 5.9, w: 5.4, h: 0.3, fs: 7.2, color: C.dim, page: 11,
    });
  });
  text(slide, "免费量必须可调价：更高配额、优先队列、更长结果保留都可成为 Pro 的价值，而不是无限赠送。", {
    x: M, y: 6.48, w: 11.9, h: 0.22, fs: 7.9, color: C.muted, page: 11,
  });

  notes(slide, [
    "三档假设任务：轻量检查 0.23 元原始 / 95% → 0.24；标准构建 0.90 / 90% → 1.00；重型构建 3.40 / 80% → 4.25。",
    "回收示例：每月 4 次标准构建，免费成本 4 元；月净收入假设 25 元，需要 16% 付费转化；每月 1 次只需要约 4%。",
    "两者都是数学情景，不是转化预测；说明配额与任务类型比“免费”标签更关键。",
    "混合计算单价 1.20 元/核心小时为假设，不是采购价。",
  ]);
}

/* -------------------------------------------------------------- 12 roadmap */
{
  const slide = s();
  frame(pptx, slide, {
    no: 12, total, section: "07 / 未来规划",
    claim: "三阶段扩张，每个阶段都先写清退出条件",
    source: "时间、数量与阶段目标均为建议规划，不是交付承诺；门槛未通过应延长当前阶段或缩减范围。",
  });
  hairline(slide, M, 1.82, CW, { color: C.rule });
  const phases = [
    ["01", "0—3 月", "连续性验证", "跨端个人开发者与真实项目种子社群", "桌面核心工作流补齐；同步恢复；DSH Alpha；3 个精选插件候选完成审查与移植验证。", "受控异步任务；外部按量为主；任务成本日志；Pro 仅做价格研究。", "North Star、W4 留存、任务成功、成本与恢复同时达到内部门槛。"],
    ["02", "3—9 月", "桌面增长", "扩大低配置与既有项目用户；测试 Pro。", "桌面候选发布；10—20 个精选兼容项（建议目标）；自助迁移指南与兼容看板。", "按证据开放更多任务；有限交互式工作区试点；共享 / 自有节点小规模 TCO 对照。", "桌面留存不低于跨端基线；插件维护可控；Pro 净收入改善单位经济。"],
    ["03", "9—18 月", "生态与团队", "小型团队、区域化分发与生态合作。", "稳定 SLIPE API、签名提交、权限与版本审核；团队共享插件与集中治理。", "区域云与团队试点；只有 TCO 优胜才扩大自主算力。", "团队续费、生态活跃、区域合规与供应韧性支持持续扩张。"],
  ];
  phases.forEach(([no, period, title, market, product, cloud, gate], i) => {
    const x = M + i * 4.11;
    rect(slide, x + 0.0, 1.77, 0.08, 0.08, { fill: C.pop, line: null });
    token(slide, period, { x: x + 0.16, y: 1.68, w: 1.2, h: 0.2, fs: 8.6, color: C.ink });
    token(slide, no, { x: x + 3.4, y: 1.7, w: 0.35, h: 0.18, fs: 7.4, color: C.dim, align: "right" });

    panel(slide, x, 2.02, 3.87, 4.3, { page: 12 });
    text(slide, title, { x: x + 0.22, y: 2.16, w: 3.4, h: 0.28, fs: 12.5, bold: true, page: 12 });
    hairline(slide, x + 0.22, 2.52, 3.42, { color: C.ruleSoft, pt: 0.5 });
    const fields = [
      ["市场目标", market, 0.6],
      ["产品 / 生态", product, 0.92],
      ["云与商业化", cloud, 0.84],
    ];
    let fy = 2.62;
    fields.forEach(([label, body, h]) => {
      text(slide, label, { x: x + 0.22, y: fy, w: 3.4, h: 0.18, fs: 6.8, color: C.accent, page: 12 });
      text(slide, body, { x: x + 0.22, y: fy + 0.19, w: 3.42, h, fs: 8, color: C.muted, lh: 10.7, page: 12 });
      fy += h + 0.29;
    });
    hairline(slide, x + 0.22, 5.42, 3.42, { color: C.rule });
    token(slide, "门槛", { x: x + 0.22, y: 5.52, w: 0.42, h: 0.18, fs: 7, color: C.pop });
    text(slide, gate, { x: x + 0.7, y: 5.5, w: 2.95, h: 0.7, fs: 7.4, color: C.ink, lh: 9.8, page: 12 });
  });

  notes(slide, [
    "0—3 月：连续性验证，桌面核心工作流、同步恢复、DSH Alpha、3 个插件候选。",
    "3—9 月：桌面增长，桌面候选发布，10—20 个精选兼容项为建议目标，测试 Pro。",
    "9—18 月：生态与团队，稳定 API、签名提交、权限与版本审核，区域云与团队试点。",
    "每一阶段都有进入下一阶段的门槛；不达标就延长或缩减，不按时间表硬推。",
  ]);
}

/* ------------------------------------------------------- 13 ecosystem tests */
{
  const slide = s();
  frame(pptx, slide, {
    no: 13, total, section: "07 / 生态兼容",
    claim: "生态不做全量兼容：DSH 锁版本，插件按四级放行",
    source: "来源：VS Code Extension Host 与 Web Extensions 文档 [13][14]；社区 Harness 连接器 [15][16]。不宣称全量插件兼容或 DeepSeek 官方背书。",
  });
  kicker(slide, "DEEPSEEK HARNESS / 6 TESTS", { x: M, y: 1.62, w: 3.4, fs: 6.9 });
  text(slide, "六项兼容测试，先锁版本再谈适配", { x: M, y: 1.82, w: 6.0, h: 0.26, fs: 11, bold: true, page: 13 });
  const tests = [
    ["版本", "锁定 Harness、连接器与 SLIPE 的已测组合与回退策略。"],
    ["启动与认证", "最小权限流程，不默认读取含模型密钥的凭据文件。"],
    ["工作区与 RPC", "端点发现、超时、重连与错误提示。"],
    ["远程执行", "远程 / 容器、端口转发、权限与撤销。"],
    ["会话与差异", "审批、问题、差异审查、取消与恢复。"],
    ["界面嵌入", "拖放、链接、剪贴板与各端交互差异。"],
  ];
  tests.forEach(([label, body], i) => {
    const y = 2.18 + i * 0.56;
    token(slide, String(i + 1).padStart(2, "0"), { x: M, y, w: 0.3, h: 0.18, fs: 7.4, color: C.pop });
    text(slide, [
      { text: `${label}  `, options: { bold: true, color: C.ink } },
      { text: body, options: { color: C.muted } },
    ], { x: M + 0.34, y, w: 5.9, h: 0.44, fs: 8.2, lh: 11, page: 13 });
    if (i < tests.length - 1) hairline(slide, M, y + 0.47, 6.2, { color: C.ruleSoft, pt: 0.5 });
  });
  text(slide, "社区连接器已体现上述适配深度，但不是 DeepSeek 官方稳定接口或背书。", {
    x: M, y: 5.58, w: 6.2, h: 0.34, fs: 7.2, color: C.dim, page: 13,
  });

  kicker(slide, "VS CODE EXTENSIONS / GRADES", { x: 7.2, y: 1.62, w: 3.6, fs: 6.9 });
  text(slide, "四级移植 + 四项准入", { x: 7.2, y: 1.82, w: 5.0, h: 0.26, fs: 11, bold: true, page: 13 });
  const gradeRows = [
    ["等级", "处理方式"],
    [{ text: "L1 静态贡献", options: { bold: true, color: C.ink } }, "主题、片段、语法等声明式贡献优先"],
    [{ text: "L2 Web 可运行", options: { bold: true, color: C.ink } }, "浏览器沙箱适配，不直接依赖 Node API"],
    [{ text: "L3 Node / 远程", options: { bold: true, color: C.ink } }, "需扩展宿主、进程、文件与网络边界"],
    [{ text: "L4 设备 / UI", options: { bold: true, color: C.ink } }, "依赖特定设备、Webview 或原生能力，逐端验收"],
  ];
  table(slide, {
    x: 7.2, y: 2.16, w: 5.51, colW: [1.25, 4.26],
    data: gradeRows, rowH: [0.32, 0.42, 0.42, 0.42, 0.42], fs: 8, pad: 0.05, page: 13, label: "grades",
  });
  text(slide, "四项准入：每项都先过", { x: 7.2, y: 4.28, w: 3.4, h: 0.2, fs: 7.4, color: C.accent, page: 13 });
  const gates = ["许可证", "所需 API", "Node 依赖", "分发权限"];
  gates.forEach((g, i) => {
    const x = 7.2 + i * 1.3;
    rect(slide, x, 4.52, 1.2, 0.3, { fill: C.panel, line: C.rule });
    text(slide, g, { x, y: 4.57, w: 1.2, h: 0.2, fs: 7.4, color: C.ink, align: "center", page: 13 });
  });
  text(slide, "Web 扩展与本地 / 远程宿主边界不同；未经审查不承诺具体插件可移植或再分发。可从格式化、Lint、Git 历史等高频类别选候选。", {
    x: 7.2, y: 4.96, w: 5.5, h: 0.54, fs: 7.4, color: C.muted, lh: 9.8, page: 13,
  });

  panel(slide, M, 6.06, CW, 0.56, { leftRule: C.pop, page: 13 });
  text(slide, "生态北极星不是移植数量：看插件周活跃项目、任务成功率、兼容缺陷、移植周期与升级维护工时；低使用、高维护的插件退出官方清单。", {
    x: M + 0.2, y: 6.13, w: CW - 0.4, h: 0.42, fs: 8.1, color: C.ink, lh: 10.6, page: 13,
  });

  notes(slide, [
    "DSH 六项测试：版本、启动认证、工作区 RPC、远程执行、会话差异、界面嵌入。",
    "VS Code 插件四级：L1 静态贡献、L2 Web 可运行、L3 Node/远程、L4 设备/UI；每级都要过许可证、所需 API、Node 依赖、分发权限。",
    "社区 Harness 连接器是独立项目，不是 DeepSeek 官方接口或背书；不宣称全量插件兼容。",
  ]);
}

/* --------------------------------------------------------- 14 metrics/risks */
{
  const slide = s();
  frame(pptx, slide, {
    no: 14, total, section: "08 / 指标与风险",
    claim: "增长、体验、成本必须一起过会，任一越界就停",
    source: "North Star 与指标树为本报告建议；阈值需在 D30 基线后复核。风险信号与动作见主报告第 08、09 章。",
  });
  panel(slide, M, 1.62, CW, 0.92, { leftRule: C.pop, page: 14 });
  kicker(slide, "NORTH STAR", { x: M + 0.24, y: 1.74, w: 2.0, color: C.pop, fs: 7 });
  text(slide, "每周跨至少两类设备完成有效编辑或构建的活跃项目数", {
    x: M + 0.24, y: 1.96, w: 11.2, h: 0.34, fs: 15, bold: true, page: 14,
  });

  const kpi = [
    ["层", "核心指标", "节奏 / 用途"],
    [{ text: "激活", options: { bold: true, color: C.ink } }, "首个有效项目率；7 日第二设备激活率；首次成功任务耗时", "每周 / 调渠道与 onboarding"],
    [{ text: "留存", options: { bold: true, color: C.ink } }, "W4 跨端活跃项目 ÷ 跨端激活队列；恢复后继续任务率", "每周 / 决定是否放量"],
    [{ text: "体验", options: { bold: true, color: C.ink } }, "同步与云任务成功率、冲突率、P50/P95 等待、取消原因", "每日 / 容量与降级"],
    [{ text: "成本", options: { bold: true, color: C.ink } }, "每成功任务全成本、每激活项目免费成本、预算偏差", "每日 / 配额与供应"],
    [{ text: "商业", options: { bold: true, color: C.ink } }, "分渠道激活 CAC、付费转化、退款后净收入、回收期", "每月 / 定价与退出"],
  ];
  table(slide, {
    x: M, y: 2.7, w: 6.85, colW: [0.95, 4.3, 1.6],
    data: kpi, rowH: [0.34, 0.5, 0.5, 0.5, 0.5, 0.5], fs: 7.8, pad: 0.05, page: 14, label: "kpi",
  });

  kicker(slide, "STOP RULES / 何时停", { x: 7.7, y: 2.7, w: 2.6, fs: 6.9 });
  text(slide, "四个触发信号与立即动作", { x: 7.7, y: 2.9, w: 4.9, h: 0.24, fs: 10.8, bold: true, page: 14 });
  const risks = [
    ["免费成本失控", "熔断新任务、缩配额与类型、回收环境"],
    ["桌面体验不达标", "暂停放量，集中修核心工作流"],
    ["同步或迁移失败", "限制新同步项目，完成迁移与恢复演练"],
    ["插件维护失控", "缩减官方清单，标记限制或停止维护"],
  ];
  risks.forEach(([risk, action], i) => {
    const y = 3.22 + i * 0.6;
    text(slide, risk, { x: 7.7, y, w: 2.0, h: 0.22, fs: 8.6, bold: true, color: C.ink, page: 14 });
    text(slide, "→", { x: 9.72, y, w: 0.22, h: 0.22, fs: 8.6, color: C.pop, page: 14 });
    text(slide, action, { x: 9.98, y, w: 2.68, h: 0.46, fs: 7.6, color: C.muted, lh: 9.8, page: 14 });
    if (i < risks.length - 1) hairline(slide, 7.7, y + 0.5, 4.95, { color: C.ruleSoft, pt: 0.5 });
  });
  text(slide, "另有上游价格、数据合规与渠道错配三类，进入周度监测与月度复盘。", {
    x: 7.7, y: 5.7, w: 4.95, h: 0.3, fs: 7.2, color: C.dim, page: 14,
  });

  hairline(slide, M, 5.94, CW, { color: C.rule });
  kicker(slide, "CADENCE / 单一事实源", { x: M, y: 6.02, w: 2.8, color: C.accent, fs: 6.8 });
  text(slide, [
    { text: "每日 ", options: { bold: true, color: C.ink } },
    { text: "预算、异常任务、失败率与队列  ·  ", options: { color: C.muted } },
    { text: "每周 ", options: { bold: true, color: C.ink } },
    { text: "North Star、渠道、跨端漏斗、插件缺陷  ·  ", options: { color: C.muted } },
    { text: "每月 ", options: { bold: true, color: C.ink } },
    { text: "单位经济、W4、TCO 与合规", options: { color: C.muted } },
  ], { x: M, y: 6.24, w: 11.9, h: 0.22, fs: 7.8, lh: 10, page: 14 });
  text(slide, "用匿名 / 假名项目 ID 串联产品事件、云任务与账单；分析用途与模型训练用途分离，权限与保留期限按数据地图执行。", {
    x: M, y: 6.5, w: 11.9, h: 0.22, fs: 7.2, color: C.dim, page: 14,
  });

  notes(slide, [
    "North Star：每周跨至少两类设备完成有效编辑或构建的活跃项目数；下载、注册与模型调用只作辅助。",
    "指标树覆盖激活、留存、体验、成本、商业；生态指标在上一页。",
    "四个即刻停止信号：免费成本、桌面体验、同步或迁移、插件维护。",
    "节奏：每日看预算与失败，每周看 North Star 与漏斗，每月看单位经济与合规。",
  ]);
}

/* -------------------------------------------------------- 15 actions/close */
{
  const slide = s();
  frame(pptx, slide, {
    no: 15, total, section: "09 / 行动与来源",
    claim: "接下来 10 个动作，把建议变成可复盘的证据",
    source: "来源：主报告 24 条参考资料（官方定价与文档、项目文件、法规原文、商业估算），均截至 2026-11-12。本页为行动建议，不构成交付承诺。",
  });
  kicker(slide, "NEXT 10 ACTIONS / 0—90 DAYS", { x: M, y: 1.62, w: 4.2, color: C.accent, fs: 6.9 });
  const actions = [
    "指定 North Star 与跨端项目去重口径，剔除测试与异常账号",
    "选 20 个真实项目，建立桌面 / 移动、同步与性能基线",
    "完成任务级模型、计算、存储、流量与失败成本埋点",
    "实现免费任务白名单、配额、超时、取消、停机、回收与全局熔断",
    "验证云端不可用时本地编辑与同步的降级路径",
    "制定数据库迁移、备份、恢复与多实例路线",
    "锁定 DSH 测试版本，完成最小权限与六项兼容矩阵",
    "按四级与四项准入选首批 3 个插件候选，公开限制",
    "启动 30 个深访与三个信息实验，以跨端激活评估",
    "建立周度竞品 / 政策监测与月度单位经济复盘",
  ];
  actions.forEach((action, i) => {
    const col = i < 5 ? 0 : 1;
    const x = M + col * 4.22;
    const y = 1.96 + (i % 5) * 0.86;
    token(slide, String(i + 1).padStart(2, "0"), { x, y, w: 0.32, h: 0.2, fs: 8.4, color: C.pop });
    text(slide, action, { x: x + 0.36, y, w: 3.65, h: 0.68, fs: 8.4, color: C.ink, lh: 11.4, page: 15 });
    if (i % 5 < 4) hairline(slide, x, y + 0.74, 3.95, { color: C.ruleSoft, pt: 0.5 });
  });

  panel(slide, 9.05, 1.94, 3.66, 3.44, { topRule: C.accent, page: 15 });
  kicker(slide, "METHOD & SOURCES", { x: 9.25, y: 2.1, w: 3.2, fs: 6.9 });
  text(slide, "24 条来源，事实与假设分记", { x: 9.25, y: 2.3, w: 3.2, h: 0.44, fs: 10.8, bold: true, lh: 14, page: 15 });
  bulletList(slide, [
    "项目文件：pubspec.yaml、backend/README.md",
    "官方页面：VS Code、Cursor、Replit、Codespaces、Firebase Studio、DeepSeek、Open VSX / Marketplace",
    "法规：生成式 AI 暂行办法、网络数据安全管理条例、GDPR、AI Act、CCPA",
    "商业估算：Morgan Reed Insights（宽口径，非 TAM）",
    "全部信息截至 2026-11-12；公开价格可能变化",
    "无同口径性能、用户、收入、留存与云账单数据",
  ], { x: 9.25, y: 2.82, w: 3.25, fs: 7.2, gap: 0.1, color: C.muted, page: 15 });

  hairline(slide, M, 6.28, CW, { color: C.rule });
  text(slide, "先证明连续性，再买增长。", {
    x: M, y: 6.4, w: 7.0, h: 0.36, fs: 18, bold: true, color: C.pop, page: 15,
  });
  token(slide, "SLIPE · 2026-11-12", { x: W - M - 3.0, y: 6.48, w: 3.0, h: 0.2, fs: 7.6, color: C.dim, align: "right" });

  notes(slide, [
    "10 个动作覆盖口径、基线、成本埋点、硬控制、降级、数据库、DSH、插件、用户研究与监测。",
    "方法：事实（项目文件、官方页面、法规）、假设（预算、单位成本、转化）、决策（定位、门槛、释放）分开记录。",
    "24 条来源均截至 2026-11-12；公开价格可能变化，采购与上线前应复核。",
    "收束句：先证明连续性，再买增长。",
  ]);
}

/* ------------------------------------------------------------------- output */
const out = path.resolve(OUT);
await pptx.writeFile({ fileName: out });
const w = getWarnings();
console.log(`\nwrote ${out}`);
console.log(`slides: ${total}`);
console.log(`layout warnings: ${w.length}`);
w.forEach((m) => console.log(" -", m));
