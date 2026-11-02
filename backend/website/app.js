/* SlipCode 官网交互：版本信息、设备适配、QQ 群复制 */
(function () {
  'use strict';

  var API_BASE = ''; // 官网与 API 同源（slipe.cn 反代到后端进程）

  var isMobile = /Android|iPhone|iPad|iPod|Mobile|HarmonyOS/i.test(navigator.userAgent);

  // ---------------------------------------------------------------------------
  // Toast
  // ---------------------------------------------------------------------------
  var toastTimer = null;
  function toast(message) {
    var el = document.getElementById('toast');
    el.textContent = message;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      el.classList.remove('show');
    }, 2200);
  }

  // ---------------------------------------------------------------------------
  // 设备适配：当前设备对应的平台卡片加「推荐」徽章并前置
  // ---------------------------------------------------------------------------
  var badgeAndroid = document.getElementById('badge-android');
  var badgeDesktop = document.getElementById('badge-desktop');
  var cardsWrap = document.getElementById('platform-cards');
  var cardAndroid = document.getElementById('card-android');
  var cardDesktop = document.getElementById('card-desktop');
  var desktopNote = document.getElementById('desktop-note');
  var androidNote = document.getElementById('android-note');

  if (isMobile) {
    badgeAndroid.classList.add('show');
    desktopNote.textContent = '桌面客户端适配中，可先使用 Android 版。';
  } else {
    badgeDesktop.classList.add('show');
    // 桌面端访问：桌面版卡片前置，自动展示「即将推出」
    cardsWrap.insertBefore(cardDesktop, cardAndroid);
    desktopNote.textContent = '我们正在适配桌面客户端，移动端可先下载 Android 版。';
    androidNote.textContent = '使用手机访问本页可直接安装。';
  }

  // ---------------------------------------------------------------------------
  // 最新版本信息
  // ---------------------------------------------------------------------------
  var heroMeta = document.getElementById('hero-meta');
  var releaseInfo = document.getElementById('release-info');
  var btnDownload = document.getElementById('btn-download-android');
  var btnText = document.getElementById('btn-android-text');

  function formatSize(bytes) {
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }

  function formatDate(iso) {
    var d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '';
    var pad = function (n) { return String(n).padStart(2, '0'); };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }

  function renderRelease(release) {
    var dateText = formatDate(release.updatedAt);
    releaseInfo.innerHTML =
      '<p class="release-version">v' + release.version + ' · ' + formatSize(release.size) + '</p>' +
      (dateText ? '<p class="release-notes">发布于 ' + dateText + ' · 已下载 ' + (release.downloads || 0) + ' 次</p>' : '') +
      (release.notes ? '<p class="release-notes">' + escapeHtml(release.notes) + '</p>' : '');
    btnDownload.disabled = false;
    btnText.textContent = '下载 Android 版 v' + release.version;
    btnDownload.addEventListener('click', function () {
      window.location.href = API_BASE + '/api/releases/download';
    });
    heroMeta.textContent = '最新版本 v' + release.version + (dateText ? ' · ' + dateText + ' 更新' : '');
  }

  function renderEmpty() {
    releaseInfo.innerHTML = '<p class="release-loading">首个公开版本即将发布，敬请期待。</p>';
    btnText.textContent = '即将发布';
    btnDownload.disabled = true;
    heroMeta.textContent = '首个公开版本即将发布';
  }

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
      .replace(/\n/g, '<br>');
  }

  fetch(API_BASE + '/api/releases/latest', { headers: { Accept: 'application/json' } })
    .then(function (res) {
      if (res.status === 404) return null;
      if (!res.ok) throw new Error('bad status');
      return res.json();
    })
    .then(function (data) {
      if (data && data.release) renderRelease(data.release);
      else renderEmpty();
    })
    .catch(function () {
      releaseInfo.innerHTML = '<p class="release-loading">版本信息获取失败，请稍后刷新重试。</p>';
      btnText.textContent = '暂不可用';
      heroMeta.textContent = '';
    });

  // ---------------------------------------------------------------------------
  // QQ 群（后台可配置）
  // ---------------------------------------------------------------------------
  var btnQq = document.getElementById('btn-qq');
  var qqText = document.getElementById('qq-text');

  fetch(API_BASE + '/api/public/info', { headers: { Accept: 'application/json' } })
    .then(function (res) { return res.ok ? res.json() : null; })
    .then(function (data) {
      var group = data && String(data.qqGroup || '').trim();
      if (!group) return;
      btnQq.hidden = false;
      qqText.textContent = 'QQ 群：' + group;
      btnQq.addEventListener('click', function () {
        copyText(group);
      });
    })
    .catch(function () { /* 未配置时保持隐藏 */ });

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(
        function () { toast('QQ 群号已复制'); },
        function () { fallbackCopy(text); }
      );
    } else {
      fallbackCopy(text);
    }
  }

  function fallbackCopy(text) {
    var input = document.createElement('textarea');
    input.value = text;
    input.style.position = 'fixed';
    input.style.opacity = '0';
    document.body.appendChild(input);
    input.select();
    try {
      document.execCommand('copy');
      toast('QQ 群号已复制');
    } catch (err) {
      toast('复制失败，请手动记录：' + text);
    }
    document.body.removeChild(input);
  }
})();
