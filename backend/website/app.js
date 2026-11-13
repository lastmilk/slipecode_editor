/* SLIPE 官网交互：版本信息、统计数据、定价切换、社区内容、政策弹窗 */
(function () {
  'use strict';

  // 官网与 API 同源；直接打开本地文件时回退到线上接口
  var API_BASE = location.protocol === 'file:' ? 'https://api.lineregre.com' : '';
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function $(sel, root) {
    return (root || document).querySelector(sel);
  }
  function $$(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }
  function escapeHtml(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
  function formatNumber(n) {
    var num = Number(n);
    if (!Number.isFinite(num)) return '0';
    return num.toLocaleString('zh-CN');
  }
  function formatSize(bytes) {
    var n = Number(bytes);
    if (!Number.isFinite(n) || n <= 0) return '—';
    if (n >= 1024 * 1024 * 1024) return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
    return (n / 1024 / 1024).toFixed(1) + ' MB';
  }
  function formatDate(iso) {
    var d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '—';
    var pad = function (v) { return String(v).padStart(2, '0'); };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }
  function relativeDate(iso) {
    var d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '';
    var diff = Date.now() - d.getTime();
    var day = 24 * 60 * 60 * 1000;
    if (diff < 60 * 60 * 1000) return '刚刚';
    if (diff < day && new Date().getDate() === d.getDate()) return '今天';
    if (diff < day * 2) return '昨天';
    if (diff < day * 30) return Math.floor(diff / day) + ' 天前';
    return formatDate(iso);
  }

  // ---------------------------------------------------------------------------
  // Toast / 复制
  // ---------------------------------------------------------------------------
  var toastTimer = null;
  function toast(message) {
    var el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2200);
  }

  function copyText(text, okMessage) {
    var done = function () { toast(okMessage || '已复制'); };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text, done); });
    } else {
      fallbackCopy(text, done);
    }
  }
  function fallbackCopy(text, done) {
    var input = document.createElement('textarea');
    input.value = text;
    input.setAttribute('readonly', '');
    input.style.position = 'fixed';
    input.style.opacity = '0';
    document.body.appendChild(input);
    input.select();
    try {
      document.execCommand('copy');
      done();
    } catch (err) {
      toast('复制失败，请手动记录：' + text);
    }
    document.body.removeChild(input);
  }

  // ---------------------------------------------------------------------------
  // 导航 / 抽屉
  // ---------------------------------------------------------------------------
  var header = $('#site-header');
  var navToggle = $('#nav-toggle');
  var drawer = $('#mobile-drawer');

  function onScroll() {
    if (!header) return;
    header.classList.toggle('scrolled', window.scrollY > 8);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  function setDrawer(open) {
    if (!drawer || !navToggle) return;
    drawer.hidden = !open;
    navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    navToggle.setAttribute('aria-label', open ? '关闭菜单' : '打开菜单');
    document.body.style.overflow = open ? 'hidden' : '';
  }
  if (navToggle && drawer) {
    navToggle.addEventListener('click', function () {
      setDrawer(drawer.hidden);
    });
    $$('a', drawer).forEach(function (a) {
      a.addEventListener('click', function () { setDrawer(false); });
    });
    window.addEventListener('resize', function () {
      if (window.innerWidth > 960 && !drawer.hidden) setDrawer(false);
    });
  }

  // ---------------------------------------------------------------------------
  // 入场动画
  // ---------------------------------------------------------------------------
  var revealItems = $$('.reveal');
  if ('IntersectionObserver' in window && !reduceMotion) {
    revealItems.forEach(function (el) { el.classList.add('is-pending'); });
    var revealObs = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-in');
          revealObs.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    revealItems.forEach(function (el) { revealObs.observe(el); });
  }

  // ---------------------------------------------------------------------------
  // 统计数字滚动
  // ---------------------------------------------------------------------------
  var statEls = $$('[data-stat]');
  function paintStat(el, value) {
    el.textContent = formatNumber(value);
  }
  function countUp(el, target) {
    if (reduceMotion) { paintStat(el, target); return; }
    var start = performance.now();
    var duration = 1300;
    function frame(now) {
      var p = Math.min(1, (now - start) / duration);
      var eased = 1 - Math.pow(1 - p, 3);
      paintStat(el, Math.round(target * eased));
      if (p < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }
  function runStats(values) {
    statEls.forEach(function (el) {
      var key = el.getAttribute('data-stat');
      var value = Number(values[key]);
      if (!Number.isFinite(value)) value = Number(el.getAttribute('data-fallback')) || 0;
      countUp(el, value);
    });
  }
  if (statEls.length) {
    var statHost = $('.stats-strip');
    if ('IntersectionObserver' in window) {
      var statObs = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting) {
          runStats(window.__slipeStats || {});
          statObs.disconnect();
        }
      }, { threshold: 0.3 });
      statObs.observe(statHost);
    } else {
      runStats({});
    }
  }

  // ---------------------------------------------------------------------------
  // 顶部卡片光晕跟随
  // ---------------------------------------------------------------------------
  if (window.matchMedia('(hover: hover)').matches && !reduceMotion) {
    $$('.bento-card').forEach(function (card) {
      card.addEventListener('pointermove', function (e) {
        var rect = card.getBoundingClientRect();
        card.style.setProperty('--mx', ((e.clientX - rect.left) / rect.width) * 100 + '%');
        card.style.setProperty('--my', ((e.clientY - rect.top) / rect.height) * 100 + '%');
      });
    });
  }

  // ---------------------------------------------------------------------------
  // 最新版本 / 下载
  // ---------------------------------------------------------------------------
  var releaseState = $('#release-state');
  var releaseVersion = $('#release-version');
  var releaseSize = $('#release-size');
  var releaseDate = $('#release-date');
  var releaseDownloads = $('#release-downloads');
  var releaseNotes = $('#release-notes');
  var releaseSha = $('#release-sha');
  var shaRow = $('#sha-row');
  var copySha = $('#copy-sha');
  var downloadBtn = $('#download-btn');
  var downloadBtnText = $('#download-btn-text');
  var downloadHint = $('#download-hint');
  var heroVersion = $('#hero-version');
  var heroMetaVersion = $('#hero-meta-version');
  var shaValue = '';

  function renderRelease(release) {
    if (!release) {
      if (releaseState) releaseState.textContent = '首个公开版本即将发布';
      if (downloadBtn) downloadBtn.setAttribute('aria-disabled', 'true');
      if (downloadBtnText) downloadBtnText.textContent = '即将发布';
      if (downloadHint) downloadHint.textContent = '版本发布后将在此提供 APK 下载，可先加入社区获取内测。';
      if (heroMetaVersion) heroMetaVersion.textContent = '首个版本';
      return;
    }
    if (releaseState) releaseState.textContent = '最新版本已就绪 · Android APK';
    if (releaseVersion) releaseVersion.textContent = 'v' + release.version;
    if (releaseSize) releaseSize.textContent = formatSize(release.size);
    if (releaseDate) releaseDate.textContent = formatDate(release.updatedAt);
    if (releaseDownloads) releaseDownloads.textContent = formatNumber(release.downloads || 0) + ' 次';
    if (heroVersion) heroVersion.textContent = release.version;
    if (heroMetaVersion) heroMetaVersion.textContent = 'v' + release.version;
    if (downloadBtn) {
      downloadBtn.setAttribute('aria-disabled', 'false');
      downloadBtn.setAttribute('href', API_BASE + '/api/releases/download');
    }
    if (downloadBtnText) downloadBtnText.textContent = '下载 v' + release.version;
    if (releaseNotes && release.notes) {
      releaseNotes.textContent = String(release.notes).slice(0, 260);
    }
    if (release.sha256) {
      shaValue = release.sha256;
      if (releaseSha) releaseSha.textContent = release.sha256;
      if (shaRow) shaRow.hidden = false;
    }
  }

  if (copySha) {
    copySha.addEventListener('click', function () {
      if (shaValue) copyText(shaValue, 'SHA-256 已复制');
    });
  }

  // ---------------------------------------------------------------------------
  // 社区帖子 / 教程
  // ---------------------------------------------------------------------------
  var postsList = $('#posts-list');
  var tracksList = $('#tracks-list');
  var tracksSummary = $('#tracks-summary');

  function renderPosts(posts) {
    if (!postsList) return;
    if (!posts || !posts.length) {
      postsList.innerHTML =
        '<div class="feed-item"><span class="feed-item-title">还没有公开帖子，来社区发第一条。</span>' +
        '<span class="feed-item-meta">COMMUNITY · 等待你的声音</span></div>';
      return;
    }
    postsList.innerHTML = posts.map(function (post) {
      var meta = [
        escapeHtml(post.authorName || '匿名开发者'),
        relativeDate(post.createdAt),
        '♥ ' + formatNumber(post.likes || 0),
        '评论 ' + formatNumber(post.commentCount || 0),
      ].filter(Boolean).join(' · ');
      return '<a class="feed-item" href="#community" title="' + escapeHtml(post.excerpt || post.title) + '">' +
        '<span class="feed-item-title">' + escapeHtml(post.title || '未命名帖子') + '</span>' +
        '<span class="feed-item-meta">' + meta + '</span></a>';
    }).join('');
  }

  function renderTracks(tracks, lessons) {
    if (!tracksList) return;
    if (!tracks || !tracks.length) {
      tracksList.innerHTML =
        '<div class="track-item"><span class="track-index">—</span>' +
        '<div><b>教程正在编排</b><small>上线后可在 App 内逐课学习</small></div></div>';
      return;
    }
    tracksList.innerHTML = tracks.slice(0, 4).map(function (track, i) {
      var meta = [];
      if (track.lessonCount) meta.push(track.lessonCount + ' 课时');
      if (track.durationMin) meta.push(track.durationMin + ' 分钟');
      return '<div class="track-item">' +
        '<span class="track-index">' + String(i + 1).padStart(2, '0') + '</span>' +
        '<div><b>' + escapeHtml(track.name) + '</b>' +
        '<small>' + escapeHtml(track.description || meta.join(' · ') || '实战教程') + '</small></div>' +
        '<span class="track-arrow">↗</span></div>';
    }).join('');
    if (tracksSummary) {
      tracksSummary.textContent = '共 ' + formatNumber(tracks.length) + ' 条轨道 · ' + formatNumber(lessons || 0) + ' 课时';
    }
  }

  // ---------------------------------------------------------------------------
  // 定价
  // ---------------------------------------------------------------------------
  var planGrid = $('#plan-grid');
  var pricingNote = $('#pricing-note');
  var billingCycles = [];
  var billingPlans = [];
  var currentCycle = 'month';
  var pricingMeta = { tokensPerCredit: 1000, initialCredits: 500 };

  function formatPrice(value) {
    var n = Number(value);
    if (!Number.isFinite(n) || n <= 0) return '0';
    return n % 1 === 0 ? String(n) : n.toFixed(1);
  }
  function cycleMonths(id) {
    var found = billingCycles.filter(function (c) { return c.id === id; })[0];
    return found ? Number(found.months) || 1 : 1;
  }
  function planFeatures(plan, pricing) {
    var list = [];
    if (plan.free) {
      list.push('每日签到 ' + formatNumber(plan.checkinReward || 0) + ' 积分');
      list.push('注册赠送 ' + formatNumber(pricing.initialCredits || 0) + ' 积分');
      list.push('编辑器、云端构建与社区全功能');
      list.push('项目与偏好跨设备同步');
    } else {
      list.push('每月 ' + formatNumber(plan.monthlyCredits || 0) + ' 积分');
      list.push('每日签到 ' + formatNumber(plan.checkinReward || 0) + ' 积分');
      list.push('内置大模型与工具调用');
      list.push('1 积分 = ' + formatNumber(pricing.tokensPerCredit || 1000) + ' tokens');
    }
    return list;
  }
  function renderPlans() {
    if (!planGrid || !billingPlans.length) return;
    planGrid.innerHTML = billingPlans.map(function (plan) {
      var price = plan.prices && plan.prices[currentCycle] != null
        ? plan.prices[currentCycle]
        : 0;
      var isFree = !!plan.free;
      var featured = plan.id === 'pro' || plan.badge === '推荐';
      var months = cycleMonths(currentCycle);
      var monthly = !isFree && price > 0 && months > 1 ? '≈ ¥' + (Number(price) / months).toFixed(1) + ' / 月' : '';
      var per = isFree ? '/永久' : '/ ' + (currentCycle === 'year' ? '年' : currentCycle === 'quarter' ? '季' : '月');
      var features = planFeatures(plan, pricingMeta).map(function (f) {
        return '<li>' + escapeHtml(f) + '</li>';
      }).join('');
      return '<article class="plan' + (featured ? ' featured' : '') + '">' +
        (plan.badge ? '<span class="plan-badge">' + escapeHtml(plan.badge) + '</span>' : '') +
        '<p class="plan-name">' + escapeHtml(plan.name) + '</p>' +
        '<p class="plan-price"><span class="cur">¥</span><b>' + formatPrice(price) + '</b>' +
        '<span class="per">' + per + '</span></p>' +
        '<p class="plan-monthly">' + monthly + '</p>' +
        '<p class="plan-desc">' + escapeHtml(plan.description || '') + '</p>' +
        '<ul class="plan-features">' + features + '</ul>' +
        '<a class="btn ' + (featured ? 'btn-primary' : 'btn-ghost') + ' btn-block" href="#download">' +
        (isFree ? '免费开始' : '在 App 内开通') + '</a></article>';
    }).join('');
  }

  function setupPricing(data) {
    if (!data) return;
    billingCycles = Array.isArray(data.cycles) && data.cycles.length
      ? data.cycles
      : [{ id: 'month', name: '月付', months: 1 }, { id: 'quarter', name: '季付', months: 3 }, { id: 'year', name: '年付', months: 12 }];
    billingPlans = Array.isArray(data.plans) ? data.plans : [];
    pricingMeta = data.pricing || pricingMeta;
    var known = billingCycles.some(function (c) { return c.id === currentCycle; });
    if (!known) currentCycle = billingCycles[0].id;

    $$('#pricing .segmented button').forEach(function (btn) {
      var cycle = btn.getAttribute('data-cycle');
      btn.classList.toggle('active', cycle === currentCycle);
      btn.setAttribute('aria-pressed', cycle === currentCycle ? 'true' : 'false');
    });
    renderPlans();
    if (pricingNote) {
      pricingNote.textContent = '1 积分 = ' + formatNumber(pricingMeta.tokensPerCredit || 1000) +
        ' tokens · 注册赠送 ' + formatNumber(pricingMeta.initialCredits || 500) +
        ' 积分 · 价格以 App 内结算页为准';
    }
  }

  $$('#pricing .segmented button').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var cycle = btn.getAttribute('data-cycle');
      if (!cycle || cycle === currentCycle) return;
      currentCycle = cycle;
      $$('#pricing .segmented button').forEach(function (b) {
        b.classList.toggle('active', b === btn);
        b.setAttribute('aria-pressed', b === btn ? 'true' : 'false');
      });
      renderPlans();
    });
  });

  // ---------------------------------------------------------------------------
  // QQ 群
  // ---------------------------------------------------------------------------
  function setupQq(group) {
    if (!group) return;
    var btn = $('#qq-copy');
    var number = $('#qq-number');
    if (!btn || !number) return;
    number.textContent = group;
    btn.hidden = false;
    btn.addEventListener('click', function () {
      copyText(group, 'QQ 群号已复制：' + group);
    });
  }

  // ---------------------------------------------------------------------------
  // 政策弹窗
  // ---------------------------------------------------------------------------
  var policyModal = $('#policy-modal');
  var policyTitle = $('#policy-title');
  var policyBody = $('#policy-body');
  var policiesCache = null;
  var policiesPromise = null;
  var lastFocus = null;

  function fetchPolicies() {
    if (policiesCache) return Promise.resolve(policiesCache);
    if (!policiesPromise) {
      policiesPromise = fetch(API_BASE + '/api/policies', { headers: { Accept: 'application/json' } })
        .then(function (res) {
          if (!res.ok) throw new Error('bad status');
          return res.json();
        })
        .then(function (data) {
          policiesCache = (data && data.policies) || {};
          return policiesCache;
        })
        .catch(function () {
          policiesPromise = null;
          return null;
        });
    }
    return policiesPromise;
  }

  function inlinePolicy(text) {
    return String(text)
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/`([^`]+)`/g, '<code>$1</code>');
  }
  function renderPolicyText(text) {
    var blocks = escapeHtml(text).split(/\n{2,}/);
    return blocks.map(function (block) {
      var lines = block.split('\n').map(function (l) { return l.trim(); }).filter(Boolean);
      if (!lines.length) return '';
      var heading = lines[0].match(/^#{1,4}\s+(.+)$/);
      if (heading) {
        var rest = lines.slice(1);
        return '<h4>' + inlinePolicy(heading[1]) + '</h4>' +
          (rest.length ? '<p>' + inlinePolicy(rest.join('<br>')) + '</p>' : '');
      }
      var isList = lines.every(function (l) { return /^([-*]|\d+[.、])\s*/.test(l); });
      if (isList) {
        return '<ul>' + lines.map(function (l) {
          return '<li>' + inlinePolicy(l.replace(/^([-*]|\d+[.、])\s*/, '')) + '</li>';
        }).join('') + '</ul>';
      }
      return '<p>' + inlinePolicy(lines.join('<br>')) + '</p>';
    }).join('');
  }

  function renderPolicy(type) {
    if (!policyBody) return;
    var policy = policiesCache && policiesCache[type];
    if (!policy) {
      policyBody.textContent = '内容暂时无法加载，请稍后重试，或在 App 内查看最新版本。';
      return;
    }
    if (policyTitle) policyTitle.textContent = policy.title || (type === 'privacyPolicy' ? '隐私政策' : '用户协议');
    var meta = [policy.version ? '版本 ' + policy.version : '', policy.updatedAt ? '更新于 ' + formatDate(policy.updatedAt) : '']
      .filter(Boolean).join(' · ');
    var html = '';
    if (meta) html += '<p class="policy-meta">' + escapeHtml(meta) + '</p>';
    html += renderPolicyText(policy.content || '暂无内容');
    policyBody.innerHTML = html;
    policyBody.scrollTop = 0;
  }

  function openPolicy(type) {
    if (!policyModal) return;
    lastFocus = document.activeElement;
    policyModal.hidden = false;
    document.body.style.overflow = 'hidden';
    if (policyBody) policyBody.textContent = '正在加载…';
    $$('#policy-modal [data-policy]').forEach(function (btn) {
      btn.classList.toggle('active', btn.getAttribute('data-policy') === type);
    });
    fetchPolicies().then(function (data) {
      if (data) renderPolicy(type);
      else if (policyBody) policyBody.textContent = '内容暂时无法加载，请稍后重试。';
    });
  }
  function closePolicy() {
    if (!policyModal || policyModal.hidden) return;
    policyModal.hidden = true;
    document.body.style.overflow = '';
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  $$('[data-policy]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var type = btn.getAttribute('data-policy');
      var inModal = policyModal && policyModal.contains(btn);
      if (inModal && policiesCache) {
        $$('#policy-modal [data-policy]').forEach(function (b) {
          b.classList.toggle('active', b === btn);
        });
        renderPolicy(type);
      } else {
        openPolicy(type);
      }
    });
  });
  if (policyModal) {
    $$('[data-close]', policyModal).forEach(function (el) {
      el.addEventListener('click', closePolicy);
    });
  }
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      closePolicy();
      if (drawer && !drawer.hidden) setDrawer(false);
    }
  });

  // ---------------------------------------------------------------------------
  // 聚合数据
  // ---------------------------------------------------------------------------
  function applyOverview(data) {
    window.__slipeStats = (data && data.stats) || {};
    runStats(window.__slipeStats);
    renderRelease(data && data.release);
    renderPosts(data && data.posts);
    renderTracks(data && data.tutorials, data && data.stats && data.stats.lessons);
    setupPricing(data && data.plans);
    setupQq(data && data.qqGroup);
  }

  fetch(API_BASE + '/api/public/overview', { headers: { Accept: 'application/json' } })
    .then(function (res) {
      if (!res.ok) throw new Error('bad status');
      return res.json();
    })
    .then(applyOverview)
    .catch(function () {
      renderRelease(null);
      renderPosts([]);
      renderTracks([], 0);
      if (releaseState) releaseState.textContent = '版本信息暂时不可用';
      if (pricingNote) pricingNote.textContent = '套餐信息暂时不可用，请稍后刷新或直接在 App 内查看。';
      if (planGrid) {
        planGrid.innerHTML = '<article class="plan featured"><p class="plan-name">SLIPE</p>' +
          '<p class="plan-desc" style="border:0;min-height:0">套餐与价格正在加载失败，请稍后刷新页面，或下载 App 在应用内查看。</p>' +
          '<a class="btn btn-primary btn-block" href="#download">前往下载</a></article>';
      }
      runStats({});
    });

  // 年份
  var yearEl = $('#year');
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());
})();
