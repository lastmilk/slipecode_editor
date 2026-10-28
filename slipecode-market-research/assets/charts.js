// assets/charts.js
(function() {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();

  // --- Chart 1: Global IDE Market Size (2025-2034) ---
  var el1 = document.getElementById('chart-ide-market');
  if (el1) {
    var chart1 = echarts.init(el1, null, { renderer: 'svg' });
    chart1.setOption({
      animation: false,
      tooltip: {
        trigger: 'axis',
        appendToBody: true,
        valueFormatter: function(v) { return v + ' 十亿美元'; }
      },
      grid: { top: 40, right: 30, bottom: 50, left: 60 },
      xAxis: {
        type: 'category',
        data: ['2025','2026','2027','2028','2029','2030','2031','2032','2033','2034'],
        axisLine: { lineStyle: { color: rule } },
        axisLabel: { color: muted, fontSize: 12 }
      },
      yAxis: {
        type: 'value',
        name: '十亿美元',
        nameTextStyle: { color: muted, fontSize: 12 },
        axisLine: { show: false },
        axisTick: { show: false },
        splitLine: { lineStyle: { color: rule, type: 'dashed' } },
        axisLabel: { color: muted, fontSize: 12 }
      },
      series: [{
        name: '全球 IDE 市场规模',
        type: 'bar',
        data: [4.8, 5.66, 6.68, 7.88, 9.30, 10.97, 12.95, 15.28, 18.03, 21.29],
        itemStyle: {
          color: {
            type: 'linear', x: 0, y: 0, x2: 0, y2: 1,
            colorStops: [
              { offset: 0, color: accent },
              { offset: 1, color: accent + '66' }
            ]
          },
          borderRadius: [4, 4, 0, 0]
        },
        barWidth: '50%',
        label: {
          show: true,
          position: 'top',
          color: ink,
          fontSize: 11,
          fontWeight: 600,
          formatter: '{c}'
        }
      }]
    });
    window.addEventListener('resize', function() { chart1.resize(); });
  }

  // --- Chart 2: China AI Coding Market (2024-2026E) ---
  var el2 = document.getElementById('chart-ai-coding');
  if (el2) {
    var chart2 = echarts.init(el2, null, { renderer: 'svg' });
    chart2.setOption({
      animation: false,
      tooltip: {
        trigger: 'axis',
        appendToBody: true,
        valueFormatter: function(v) { return v + ' 亿元'; }
      },
      grid: { top: 40, right: 30, bottom: 50, left: 60 },
      xAxis: {
        type: 'category',
        data: ['2024', '2025', '2026E'],
        axisLine: { lineStyle: { color: rule } },
        axisLabel: { color: muted, fontSize: 12 }
      },
      yAxis: {
        type: 'value',
        name: '亿元',
        nameTextStyle: { color: muted, fontSize: 12 },
        axisLine: { show: false },
        axisTick: { show: false },
        splitLine: { lineStyle: { color: rule, type: 'dashed' } },
        axisLabel: { color: muted, fontSize: 12 }
      },
      series: [{
        name: '中国 AI 编程市场规模',
        type: 'bar',
        data: [1.35, 3.99, 11.73],
        itemStyle: {
          color: {
            type: 'linear', x: 0, y: 0, x2: 0, y2: 1,
            colorStops: [
              { offset: 0, color: accent2 },
              { offset: 1, color: accent2 + '66' }
            ]
          },
          borderRadius: [4, 4, 0, 0]
        },
        barWidth: '45%',
        label: {
          show: true,
          position: 'top',
          color: ink,
          fontSize: 13,
          fontWeight: 700,
          formatter: '{c} 亿'
        }
      }]
    });
    window.addEventListener('resize', function() { chart2.resize(); });
  }
})();
