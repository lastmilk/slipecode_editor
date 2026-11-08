(function() {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var warn = style.getPropertyValue('--warn').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();

  function baseTooltip() {
    return {
      appendToBody: true,
      backgroundColor: bg2,
      borderColor: rule,
      textStyle: { color: ink, fontSize: 12.5 }
    };
  }

  function axisStyle() {
    return {
      axisLine: { lineStyle: { color: rule } },
      axisLabel: { color: muted, fontSize: 12 },
      splitLine: { lineStyle: { color: rule, opacity: 0.5 } }
    };
  }

  // --- Chart 1: Market size (Global $B vs China ¥100M) ---
  var c1 = echarts.init(document.getElementById('chart-market'), null, { renderer: 'svg' });
  c1.setOption({
    animation: false,
    tooltip: Object.assign(baseTooltip(), { trigger: 'axis' }),
    legend: { textStyle: { color: muted }, top: 0 },
    grid: { top: 44, left: 56, right: 56, bottom: 36 },
    xAxis: Object.assign(axisStyle(), {
      type: 'category',
      data: ['2024', '2025(估)', '2026(预测)']
    }),
    yAxis: [
      Object.assign(axisStyle(), {
        type: 'value', name: '全球（亿美元）',
        nameTextStyle: { color: muted }, splitLine: { lineStyle: { color: rule, opacity: 0.5 } }
      }),
      Object.assign(axisStyle(), {
        type: 'value', name: '中国（亿元）',
        nameTextStyle: { color: muted }, splitLine: { show: false }
      })
    ],
    series: [
      {
        name: '全球市场规模',
        type: 'bar',
        barWidth: 42,
        data: [67, 94, 128],
        itemStyle: { color: accent, borderRadius: [6, 6, 0, 0] },
        label: { show: true, position: 'top', color: accent, fontWeight: 700, fontFamily: 'JetBrainsMono' }
      },
      {
        name: '中国市场规模',
        type: 'line',
        yAxisIndex: 1,
        data: [null, 3.99, 11.73],
        smooth: false,
        symbol: 'circle',
        symbolSize: 9,
        lineStyle: { color: accent2, width: 3 },
        itemStyle: { color: accent2 },
        label: { show: true, position: 'top', color: accent2, fontWeight: 700, fontFamily: 'JetBrainsMono' }
      }
    ]
  });
  window.addEventListener('resize', function() { c1.resize(); });

  // --- Chart 2: Positioning map (form factor vs price) ---
  var c2 = echarts.init(document.getElementById('chart-position'), null, { renderer: 'svg' });
  var posData = [
    { name: 'Cursor Pro', v: [8, 215], c: muted },
    { name: 'Copilot Pro', v: [12, 72], c: muted },
    { name: 'Copilot Max', v: [12, 720], c: muted },
    { name: 'Replit Core', v: [45, 145], c: muted },
    { name: 'Replit Pro', v: [45, 720], c: muted },
    { name: '传统移动IDE', v: [88, 10], c: warn },
    { name: 'SLIPE Pro ¥22', v: [90, 22], c: accent2 },
    { name: 'SLIPE Pro+ ¥49', v: [92, 49], c: accent }
  ];
  c2.setOption({
    animation: false,
    tooltip: Object.assign(baseTooltip(), {
      formatter: function(p) {
        return '<b>' + p.data.name + '</b><br/>移动端程度 ' + p.data.v[0] + '/100<br/>月费 ¥' + p.data.v[1];
      }
    }),
    grid: { top: 30, left: 70, right: 40, bottom: 52 },
    xAxis: Object.assign(axisStyle(), {
      name: '桌面端 ←→ 移动端',
      nameLocation: 'middle', nameGap: 32,
      nameTextStyle: { color: muted },
      min: 0, max: 100
    }),
    yAxis: Object.assign(axisStyle(), {
      type: 'log', logBase: 10,
      name: '个人版月费（¥，对数轴）',
      nameTextStyle: { color: muted },
      min: 5, max: 1000
    }),
    series: [{
      type: 'scatter',
      symbolSize: function(v, p) { return p.data.name.indexOf('SLIPE') === 0 ? 20 : 14; },
      data: posData.map(function(d) {
        return { name: d.name, v: d.v, value: d.v, itemStyle: { color: d.c, opacity: 0.9 } };
      }),
      label: {
        show: true, position: 'right', color: ink, fontSize: 11.5,
        formatter: function(p) { return p.data.name; }
      },
      markArea: {
        silent: true,
        itemStyle: { color: 'rgba(52,211,153,0.06)' },
        label: { color: accent2, fontSize: 12, position: 'insideTopRight' },
        data: [[
          { name: '移动端 × 付费 真空区', xAxis: 70, yAxis: 15 },
          { xAxis: 100, yAxis: 80 }
        ]]
      }
    }]
  });
  window.addEventListener('resize', function() { c2.resize(); });

  // --- Chart 3: Pricing comparison ---
  var c3 = echarts.init(document.getElementById('chart-pricing'), null, { renderer: 'svg' });
  var priceData = [
    { name: '传统移动IDE', v: 10, c: muted },
    { name: 'SLIPE Pro', v: 22, c: accent2 },
    { name: 'SLIPE Pro+', v: 49, c: accent2 },
    { name: 'Copilot Pro', v: 72, c: muted },
    { name: 'Replit Core', v: 145, c: muted },
    { name: 'Cursor Pro', v: 215, c: muted },
    { name: 'Copilot Max', v: 720, c: muted }
  ];
  c3.setOption({
    animation: false,
    tooltip: Object.assign(baseTooltip(), {
      formatter: function(p) { return '<b>' + p.name + '</b><br/>月费 ¥' + p.value; }
    }),
    grid: { top: 24, left: 110, right: 70, bottom: 30 },
    xAxis: Object.assign(axisStyle(), { type: 'value', name: '¥/月', nameTextStyle: { color: muted } }),
    yAxis: Object.assign(axisStyle(), {
      type: 'category',
      data: priceData.map(function(d) { return d.name; }),
      axisLabel: { color: ink, fontSize: 12.5 }
    }),
    series: [{
      type: 'bar',
      barWidth: 20,
      data: priceData.map(function(d) {
        return { value: d.v, itemStyle: { color: d.c, borderRadius: [0, 6, 6, 0] } };
      }),
      label: {
        show: true, position: 'right',
        color: ink, fontFamily: 'JetBrainsMono', fontWeight: 700, fontSize: 12,
        formatter: function(p) { return '¥' + p.value; }
      }
    }]
  });
  window.addEventListener('resize', function() { c3.resize(); });

  // --- Chart 4: 12-month MRR projection (stacked) ---
  var c4 = echarts.init(document.getElementById('chart-mrr'), null, { renderer: 'svg' });
  var months = ['M1','M2','M3','M4','M5','M6','M7','M8','M9','M10','M11','M12'];
  // Unit: ¥ thousand (K). Estimated model.
  var pro =  [3.0, 4.0, 4.6, 7, 11, 16, 21, 26, 40, 58, 78, 95];
  var proPlus = [0.4, 0.7, 1.0, 2.0, 3.4, 5.0, 6.6, 8.4, 14, 21, 29, 37];
  var other = [0.1, 0.3, 0.5, 1.0, 1.8, 2.8, 3.8, 5.0, 8, 12, 16, 18]; // packs + team
  c4.setOption({
    animation: false,
    tooltip: Object.assign(baseTooltip(), {
      trigger: 'axis',
      valueFormatter: function(v) { return '¥' + v + 'K'; }
    }),
    legend: { textStyle: { color: muted }, top: 0 },
    grid: { top: 44, left: 60, right: 30, bottom: 36 },
    xAxis: Object.assign(axisStyle(), { type: 'category', data: months, boundaryGap: false }),
    yAxis: Object.assign(axisStyle(), {
      type: 'value', name: 'MRR（千元）', nameTextStyle: { color: muted }
    }),
    series: [
      {
        name: 'Pro ¥22', type: 'line', stack: 'm', smooth: false, symbol: 'circle', symbolSize: 5,
        data: pro, lineStyle: { color: accent, width: 2.5 }, itemStyle: { color: accent },
        areaStyle: { color: accent, opacity: 0.25 }
      },
      {
        name: 'Pro+ ¥49', type: 'line', stack: 'm', smooth: false, symbol: 'circle', symbolSize: 5,
        data: proPlus, lineStyle: { color: accent2, width: 2.5 }, itemStyle: { color: accent2 },
        areaStyle: { color: accent2, opacity: 0.25 }
      },
      {
        name: '加油包 + 团队版', type: 'line', stack: 'm', smooth: false, symbol: 'circle', symbolSize: 5,
        data: other, lineStyle: { color: muted, width: 2 }, itemStyle: { color: muted },
        areaStyle: { color: muted, opacity: 0.18 }
      }
    ]
  });
  window.addEventListener('resize', function() { c4.resize(); });

  // --- Mermaid ---
  if (window.mermaid) {
    mermaid.initialize({
      startOnLoad: true,
      theme: 'neutral',
      securityLevel: 'loose',
      flowchart: { curve: 'linear' }
    });
  }
})();
