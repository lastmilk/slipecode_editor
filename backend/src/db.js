// 数据层：单文件 JSON 存储（原子写入）
//
// 数据量小、单实例部署，用 db.json + 队列写入即可。
// 结构：
//   users / settings / llmModels / projects / chatHistory
//   config  —— 运行期可配置的凭据（极验、阿里云、管理员密码哈希）
//   stats   —— 运营统计（总量 + 按天）

import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

export const DATA_DIR =
  process.env.DATA_DIR || join(__dirname, '..', 'data');
export const DB_FILE = join(DATA_DIR, 'db.json');
/** 用户上传的头像 / 壁纸 */
export const UPLOAD_DIR = join(DATA_DIR, 'uploads');

/**
 * 默认政策文档（用户服务协议 / 隐私政策），Markdown 格式。
 * 管理端编辑后写入 db.config.policies，旧版 db.json 缺失时以本常量兜底。
 */
export const DEFAULT_POLICIES = {
  userAgreement: {
    title: 'SLIPE 用户服务协议',
    version: '1.0.0',
    updatedAt: '',
    content: `## 一、协议的接受与更新

1. 本《SLIPE 用户服务协议》（以下简称"本协议"）是您与我们之间就使用 SLIPE 移动端代码编辑器及相关服务（以下简称"本服务"）所订立的协议。您在注册、登录或以任何方式使用本服务时，即表示您已充分阅读、理解并同意接受本协议的全部条款。
2. 我们可能根据业务发展不时修订本协议。一般性修订将通过应用内公告等方式发布；涉及用户重大权利义务的变更（如服务内容调整、责任限制变化等），我们将通过应用内通知提前告知您。
3. 修订协议生效后，若您继续使用本服务，即视为接受修订后的内容；若您不同意修订内容，应停止使用本服务，并可根据本协议约定注销账号。

## 二、账号注册与安全

1. 您应使用真实、有效的邮箱或手机号注册账号，并设置安全强度足够的密码。因您提供的注册信息不真实、不准确而引发的一切后果，由您自行承担。
2. 您应对账号项下的全部活动负责，包括但不限于项目创建、云端构建、AI 助手调用、积分消耗以及经授权的第三方平台（GitHub、Gitee）操作。
3. 您应妥善保管账号与密码，不得将账号出借、赠与、转让或与他人共用。任何通过您的账号进行的操作均视为您本人行为，但法律另有规定的除外。
4. 若您发现账号被他人盗用或存在异常登录，请立即通过 support@slipe.cn 通知我们。我们将协助您采取合理措施（如重置凭证、临时冻结账号）以减少损失。

## 三、用户行为规范

您在使用本服务时，应遵守中华人民共和国法律法规及本协议约定，不得从事下列行为：

1. 上传、存储或传播违法违规内容，包括危害国家安全、涉恐涉暴、淫秽色情、赌博诈骗、侵害他人合法权益的内容等；
2. 上传或传播恶意代码，包括计算机病毒、木马、蠕虫、挖矿程序等，或利用本服务实施网络攻击、漏洞利用；
3. 上传或传播侵犯他人知识产权、商业秘密或个人信息的内容；
4. 对本服务进行逆向工程、反编译、反汇编，或试图绕过服务限制、破解鉴权机制；
5. 干扰或破坏服务器的正常运行，包括恶意高频请求、暴力破解以及其他自动化滥用行为；
6. 利用本服务从事法律法规禁止的其他活动。

若您违反上述约定，我们有权视情节轻重采取警示、限制功能、暂停服务、封禁账号等措施，并保留依法追究责任的权利。

## 四、服务内容

1. 本服务目前包括：移动端代码编辑器（代码浏览、编辑与语法高亮）、基于 GitHub Actions 与 Gitee Go 的云端构建、AI 编程助手、项目云同步等，具体以应用内实际提供的功能为准。
2. 云端构建需要您授权我们访问您的 GitHub 或 Gitee 账号，以便代您触发构建工作流、读取构建结果并回传产物。
3. AI 助手功能可能依赖第三方模型服务，其可用性与准确性受上游服务影响，生成内容仅供参考，您应在采用前自行核验。
4. 本服务按"现状"与"现有"基础提供，我们不承诺服务持续不中断或完全无缺陷。因系统维护、升级导致的短暂中断，我们会尽量提前公告。

## 五、知识产权

1. 您通过本服务创建、编辑、上传的代码与项目，其全部知识产权归您所有。未经您的授权，我们不会查看、修改您的项目内容，也不会向第三方披露。
2. 为向您提供云同步、云端构建、AI 助手等服务之必需，您授予我们有限、非排他、可撤回的许可，在实现服务功能所必需的范围内处理（含存储、传输）您的内容。
3. 本服务的软件、界面、商标、文档等知识产权归我们或相应权利人所有，未经书面许可，任何人不得复制、传播或将其用于商业用途。

## 六、免责声明与责任限制

1. 您应自行对项目代码与数据进行备份。对因不可抗力、系统故障、存储损坏或其他原因导致的用户代码丢失，我们不承担责任。
2. 在适用法律允许的最大范围内，我们不对任何间接损失、预期利益损失或第三方索赔承担责任；我们的累计赔偿责任不超过您在索赔事项发生前十二个月内就本服务实际支付的费用。
3. 因您违反本协议或法律法规而产生的损失与责任，由您自行承担。

## 七、服务的变更与终止

1. 我们可能新增、调整、中止或终止部分服务功能，重大变更将提前通过应用内通知公告。
2. 您可随时停止使用本服务并申请注销账号。注销后，我们将在合理期限内删除或匿名化处理您的个人信息，法律法规要求留存的除外。
3. 若您严重违反本协议，我们有权暂停或终止继续向您提供服务。

## 八、法律适用与争议解决

1. 本协议的订立、履行与解释，适用中华人民共和国法律。
2. 因本协议产生的任何争议，双方应首先友好协商解决；协商不成的，任何一方均可向我们所在地有管辖权的人民法院提起诉讼。
3. 本协议未尽事宜，依照《SLIPE 隐私政策》及有关法律法规执行。`,
  },
  privacyPolicy: {
    title: 'SLIPE 隐私政策',
    version: '1.0.0',
    updatedAt: '',
    content: `本政策帮助您了解 SLIPE 如何收集、使用、存储和保护您的个人信息。请您仔细阅读，尤其是加粗标注的内容。

## 一、我们收集的信息

1. **注册信息**：邮箱或手机号、昵称、密码。密码仅以加盐哈希后的形式存储，任何人均无法还原明文。
2. **使用数据**：编辑器偏好设置、云同步的项目列表元数据（项目名称、本地路径、关联仓库）、云端构建记录（构建状态、日志摘要、产物信息），以及 AI 对话记录（仅在您主动开启保存时记录，可随时关闭并清空）。
3. **设备信息**：设备型号、操作系统版本与应用版本号，用于兼容性统计与故障排查。
4. **第三方授权令牌**：GitHub / Gitee 的 OAuth 访问令牌，仅用于在您触发云端构建时代您执行仓库操作。

特别说明：

- 您的项目代码内容仅在您主动推送至仓库或开启云同步时传输，我们不会在未经您操作的情况下读取您的代码；
- AI 助手若由您自行填写 API Key，该 Key 仅保存在您的本地设备，不会上传至我们的服务器。

## 二、信息的使用目的

1. 提供与改进服务：实现账号登录、偏好同步、云端构建、AI 助手等核心功能，并基于使用情况优化产品体验。
2. 保障账号安全：身份验证、异常登录检测、防止恶意注册与批量滥用。
3. 服务通知：发送验证码、安全提醒与重大服务变更通知，我们不会以此进行营销骚扰。
4. 匿名化统计：了解功能使用情况以指导产品迭代，统计结果不指向任何特定用户。

## 三、存储与保护

1. 您的数据存储于我们管理的服务器，传输过程采用加密通道。
2. 密码使用加盐哈希算法处理，即使数据库泄露也无法直接得到您的明文密码。
3. 我们采取访问控制、操作审计、最小权限分工等技术与管理措施保护您的信息。
4. 我们仅在实现本政策所述目的所必需的期限内保存您的信息，超出期限后予以删除或匿名化处理。
5. 我们不会主动向任何第三方出售您的个人信息。

## 四、共享与披露

1. **您授权的第三方平台**：在您绑定 GitHub / Gitee 并触发云端构建时，我们在必要范围内向相应平台提交构建请求与仓库操作指令。
2. **法律法规要求**：在法律法规、司法机关或行政机关作出强制性要求时，我们可能披露必要的信息，并尽可能提前通知您。
3. 除上述情形外，未经您的另行同意，我们不会向任何第三方提供您的个人信息。

## 五、您的权利

1. 查询与更正：您可在应用内随时查看并修改昵称、头像等个人资料。
2. 删除与注销：您可以删除项目、清空对话记录，或申请注销账号；注销后我们将在合理期限内删除您的个人信息（法律法规要求留存的除外）。
3. 撤回授权：您可以随时解除 GitHub / Gitee 绑定、关闭云同步或关闭 AI 记录。
4. 联系我们：行使上述权利或对本政策有任何疑问，请发送邮件至 support@slipe.cn，我们将在十五个工作日内回复。

## 六、未成年人保护

1. 本服务面向具备完全民事行为能力的开发者群体，未成年人应在监护人的指导下使用本服务。
2. 若我们发现在未取得监护人同意的情况下收集了未成年人的个人信息，将尽快删除相关数据。
3. 监护人如发现未成年人不当使用本服务，可通过 support@slipe.cn 与我们联系。

## 七、政策更新

我们可能适时修订本政策。发生重大变更时，将通过应用内通知等方式告知您；若您在修订生效后继续使用本服务，即视为接受修订后的政策。您可随时查看本政策的现行版本与生效日期。`,
  },
};

const DEFAULT_DB = {
  users: [],
  settings: {},
  llmModels: [],
  projects: {},
  chatHistory: {},
  // 管理员发布的使用文档（Markdown）
  docs: [],
  // 官网下载的最新安装包元数据（文件存 DATA_DIR/releases/）
  release: null,
  // 社区 Payload 包（用户发布，需管理端审核通过后公开）
  community: [],
  // 积分激活码（管理端生成，用户兑换）
  activationCodes: [],
  // 运行期配置（优先级高于环境变量，便于在管理端热更新）
  config: {
    geetest: {},
    aliyun: {},
    admin: { passwordHash: '' },
    // 面向用户端的运营信息（公开只读）
    portal: { qqGroup: '' },
    // 用户服务协议 / 隐私政策（公开只读，管理端可编辑）
    policies: DEFAULT_POLICIES,
  },
  stats: {
    totals: {
      registers: 0,
      logins: 0,
      smsSent: 0,
      captchaPass: 0,
      captchaFail: 0,
      llmCalls: 0,
      tokensUsed: 0,
    },
    daily: {},
  },
};

let db = structuredClone(DEFAULT_DB);
let writeQueue = Promise.resolve();

/** 当前内存中的数据库对象（只读使用，修改后需调用 saveDb） */
export function getDb() {
  return db;
}

export async function loadDb() {
  await mkdir(DATA_DIR, { recursive: true });
  try {
    const raw = await readFile(DB_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    db = {
      users: Array.isArray(parsed.users) ? parsed.users : [],
      settings:
        parsed.settings && typeof parsed.settings === 'object' ? parsed.settings : {},
      llmModels: Array.isArray(parsed.llmModels) ? parsed.llmModels : [],
      projects:
        parsed.projects && typeof parsed.projects === 'object' ? parsed.projects : {},
      chatHistory:
        parsed.chatHistory && typeof parsed.chatHistory === 'object'
          ? parsed.chatHistory
          : {},
      docs: Array.isArray(parsed.docs) ? parsed.docs : [],
      release:
        parsed.release && typeof parsed.release === 'object' ? parsed.release : null,
      community: Array.isArray(parsed.community) ? parsed.community : [],
      activationCodes: Array.isArray(parsed.activationCodes)
        ? parsed.activationCodes
        : [],
      config: mergeConfig(parsed.config),
      stats: mergeStats(parsed.stats),
    };
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    await saveDb();
  }
}

/** 合并旧版本 db.json 中缺失的字段，保证向后兼容 */
function mergeConfig(raw) {
  const base = structuredClone(DEFAULT_DB.config);
  if (!raw || typeof raw !== 'object') return base;
  return {
    geetest: { ...base.geetest, ...(raw.geetest || {}) },
    aliyun: { ...base.aliyun, ...(raw.aliyun || {}) },
    admin: { ...base.admin, ...(raw.admin || {}) },
    portal: { ...base.portal, ...(raw.portal || {}) },
    policies: {
      userAgreement: { ...base.policies.userAgreement, ...(raw.policies?.userAgreement || {}) },
      privacyPolicy: { ...base.policies.privacyPolicy, ...(raw.policies?.privacyPolicy || {}) },
    },
  };
}

function mergeStats(raw) {
  const base = structuredClone(DEFAULT_DB.stats);
  if (!raw || typeof raw !== 'object') return base;
  return {
    totals: { ...base.totals, ...(raw.totals || {}) },
    daily: raw.daily && typeof raw.daily === 'object' ? raw.daily : {},
  };
}

/** 原子写盘（tmp + rename），并发调用串行执行 */
export function saveDb() {
  writeQueue = writeQueue.then(async () => {
    await mkdir(DATA_DIR, { recursive: true });
    const tmp = `${DB_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(db, null, 2), 'utf8');
    await rename(tmp, DB_FILE);
  });
  return writeQueue;
}

// ---------------------------------------------------------------------------
// 统计埋点
// ---------------------------------------------------------------------------

/** 服务器本地日期，YYYY-MM-DD */
export function todayStr() {
  const d = new Date();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

/**
 * 记录一次统计事件（总量 + 当日）。
 * @param {string} name 事件名，例如 registers / logins / smsSent
 * @param {number} amount 增量，默认 1
 */
export function bumpStat(name, amount = 1) {
  const stats = db.stats;
  stats.totals[name] = (stats.totals[name] || 0) + amount;
  const today = todayStr();
  const day = (stats.daily[today] ||= {});
  day[name] = (day[name] || 0) + amount;
  // 只保留最近 60 天，避免 db.json 无限增长
  const keys = Object.keys(stats.daily).sort();
  while (keys.length > 60) {
    delete stats.daily[keys.shift()];
  }
}

/** 取最近 N 天的统计序列（缺省补 0） */
export function dailySeries(days = 14) {
  const out = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i -= 1) {
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
      d.getDate(),
    ).padStart(2, '0')}`;
    const value = db.stats.daily[key] || {};
    out.push({
      date: key,
      registers: value.registers || 0,
      logins: value.logins || 0,
      smsSent: value.smsSent || 0,
    });
  }
  return out;
}
