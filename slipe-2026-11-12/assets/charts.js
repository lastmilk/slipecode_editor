(function () {
  'use strict';

  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var seriesColor = accent + 'cc';
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();
  var charts = [];
  var pending = [];
  var booted = false;

  function baseOption() {
    return {
      animation: false,
      aria: { enabled: true },
      emphasis: { focus: 'series' },
      backgroundColor: 'transparent',
      textStyle: { fontFamily: 'Instrument Sans, Noto Sans CJK SC, sans-serif', color: ink },
      tooltip: { appendToBody: true, backgroundColor: bg2, borderColor: rule, textStyle: { color: ink } },
      grid: { left: 58, right: 28, top: 42, bottom: 48, containLabel: true }
    };
  }

  function axis(name) {
    return {
      name: name || '',
      nameTextStyle: { color: muted },
      axisLabel: { color: muted },
      axisLine: { lineStyle: { color: rule } },
      axisTick: { lineStyle: { color: rule } },
      splitLine: { lineStyle: { color: rule } }
    };
  }

  function setStatus(el, message) {
    var figure = el.closest('figure');
    var status = figure ? figure.querySelector('[data-chart-status]') : null;
    if (status) status.textContent = message;
  }

  function useTableFallback(el) {
    el.className = 'chart-unavailable';
    el.textContent = '静态表格模式：精确数值见下表。';
    setStatus(el, '当前显示静态数据表，所有数值保持可读。');
  }

  function render(item) {
    var el = document.getElementById(item.id);
    if (!el) return;
    if (!window.echarts) {
      useTableFallback(el);
      return;
    }
    try {
      var previous = window.echarts.getInstanceByDom(el);
      if (previous) previous.dispose();
      var chart = window.echarts.init(el, null, { renderer: 'svg' });
      chart.setOption(item.option);
      charts.push(chart);
      setStatus(el, '交互图表已就绪；精确数值见下表。');
    } catch (error) {
      useTableFallback(el);
    }
  }

  function queue(id, option) {
    pending.push({ id: id, option: option });
  }

  function boot() {
    if (booted) return;
    booted = true;
    pending.forEach(render);
  }

  var market = baseOption();
  market.tooltip.trigger = 'axis';
  market.tooltip.valueFormatter = function (value) { return Number(value).toFixed(2) + ' 十亿美元'; };
  market.xAxis = Object.assign(axis(''), { type: 'category', data: ['2026 商业估算', '2035 机构预测'] });
  market.yAxis = Object.assign(axis('十亿美元'), { type: 'value', min: 0 });
  market.series = [{
    name: '宽口径云 IDE 市场', type: 'bar', barWidth: '42%',
    data: [15.54, 64.93],
    itemStyle: { color: function (params) { return params.dataIndex === 0 ? seriesColor : accent2; } },
    label: { show: true, position: 'top', color: ink, formatter: function (p) { return '$' + Number(p.value).toFixed(2) + 'B'; } }
  }];
  queue('chart-market', market);

  var budget = baseOption();
  budget.tooltip.trigger = 'axis';
  budget.tooltip.axisPointer = { type: 'shadow' };
  budget.tooltip.valueFormatter = function (value) { return Number(value).toFixed(1) + ' 万元'; };
  budget.legend = { top: 0, textStyle: { color: muted }, data: ['验证情景', '标准情景'] };
  budget.grid = { left: 118, right: 28, top: 50, bottom: 42, containLabel: true };
  budget.xAxis = Object.assign(axis('万元'), { type: 'value', min: 0, max: 4.5 });
  budget.yAxis = Object.assign(axis(''), {
    type: 'category',
    data: ['预备金', '合规/安全/工具', '研究/用户激励', '渠道实验', '社区/活动', '内容/演示', '云计算/模型']
  });
  budget.series = [
    { name: '验证情景', type: 'bar', data: [0.5, 0.8, 0.6, 0.9, 0.6, 0.8, 1.8], itemStyle: { color: seriesColor }, barMaxWidth: 22 },
    { name: '标准情景', type: 'bar', data: [1.2, 1.8, 1.5, 3.6, 2.4, 3.0, 4.5], itemStyle: { color: accent2 }, barMaxWidth: 22 }
  ];
  queue('chart-budget', budget);

  var cost = baseOption();
  cost.tooltip.trigger = 'axis';
  cost.legend = { top: 0, textStyle: { color: muted }, data: ['计算', '模型', '其他', '每成功任务'] };
  cost.grid = { left: 54, right: 58, top: 58, bottom: 48, containLabel: true };
  cost.xAxis = Object.assign(axis(''), { type: 'category', data: ['轻量检查', '标准构建', '重型构建'] });
  cost.yAxis = [
    Object.assign(axis('原始成本（元）'), { type: 'value', min: 0 }),
    Object.assign(axis('每成功任务（元）'), { type: 'value', min: 0, splitLine: { show: false } })
  ];
  cost.series = [
    { name: '计算', type: 'bar', stack: 'raw', data: [0.12, 0.60, 2.40], itemStyle: { color: accent }, barWidth: '40%' },
    { name: '模型', type: 'bar', stack: 'raw', data: [0.08, 0.20, 0.60], itemStyle: { color: seriesColor }, barWidth: '40%' },
    { name: '其他', type: 'bar', stack: 'raw', data: [0.03, 0.10, 0.40], itemStyle: { color: muted }, barWidth: '40%' },
    { name: '每成功任务', type: 'line', yAxisIndex: 1, data: [0.24, 1.00, 4.25], itemStyle: { color: accent2 }, lineStyle: { color: accent2, width: 3 }, symbolSize: 9, label: { show: true, position: 'top', color: accent2, formatter: function (p) { return '¥' + Number(p.value).toFixed(2); } } }
  ];
  queue('chart-cost', cost);

  window.addEventListener('resize', function () {
    charts.forEach(function (chart) { chart.resize(); });
  });

  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(boot, boot);
  } else {
    boot();
  }
}());
