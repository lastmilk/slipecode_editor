/* SlipCode WorkAdmin —— Vue 3 + Element Plus 管理端 */

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
      if (tab === 'config') this.loadConfig();
      if (tab === 'llm') this.loadModels();
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
        ? { id: row.id, name: row.name, apiBase: row.apiBase, apiKey: row.apiKey, model: row.model, multiplier: row.multiplier || 1 }
        : { id: '', name: '', apiBase: '', apiKey: '', model: '', multiplier: 1 };
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
  },
});

app.use(ElementPlus, { locale: ElementPlusLocaleZhCn });
app.mount('#app');
