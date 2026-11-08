/* SLIPE WorkAdmin —— Vue 3 + Element Plus 管理端 */

const TOKEN_KEY = 'slipe_admin_token';

const EMPTY_STATS = {
  totals: { registers: 0, logins: 0, smsSent: 0, captchaPass: 0, captchaFail: 0, llmCalls: 0, tokensUsed: 0 },
  today: { registers: 0, logins: 0, smsSent: 0, llmCalls: 0, tokensUsed: 0 },
  daily: [],
  users: { count: 0, newToday: 0, activeToday: 0, credits: 0 },
  content: { llmModels: 0, projects: 0, chatHistories: 0, settings: 0 },
  config: {
    geetest: { captchaId: '', captchaKeyMasked: '', enforce: false, configured: false },
    aliyun: { accessKeyId: '', accessKeySecretMasked: '', signName: '', templateCode: '', devMode: true, configured: false },
  },
  server: { uptimeSeconds: 0, memoryMb: 0, nodeVersion: '' },
};

function readToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || '';
  } catch {
    return '';
  }
}

async function request(path, { method = 'GET', body, password } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  const token = readToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  if (password) headers['X-Admin-Password'] = password;
  const res = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let data = {};
  try {
    data = await res.json();
  } catch {
    data = {};
  }
  if (!res.ok) {
    const err = new Error(data.error || `请求失败（${res.status}）`);
    err.status = res.status;
    throw err;
  }
  return data;
}

const app = Vue.createApp({
  template: '#app-template',

  data() {
    return {
      token: readToken(),
      loginPassword: '',
      loggingIn: false,
      online: true,

      tab: 'overview',
      stats: EMPTY_STATS,
      loadingStats: false,

      users: [],
      usersTotal: 0,
      userQuery: '',
      pageSize: 10,
      currentPage: 1,
      loadingUsers: false,

      cfg: {
        geetest: { captchaId: '', captchaKey: '', enforce: true },
        aliyun: { accessKeyId: '', accessKeySecret: '', signName: '', templateCode: '' },
        portal: { qqGroup: '' },
      },
      cfgInfo: {
        geetest: { captchaKeyMasked: '' },
        aliyun: { accessKeySecretMasked: '', devMode: true },
        admin: { usingDefaultPassword: true },
      },
      pwdForm: { current: '', next: '' },
      loadingConfig: false,
      savingGee: false,
      savingAli: false,
      savingPwd: false,
      savingPortal: false,

      docs: [],
      loadingDocs: false,
      docDialog: false,
      docForm: { id: '', title: '', content: '', published: true },
      savingDoc: false,

      release: null,
      loadingRelease: false,
      releaseDialog: false,
      releaseForm: { version: '', notes: '' },
      uploading: false,
      uploadPercent: 0,

      communityPackages: [],
      communityStatus: 'pending',
      loadingCommunity: false,
      communityDialog: false,
      communityPreview: null,

      policies: {
        userAgreement: { title: '', content: '', version: '', updatedAt: '' },
        privacyPolicy: { title: '', content: '', version: '', updatedAt: '' },
      },
      loadingPolicies: false,
      savingUa: false,
      savingPrivacy: false,

      models: [],
      loadingModels: false,
      modelDialog: false,
      modelForm: { id: '', name: '', apiBase: '', apiKey: '', model: '', multiplier: 1 },
      savingModel: false,

      pwdDialog: false,
      verifyPassword: '',
      targetUser: null,
      loadingDetail: false,
      detail: null,
      detailDialog: false,

      creditsDialog: false,
      creditsUser: null,
      creditsDelta: 100,
      savingCredits: false,

      codes: [],
      codeTotal: 0,
      codePage: 1,
      codePageSize: 20,
      codeStatus: '',
      codeQuery: '',
      codeSummary: { total: 0, unused: 0, used: 0, creditsIssued: 0, creditsRedeemed: 0 },
      loadingCodes: false,
      codeDialog: false,
      codeForm: { credits: 1000, planId: 'standard', count: 5, expiresAt: null, note: '' },
      generatedCodes: [],
      savingCode: false,
      creditPlans: [
        { id: 'trial', name: '体验包', credits: 1000, price: 9.9 },
        { id: 'standard', name: '标准包', credits: 3000, price: 29.9 },
        { id: 'pro', name: '专业包', credits: 10000, price: 89 },
        { id: 'team', name: '团队包', credits: 30000, price: 249 },
      ],
    };
  },

  computed: {
    pagedUsers() {
      const start = (this.currentPage - 1) * this.pageSize;
      return this.users.slice(start, start + this.pageSize);
    },
    uptimeText() {
      const s = Number(this.stats.server.uptimeSeconds) || 0;
      const d = Math.floor(s / 86400);
      const h = Math.floor((s % 86400) / 3600);
      const m = Math.floor((s % 3600) / 60);
      return d ? `${d} 天 ${h} 小时` : `${h} 小时 ${m} 分`;
    },
    chartMax() {
      const values = this.stats.daily.flatMap((d) => [d.registers, d.logins, 0]);
      return Math.max(1, ...values);
    },
  },

  mounted() {
    this.checkSession();
  },

  methods: {
    fmt(value) {
      return Number(value || 0).toLocaleString('zh-CN');
    },
    dateText(value) {
      if (!value) return '-';
      const date = new Date(value);
      if (Number.isNaN(date.getTime())) return String(value);
      const pad = (n) => String(n).padStart(2, '0');
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(
        date.getHours(),
      )}:${pad(date.getMinutes())}`;
    },
    barHeight(value) {
      return `${Math.max(2, (Number(value || 0) / this.chartMax) * 100)}%`;
    },
    placeholderSecret(masked) {
      return masked ? `已配置 ${masked}（留空不修改）` : '未配置，请输入';
    },

    handleError(err) {
      if (err.status === 401) {
        this.logout(true);
        ElementPlus.ElMessage.warning('登录已过期，请重新登录');
        return;
      }
      ElementPlus.ElMessage.error(err.message || '操作失败');
    },

    async checkSession() {
      if (!this.token) return;
      try {
        await request('/api/admin/session');
        this.online = true;
        this.loadStats();
      } catch (err) {
        this.online = false;
        if (err.status === 401) this.logout(true);
      }
    },

    async login() {
      if (!this.loginPassword) {
        ElementPlus.ElMessage.warning('请输入管理员密码');
        return;
      }
      this.loggingIn = true;
      try {
        const data = await request('/api/admin/login', {
          method: 'POST',
          body: { password: this.loginPassword },
        });
        try {
          localStorage.setItem(TOKEN_KEY, data.token);
        } catch {
          /* 忽略存储失败 */
        }
        this.token = data.token;
        this.loginPassword = '';
        this.online = true;
        ElementPlus.ElMessage.success('登录成功');
        if (data.mustChangePassword) {
          ElementPlus.ElMessage.warning('当前仍使用默认管理员密码，请尽快在「凭据配置」中修改');
        }
        this.loadStats();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loggingIn = false;
      }
    },

    logout(silent = false) {
      try {
        localStorage.removeItem(TOKEN_KEY);
      } catch {
        /* 忽略 */
      }
      this.token = '';
      this.verifyPassword = '';
      this.detail = null;
      this.targetUser = null;
      if (silent !== true) ElementPlus.ElMessage.success('已退出登录');
    },

    selectTab(tab) {
      this.tab = tab;
      if (tab === 'overview') this.loadStats();
      if (tab === 'users') this.loadUsers();
      if (tab === 'activation') this.loadCodes();
      if (tab === 'config') this.loadConfig();
      if (tab === 'llm') this.loadModels();
      if (tab === 'docs') this.loadDocs();
      if (tab === 'releases') this.loadRelease();
      if (tab === 'community') this.loadCommunity();
      if (tab === 'policies') this.loadPolicies();
    },

    async loadStats() {
      this.loadingStats = true;
      try {
        this.stats = await request('/api/admin/stats');
        this.online = true;
      } catch (err) {
        this.online = false;
        this.handleError(err);
      } finally {
        this.loadingStats = false;
      }
    },

    async loadUsers() {
      this.loadingUsers = true;
      try {
        const query = this.userQuery.trim();
        const data = await request(`/api/admin/users${query ? `?q=${encodeURIComponent(query)}` : ''}`);
        this.users = data.users || [];
        this.usersTotal = data.total || this.users.length;
        const maxPage = Math.max(1, Math.ceil(this.usersTotal / this.pageSize));
        if (this.currentPage > maxPage) this.currentPage = maxPage;
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingUsers = false;
      }
    },

    onPageChange(page) {
      this.currentPage = page;
    },

    async loadConfig() {
      this.loadingConfig = true;
      try {
        const data = await request('/api/admin/config');
        this.cfgInfo = {
          geetest: { captchaKeyMasked: data.geetest.captchaKeyMasked || '' },
          aliyun: {
            accessKeySecretMasked: data.aliyun.accessKeySecretMasked || '',
            devMode: Boolean(data.aliyun.devMode),
          },
          admin: { usingDefaultPassword: Boolean(data.admin.usingDefaultPassword) },
        };
        this.cfg.geetest = {
          captchaId: data.geetest.captchaId || '',
          captchaKey: '',
          enforce: Boolean(data.geetest.enforce),
        };
        this.cfg.aliyun = {
          accessKeyId: data.aliyun.accessKeyId || '',
          accessKeySecret: '',
          signName: data.aliyun.signName || '',
          templateCode: data.aliyun.templateCode || '',
        };
        this.cfg.portal = { qqGroup: (data.portal && data.portal.qqGroup) || '' };
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingConfig = false;
      }
    },

    async saveGeetest() {
      this.savingGee = true;
      try {
        await request('/api/admin/config', {
          method: 'PUT',
          body: { geetest: { ...this.cfg.geetest } },
        });
        ElementPlus.ElMessage.success('极验配置已保存');
        await this.loadConfig();
        await this.loadStats();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingGee = false;
      }
    },

    async saveAliyun() {
      this.savingAli = true;
      try {
        await request('/api/admin/config', {
          method: 'PUT',
          body: { aliyun: { ...this.cfg.aliyun } },
        });
        ElementPlus.ElMessage.success('阿里云配置已保存');
        await this.loadConfig();
        await this.loadStats();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingAli = false;
      }
    },

    async saveAdminPassword() {
      if (!this.pwdForm.current) {
        ElementPlus.ElMessage.warning('请先输入当前密码');
        return;
      }
      if ((this.pwdForm.next || '').length < 8) {
        ElementPlus.ElMessage.warning('新密码至少 8 位');
        return;
      }
      this.savingPwd = true;
      try {
        await request('/api/admin/config', {
          method: 'PUT',
          body: { adminPassword: this.pwdForm.next, currentAdminPassword: this.pwdForm.current },
        });
        ElementPlus.ElMessage.success('管理员密码已修改，请重新登录');
        this.pwdForm = { current: '', next: '' };
        this.logout(true);
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingPwd = false;
      }
    },

    askDetail(row) {
      this.targetUser = row;
      this.verifyPassword = '';
      this.pwdDialog = true;
    },

    async confirmDetail() {
      if (!this.targetUser) return;
      if (!this.verifyPassword) {
        ElementPlus.ElMessage.warning('请输入管理员密码');
        return;
      }
      this.loadingDetail = true;
      try {
        this.detail = await request(`/api/admin/users/${encodeURIComponent(this.targetUser.id)}`, {
          password: this.verifyPassword,
        });
        this.pwdDialog = false;
        this.detailDialog = true;
        this.verifyPassword = '';
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingDetail = false;
      }
    },

    openCredits(row) {
      if (!row) return;
      this.creditsUser = row;
      this.creditsDelta = 100;
      this.creditsDialog = true;
    },

    async saveCredits() {
      if (!this.creditsUser) return;
      const delta = Number(this.creditsDelta);
      if (!Number.isInteger(delta) || delta === 0) {
        ElementPlus.ElMessage.warning('请输入非零整数');
        return;
      }
      this.savingCredits = true;
      try {
        const data = await request(`/api/admin/users/${encodeURIComponent(this.creditsUser.id)}/credits`, {
          method: 'POST',
          body: { delta },
        });
        ElementPlus.ElMessage.success(`已调整，当前 ${data.credits} 积分`);
        this.creditsDialog = false;
        if (this.detail && this.detail.user.id === data.id) this.detail.user.credits = data.credits;
        await this.loadUsers();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingCredits = false;
      }
    },

    async loadModels() {
      this.loadingModels = true;
      try {
        const data = await request('/api/admin/llm/models');
        this.models = data.models || [];
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingModels = false;
      }
    },

    openModelDialog(row) {
      this.modelForm = row
        ? { id: row.id, name: row.name, apiBase: row.apiBase, apiKey: row.apiKey, model: row.model, multiplier: row.multiplier || 1, description: row.description || '' }
        : { id: '', name: '', apiBase: '', apiKey: '', model: '', multiplier: 1, description: '' };
      this.modelDialog = true;
    },

    async saveModel() {
      const form = this.modelForm;
      if (!form.name || !form.apiBase || !form.apiKey || !form.model) {
        ElementPlus.ElMessage.warning('名称 / API Base / API Key / 模型均不能为空');
        return;
      }
      this.savingModel = true;
      try {
        if (form.id) {
          await request(`/api/admin/llm/models/${encodeURIComponent(form.id)}`, {
            method: 'PUT',
            body: { ...form },
          });
        } else {
          await request('/api/admin/llm/models', { method: 'POST', body: { ...form } });
        }
        ElementPlus.ElMessage.success('已保存');
        this.modelDialog = false;
        await this.loadModels();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingModel = false;
      }
    },

    async removeModel(row) {
      try {
        await ElementPlus.ElMessageBox.confirm(`确定删除模型「${row.name}」？`, '删除确认', {
          type: 'warning',
          confirmButtonText: '删除',
          cancelButtonText: '取消',
        });
      } catch {
        return;
      }
      try {
        await request(`/api/admin/llm/models/${encodeURIComponent(row.id)}`, { method: 'DELETE' });
        ElementPlus.ElMessage.success('已删除');
        await this.loadModels();
      } catch (err) {
        this.handleError(err);
      }
    },

    codeStatusText(row) {
      if (row.usedAt) return '已使用';
      if (row.disabled) return '已停用';
      return '未使用';
    },
    codeStatusType(row) {
      if (row.usedAt) return 'success';
      if (row.disabled) return 'info';
      return 'warning';
    },
    async loadCodes() {
      this.loadingCodes = true;
      try {
        const params = new URLSearchParams({
          page: String(this.codePage),
          pageSize: String(this.codePageSize),
        });
        if (this.codeStatus) params.set('status', this.codeStatus);
        if (this.codeQuery.trim()) params.set('q', this.codeQuery.trim());
        const data = await request(`/api/admin/activation-codes?${params.toString()}`);
        this.codes = data.codes || [];
        this.codeTotal = data.total || 0;
        if (data.summary) this.codeSummary = data.summary;
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingCodes = false;
      }
    },
    onCodePageChange(page) {
      this.codePage = page;
      this.loadCodes();
    },
    openCodeDialog() {
      this.codeForm = { credits: 1000, planId: 'standard', count: 5, expiresAt: null, note: '' };
      this.generatedCodes = [];
      this.codeDialog = true;
    },
    async generateCodes() {
      const form = this.codeForm;
      if (!form.credits || form.credits <= 0) {
        ElementPlus.ElMessage.warning('请填写有效积分面额');
        return;
      }
      this.savingCode = true;
      try {
        const data = await request('/api/admin/activation-codes', {
          method: 'POST',
          body: {
            credits: Number(form.credits),
            count: Number(form.count) || 1,
            planId: form.planId || '',
            expiresAt: form.expiresAt || null,
            note: form.note || '',
          },
        });
        this.generatedCodes = (data.codes || []).map((c) => c.code);
        ElementPlus.ElMessage.success(`已生成 ${this.generatedCodes.length} 张激活码`);
        this.codePage = 1;
        await this.loadCodes();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingCode = false;
      }
    },
    async toggleCode(row) {
      try {
        await request(`/api/admin/activation-codes/${encodeURIComponent(row.id)}/toggle`, {
          method: 'POST',
        });
        ElementPlus.ElMessage.success(row.disabled ? '已启用' : '已停用');
        await this.loadCodes();
      } catch (err) {
        this.handleError(err);
      }
    },
    async removeCode(row) {
      try {
        await ElementPlus.ElMessageBox.confirm(`确定删除激活码 ${row.code}？`, '删除确认', {
          type: 'warning',
          confirmButtonText: '删除',
          cancelButtonText: '取消',
        });
      } catch {
        return;
      }
      try {
        await request(`/api/admin/activation-codes/${encodeURIComponent(row.id)}`, {
          method: 'DELETE',
        });
        ElementPlus.ElMessage.success('已删除');
        await this.loadCodes();
      } catch (err) {
        this.handleError(err);
      }
    },
    async copyText(text) {
      try {
        await navigator.clipboard.writeText(text);
        ElementPlus.ElMessage.success('已复制');
      } catch {
        ElementPlus.ElMessage.warning('复制失败，请手动选择文本');
      }
    },
    copyAllCodes() {
      this.copyText(this.generatedCodes.join('\n'));
    },
    async loadDocs() {
      this.loadingDocs = true;
      try {
        const data = await request('/api/admin/docs');
        this.docs = data.docs || [];
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingDocs = false;
      }
    },

    openDocDialog(row) {
      this.docForm = row
        ? { id: row.id, title: row.title, content: row.content, published: Boolean(row.published) }
        : { id: '', title: '', content: '', published: true };
      this.docDialog = true;
    },

    async saveDoc() {
      const form = this.docForm;
      if (!form.title.trim()) {
        ElementPlus.ElMessage.warning('标题不能为空');
        return;
      }
      if (!form.content.trim()) {
        ElementPlus.ElMessage.warning('正文不能为空');
        return;
      }
      this.savingDoc = true;
      try {
        if (form.id) {
          await request(`/api/admin/docs/${encodeURIComponent(form.id)}`, {
            method: 'PUT',
            body: { ...form },
          });
        } else {
          await request('/api/admin/docs', { method: 'POST', body: { ...form } });
        }
        ElementPlus.ElMessage.success('已保存');
        this.docDialog = false;
        await this.loadDocs();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingDoc = false;
      }
    },

    async toggleDocPublished(row) {
      try {
        await request(`/api/admin/docs/${encodeURIComponent(row.id)}`, {
          method: 'PUT',
          body: { published: !row.published },
        });
        ElementPlus.ElMessage.success(row.published ? '已下架' : '已发布');
        await this.loadDocs();
      } catch (err) {
        this.handleError(err);
      }
    },

    async removeDoc(row) {
      try {
        await ElementPlus.ElMessageBox.confirm(`确定删除文档「${row.title}」？`, '删除确认', {
          type: 'warning',
          confirmButtonText: '删除',
          cancelButtonText: '取消',
        });
      } catch {
        return;
      }
      try {
        await request(`/api/admin/docs/${encodeURIComponent(row.id)}`, { method: 'DELETE' });
        ElementPlus.ElMessage.success('已删除');
        await this.loadDocs();
      } catch (err) {
        this.handleError(err);
      }
    },

    async loadRelease() {
      this.loadingRelease = true;
      try {
        const data = await request('/api/admin/releases');
        this.release = data.release || null;
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingRelease = false;
      }
    },

    openReleaseDialog() {
      this.releaseForm = {
        version: this.release ? this.release.version : '',
        notes: '',
      };
      this.uploadPercent = 0;
      this.releaseDialog = true;
      this.$nextTick(() => {
        if (this.$refs.apkInput) this.$refs.apkInput.value = '';
      });
    },

    uploadRelease() {
      const version = this.releaseForm.version.trim();
      if (!version) {
        ElementPlus.ElMessage.warning('请填写版本号');
        return;
      }
      const input = this.$refs.apkInput;
      const file = input && input.files && input.files[0];
      if (!file) {
        ElementPlus.ElMessage.warning('请选择 APK 文件');
        return;
      }
      if (file.size > 300 * 1024 * 1024) {
        ElementPlus.ElMessage.warning('安装包超过 300MB 上限');
        return;
      }
      this.uploading = true;
      this.uploadPercent = 0;
      const params = new URLSearchParams({
        version,
        notes: this.releaseForm.notes.trim(),
      });
      const xhr = new XMLHttpRequest();
      xhr.open('POST', `/api/admin/releases?${params.toString()}`);
      xhr.setRequestHeader('Authorization', `Bearer ${readToken()}`);
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable) {
          this.uploadPercent = Math.min(99, Math.round((event.loaded / event.total) * 100));
        }
      };
      xhr.onload = () => {
        this.uploading = false;
        let data = {};
        try {
          data = JSON.parse(xhr.responseText || '{}');
        } catch {
          data = {};
        }
        if (xhr.status >= 200 && xhr.status < 300) {
          this.uploadPercent = 100;
          this.release = data.release || null;
          this.releaseDialog = false;
          ElementPlus.ElMessage.success(`v${version} 已发布，官网下载即时生效`);
          this.loadRelease();
        } else if (xhr.status === 401) {
          this.logout(true);
          ElementPlus.ElMessage.warning('登录已过期，请重新登录');
        } else {
          ElementPlus.ElMessage.error(data.error || `上传失败（${xhr.status}）`);
        }
      };
      xhr.onerror = () => {
        this.uploading = false;
        ElementPlus.ElMessage.error('网络错误，上传失败');
      };
      xhr.send(file);
    },

    async removeRelease() {
      try {
        await ElementPlus.ElMessageBox.confirm(
          '下架后官网将显示「即将发布」，确定下架当前安装包？',
          '下架确认',
          { type: 'warning', confirmButtonText: '下架', cancelButtonText: '取消' },
        );
      } catch {
        return;
      }
      try {
        await request('/api/admin/releases', { method: 'DELETE' });
        this.release = null;
        ElementPlus.ElMessage.success('已下架');
      } catch (err) {
        this.handleError(err);
      }
    },

    communityStatusText(status) {
      if (status === 'approved') return '已通过';
      if (status === 'rejected') return '已驳回';
      return '待审核';
    },
    communityStatusType(status) {
      if (status === 'approved') return 'success';
      if (status === 'rejected') return 'danger';
      return 'warning';
    },

    async loadCommunity() {
      this.loadingCommunity = true;
      try {
        const status = this.communityStatus || 'pending';
        const data = await request(`/api/admin/community/packages?status=${encodeURIComponent(status)}`);
        this.communityPackages = data.packages || [];
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingCommunity = false;
      }
    },

    openCommunityPreview(row) {
      if (!row) return;
      let specText = '';
      try {
        specText = JSON.stringify(row.spec || {}, null, 2);
      } catch {
        specText = '';
      }
      this.communityPreview = { ...row, specText };
      this.communityDialog = true;
    },

    async approveCommunity(row) {
      if (!row) return;
      try {
        await ElementPlus.ElMessageBox.confirm(
          `通过后「${row.name}」将对所有用户公开，确定通过？`,
          '审核通过',
          { type: 'success', confirmButtonText: '通过并公开', cancelButtonText: '取消' },
        );
      } catch {
        return;
      }
      try {
        await request(`/api/admin/community/packages/${encodeURIComponent(row.id)}/review`, {
          method: 'POST',
          body: { action: 'approve' },
        });
        ElementPlus.ElMessage.success('已通过，社区即时可见');
        this.communityDialog = false;
        await this.loadCommunity();
      } catch (err) {
        this.handleError(err);
      }
    },

    async rejectCommunity(row) {
      if (!row) return;
      let note = '';
      try {
        const result = await ElementPlus.ElMessageBox.prompt(
          '请填写驳回原因（作者可在 App 内看到）',
          `驳回「${row.name}」`,
          {
            confirmButtonText: '驳回',
            cancelButtonText: '取消',
            inputType: 'textarea',
            inputPlaceholder: '例如：说明文档不完整 / 与现有 Payload 重复',
          },
        );
        note = (result.value || '').trim();
      } catch {
        return;
      }
      try {
        await request(`/api/admin/community/packages/${encodeURIComponent(row.id)}/review`, {
          method: 'POST',
          body: { action: 'reject', note },
        });
        ElementPlus.ElMessage.success('已驳回');
        this.communityDialog = false;
        await this.loadCommunity();
      } catch (err) {
        this.handleError(err);
      }
    },

    async removeCommunity(row) {
      if (!row) return;
      try {
        await ElementPlus.ElMessageBox.confirm(
          `确定删除社区包「${row.name}」？此操作不可恢复。`,
          '删除确认',
          { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
        );
      } catch {
        return;
      }
      try {
        await request(`/api/admin/community/packages/${encodeURIComponent(row.id)}`, {
          method: 'DELETE',
        });
        ElementPlus.ElMessage.success('已删除');
        this.communityDialog = false;
        await this.loadCommunity();
      } catch (err) {
        this.handleError(err);
      }
    },

    async loadPolicies() {
      this.loadingPolicies = true;
      try {
        const data = await request('/api/admin/policies');
        const empty = { title: '', content: '', version: '', updatedAt: '' };
        this.policies = {
          userAgreement: (data.policies && data.policies.userAgreement) || empty,
          privacyPolicy: (data.policies && data.policies.privacyPolicy) || empty,
        };
      } catch (err) {
        this.handleError(err);
      } finally {
        this.loadingPolicies = false;
      }
    },

    async savePolicy(type) {
      const policy = this.policies[type];
      if (!policy) return;
      if (!policy.title.trim()) {
        ElementPlus.ElMessage.warning('标题不能为空');
        return;
      }
      if (!policy.content.trim()) {
        ElementPlus.ElMessage.warning('正文不能为空');
        return;
      }
      const loadingKey = type === 'userAgreement' ? 'savingUa' : 'savingPrivacy';
      this[loadingKey] = true;
      try {
        const data = await request('/api/admin/policies', {
          method: 'PUT',
          body: {
            type,
            title: policy.title,
            content: policy.content,
            version: policy.version,
          },
        });
        if (data.policy) this.policies[type] = data.policy;
        ElementPlus.ElMessage.success('已保存并发布');
      } catch (err) {
        this.handleError(err);
      } finally {
        this[loadingKey] = false;
      }
    },

    async savePortal() {
      this.savingPortal = true;
      try {
        await request('/api/admin/config', {
          method: 'PUT',
          body: { portal: { qqGroup: this.cfg.portal.qqGroup.trim() } },
        });
        ElementPlus.ElMessage.success('QQ 群号已保存');
        await this.loadConfig();
      } catch (err) {
        this.handleError(err);
      } finally {
        this.savingPortal = false;
      }
    },
  },
});

app.use(ElementPlus, { locale: ElementPlusLocaleZhCn });
app.mount('#app');
