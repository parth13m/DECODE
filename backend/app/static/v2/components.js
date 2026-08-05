/* ══════════════════════════════════════════════════════════
   Decode Dashboard v2 — Component Library
   ══════════════════════════════════════════════════════════
   Reusable UI component builders. All functions return
   HTML strings for innerHTML injection.
   ────────────────────────────────────────────────────────── */

const D = window.D || {};
window.D = D;


/* ── Formatting Helpers ── */

D.fmt = {
  num(v, decimals = 0) {
    if (v == null || isNaN(v)) return '—';
    return Number(v).toLocaleString('en-US', {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    });
  },

  pct(v, decimals = 1) {
    if (v == null || isNaN(v)) return '—';
    return Number(v).toFixed(decimals) + '%';
  },

  usd(v, decimals = 2) {
    if (v == null || isNaN(v)) return '—';
    const n = Number(v);
    if (n < 0.01 && n > 0) return '<$0.01';
    return '$' + n.toLocaleString('en-US', {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    });
  },

  usdCompact(v) {
    if (v == null || isNaN(v)) return '—';
    const n = Number(v);
    if (n >= 1000) return '$' + (n / 1000).toFixed(1) + 'k';
    if (n >= 1) return '$' + n.toFixed(2);
    if (n >= 0.01) return '$' + n.toFixed(2);
    if (n > 0) return '<$0.01';
    return '$0.00';
  },

  duration(seconds) {
    if (seconds == null || isNaN(seconds)) return '—';
    const s = Number(seconds);
    if (s < 60) return s.toFixed(0) + 's';
    if (s < 3600) return (s / 60).toFixed(1) + 'm';
    if (s < 86400) return (s / 3600).toFixed(1) + 'h';
    return (s / 86400).toFixed(1) + 'd';
  },

  latency(ms) {
    if (ms == null || isNaN(ms)) return '—';
    const v = Number(ms);
    if (v < 1000) return v.toFixed(0) + 'ms';
    return (v / 1000).toFixed(1) + 's';
  },

  date(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  },

  dateShort(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  },

  timeAgo(iso) {
    if (!iso) return '—';
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + 'm ago';
    const hours = Math.floor(mins / 60);
    if (hours < 24) return hours + 'h ago';
    const days = Math.floor(hours / 24);
    if (days < 30) return days + 'd ago';
    return Math.floor(days / 30) + 'mo ago';
  },

  escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  },

  initials(name, email) {
    if (name) {
      const parts = name.trim().split(/\s+/);
      return parts.length > 1
        ? (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
        : parts[0].substring(0, 2).toUpperCase();
    }
    return email ? email.substring(0, 2).toUpperCase() : '??';
  },
};


/* ══════════════════════════════════════════════════════════
   API CLIENT
   ══════════════════════════════════════════════════════════ */

D.api = {
  _cache: new Map(),
  _inflight: new Map(),
  _cacheTTL: 60_000, // 1 minute default

  /** Clear all cached data */
  clearCache() {
    this._cache.clear();
    this._inflight.clear();
  },

  /** Fetch JSON with retry, caching, and dedup */
  async fetch(path, opts = {}) {
    const cacheKey = path;
    const ttl = opts.cacheTTL ?? this._cacheTTL;
    const retries = opts.retries ?? 2;

    // Return cached if fresh
    if (!opts.noCache) {
      const cached = this._cache.get(cacheKey);
      if (cached && Date.now() - cached.ts < ttl) {
        return cached.data;
      }
    }

    // Deduplicate inflight requests
    if (this._inflight.has(cacheKey)) {
      return this._inflight.get(cacheKey);
    }

    const promise = this._fetchWithRetry(path, retries);
    this._inflight.set(cacheKey, promise);

    try {
      const data = await promise;
      this._cache.set(cacheKey, { data, ts: Date.now() });
      return data;
    } finally {
      this._inflight.delete(cacheKey);
    }
  },

  async _fetchWithRetry(path, retries) {
    let lastError;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await fetch(path, {
          headers: {
            'Authorization': `Bearer ${App.token}`,
          },
        });
        if (res.status === 401) {
          App.logout();
          throw new Error('Unauthorized');
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
      } catch (err) {
        lastError = err;
        if (err.message === 'Unauthorized') throw err;
        if (attempt < retries) {
          await new Promise(r => setTimeout(r, 300 * (attempt + 1)));
        }
      }
    }
    throw lastError;
  },

  /** Build a URL with date range params from global filters */
  url(base, extraParams = {}) {
    const params = new URLSearchParams();
    const f = App.filters;
    if (f && f.days) params.set('days', f.days);
    if (f && f.start) params.set('start', f.start);
    if (f && f.end) params.set('end', f.end);
    for (const [k, v] of Object.entries(extraParams)) {
      if (v != null) params.set(k, v);
    }
    const qs = params.toString();
    return qs ? `${base}?${qs}` : base;
  },
};


/* ══════════════════════════════════════════════════════════
   GLOBAL FILTER BAR
   ══════════════════════════════════════════════════════════ */

D.globalFilterBar = function () {
  const presets = [
    { id: 'today', label: 'Today', days: 1 },
    { id: '7d',    label: '7 days', days: 7 },
    { id: '30d',   label: '30 days', days: 30 },
    { id: '90d',   label: '90 days', days: 90 },
  ];
  const activeId = App.filters?.preset || '7d';

  const presetBtns = presets.map(p => {
    const cls = p.id === activeId ? ' active' : '';
    return `<button class="d-filter-btn${cls}" data-preset="${p.id}" onclick="App.setDatePreset('${p.id}', ${p.days})">${p.label}</button>`;
  }).join('');

  return `
    <div class="d-global-filter-bar">
      <div class="d-filter-group">
        ${presetBtns}
        <div class="d-filter-sep"></div>
        <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.refreshPage()" title="Refresh (R)">
          <span class="d-icon-refresh">&#x21BB;</span> Refresh
        </button>
      </div>
      <div class="d-filter-group">
        <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.exportPage()" title="Export data">
          &#x2913; Export
        </button>
        <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.toggleSearch()" title="Search (&#x2318;K)">
          &#x1F50D; Search
        </button>
      </div>
    </div>`;
};


/* ══════════════════════════════════════════════════════════
   KPI CARD (Enhanced)
   ══════════════════════════════════════════════════════════ */

D.kpi = function ({ label, value, sub, accent, trend, trendLabel, sparkData, id }) {
  const accentAttr = accent ? ` data-accent="${accent}"` : '';
  const idAttr = id ? ` id="${id}"` : '';
  let trendHtml = '';
  if (trend != null) {
    const cls = trend > 0 ? 'd-trend-up' : trend < 0 ? 'd-trend-down' : 'd-trend-flat';
    const arrow = trend > 0 ? '&#x2191;' : trend < 0 ? '&#x2193;' : '&#x2192;';
    const label2 = trendLabel || (trend > 0 ? '+' + D.fmt.pct(Math.abs(trend)) : D.fmt.pct(Math.abs(trend)));
    trendHtml = `<span class="d-trend ${cls}">${arrow} ${label2}</span>`;
  }
  const sparkHtml = sparkData
    ? `<div class="d-kpi-sparkline"><canvas data-sparkline='${JSON.stringify(sparkData)}'></canvas></div>`
    : '';
  return `
    <div class="d-kpi"${accentAttr}${idAttr}>
      <div class="d-kpi-label">${D.fmt.escapeHtml(label)}</div>
      <div class="d-kpi-value" data-animate-value>${value}</div>
      ${sub ? `<div class="d-kpi-sub">${sub} ${trendHtml}</div>` : (trendHtml ? `<div class="d-kpi-sub">${trendHtml}</div>` : '')}
      ${sparkHtml}
    </div>`;
};


/* ── KPI Grid ── */

D.kpiGrid = function (items, cols = 4) {
  return `<div class="d-kpi-grid" data-cols="${cols}">${items.join('')}</div>`;
};


/* ── KPI Loading ── */
D.kpiLoading = function (count = 4, cols = 4) {
  const items = [];
  for (let i = 0; i < count; i++) {
    items.push(`
      <div class="d-kpi">
        <div class="d-skeleton d-skeleton-text" style="width:60%"></div>
        <div class="d-skeleton d-skeleton-value" style="width:40%"></div>
        <div class="d-skeleton d-skeleton-text" style="width:80%;margin-top:8px"></div>
      </div>`);
  }
  return `<div class="d-kpi-grid" data-cols="${cols}">${items.join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   SPARKLINE RENDERER
   ══════════════════════════════════════════════════════════ */

D.renderSparklines = function (container) {
  const canvases = (container || document).querySelectorAll('canvas[data-sparkline]');
  canvases.forEach(canvas => {
    const data = JSON.parse(canvas.dataset.sparkline);
    if (!data || !data.length) return;

    const parent = canvas.parentElement;
    const w = parent.offsetWidth || 120;
    const h = parent.offsetHeight || 28;
    const dpr = window.devicePixelRatio || 1;

    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';

    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);

    const max = Math.max(...data, 1);
    const min = Math.min(...data, 0);
    const range = max - min || 1;
    const step = w / (data.length - 1 || 1);
    const pad = 2;

    // Gradient fill
    const gradient = ctx.createLinearGradient(0, 0, 0, h);
    gradient.addColorStop(0, 'rgba(232, 120, 48, 0.25)');
    gradient.addColorStop(1, 'rgba(232, 120, 48, 0)');

    ctx.beginPath();
    ctx.moveTo(0, h);
    data.forEach((v, i) => {
      const x = i * step;
      const y = h - pad - ((v - min) / range) * (h - pad * 2);
      if (i === 0) ctx.lineTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    // Line
    ctx.beginPath();
    data.forEach((v, i) => {
      const x = i * step;
      const y = h - pad - ((v - min) / range) * (h - pad * 2);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = '#e87830';
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.stroke();
  });
};


/* ══════════════════════════════════════════════════════════
   AREA CHART (Canvas)
   ══════════════════════════════════════════════════════════ */

D.areaChart = function ({ canvasId, data, labels, color, height, yFormat, showGrid, showLabels }) {
  const h = height || 200;
  return `
    <div class="d-chart-card">
      <div class="d-chart-body" style="min-height:${h}px;padding:0">
        <canvas id="${canvasId}" style="width:100%;height:${h}px"></canvas>
      </div>
    </div>`;
};

D.renderAreaChart = function (canvasId, data, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !data || !data.length) return;

  const parent = canvas.parentElement;
  const w = parent.offsetWidth || 600;
  const h = opts.height || 200;
  const dpr = window.devicePixelRatio || 1;

  canvas.width = w * dpr;
  canvas.height = h * dpr;
  canvas.style.width = w + 'px';
  canvas.style.height = h + 'px';

  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);

  const labels = opts.labels || data.map((_, i) => i);
  const color = opts.color || '#e87830';
  const yFormat = opts.yFormat || (v => v);

  const padLeft = 48;
  const padRight = 16;
  const padTop = 16;
  const padBottom = 28;
  const chartW = w - padLeft - padRight;
  const chartH = h - padTop - padBottom;

  const max = Math.max(...data, 1);
  const min = opts.min != null ? opts.min : 0;
  const range = max - min || 1;
  const step = chartW / (data.length - 1 || 1);

  function xPos(i) { return padLeft + i * step; }
  function yPos(v) { return padTop + chartH - ((v - min) / range) * chartH; }

  // Grid lines
  ctx.strokeStyle = 'rgba(255,255,255,0.04)';
  ctx.lineWidth = 1;
  const gridLines = 4;
  for (let i = 0; i <= gridLines; i++) {
    const y = padTop + (chartH / gridLines) * i;
    ctx.beginPath();
    ctx.moveTo(padLeft, y);
    ctx.lineTo(w - padRight, y);
    ctx.stroke();

    // Y-axis labels
    const val = max - (range / gridLines) * i;
    ctx.fillStyle = 'rgba(255,255,255,0.3)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(yFormat(val), padLeft - 8, y + 3);
  }

  // X-axis labels (show a few)
  ctx.fillStyle = 'rgba(255,255,255,0.3)';
  ctx.font = '10px Inter, sans-serif';
  ctx.textAlign = 'center';
  const labelStep = Math.max(1, Math.floor(data.length / 6));
  labels.forEach((l, i) => {
    if (i % labelStep === 0 || i === data.length - 1) {
      ctx.fillText(l, xPos(i), h - 6);
    }
  });

  // Gradient fill
  const gradient = ctx.createLinearGradient(0, padTop, 0, padTop + chartH);
  const rgb = hexToRgb(color);
  gradient.addColorStop(0, `rgba(${rgb},0.2)`);
  gradient.addColorStop(1, `rgba(${rgb},0)`);

  ctx.beginPath();
  ctx.moveTo(xPos(0), padTop + chartH);
  data.forEach((v, i) => ctx.lineTo(xPos(i), yPos(v)));
  ctx.lineTo(xPos(data.length - 1), padTop + chartH);
  ctx.closePath();
  ctx.fillStyle = gradient;
  ctx.fill();

  // Line
  ctx.beginPath();
  data.forEach((v, i) => {
    if (i === 0) ctx.moveTo(xPos(i), yPos(v));
    else ctx.lineTo(xPos(i), yPos(v));
  });
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.stroke();

  // Dots on hover areas (endpoints)
  [0, data.length - 1].forEach(i => {
    ctx.beginPath();
    ctx.arc(xPos(i), yPos(data[i]), 3, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
  });
};

function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r},${g},${b}`;
}


/* ══════════════════════════════════════════════════════════
   BAR CHART (Canvas)
   ══════════════════════════════════════════════════════════ */

D.renderBarChart = function (canvasId, data, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !data || !data.length) return;

  const parent = canvas.parentElement;
  const w = parent.offsetWidth || 600;
  const h = opts.height || 200;
  const dpr = window.devicePixelRatio || 1;

  canvas.width = w * dpr;
  canvas.height = h * dpr;
  canvas.style.width = w + 'px';
  canvas.style.height = h + 'px';

  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);

  const labels = opts.labels || data.map((_, i) => i);
  const colors = opts.colors || data.map(() => '#e87830');
  const yFormat = opts.yFormat || (v => v);

  const padLeft = 48;
  const padRight = 16;
  const padTop = 16;
  const padBottom = 40;
  const chartW = w - padLeft - padRight;
  const chartH = h - padTop - padBottom;

  const max = Math.max(...data, 1);
  const barW = Math.min(40, (chartW / data.length) * 0.6);
  const gap = chartW / data.length;

  // Grid
  ctx.strokeStyle = 'rgba(255,255,255,0.04)';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padTop + (chartH / 4) * i;
    ctx.beginPath();
    ctx.moveTo(padLeft, y);
    ctx.lineTo(w - padRight, y);
    ctx.stroke();

    const val = max - (max / 4) * i;
    ctx.fillStyle = 'rgba(255,255,255,0.3)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(yFormat(val), padLeft - 8, y + 3);
  }

  // Bars
  data.forEach((v, i) => {
    const x = padLeft + gap * i + (gap - barW) / 2;
    const barH = (v / max) * chartH;
    const y = padTop + chartH - barH;
    const color = typeof colors === 'string' ? colors : (colors[i] || '#e87830');

    // Bar with rounded top
    ctx.fillStyle = color;
    ctx.beginPath();
    const r = Math.min(3, barW / 2);
    ctx.moveTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
    ctx.arcTo(x + barW, y, x + barW, y + r, r);
    ctx.lineTo(x + barW, padTop + chartH);
    ctx.lineTo(x, padTop + chartH);
    ctx.closePath();
    ctx.fill();

    // Label
    ctx.fillStyle = 'rgba(255,255,255,0.35)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'center';
    ctx.save();
    ctx.translate(x + barW / 2, h - 6);
    if (labels[i] && labels[i].length > 6) {
      ctx.rotate(-Math.PI / 6);
      ctx.textAlign = 'right';
    }
    ctx.fillText(labels[i] || '', 0, 0);
    ctx.restore();
  });
};


/* ══════════════════════════════════════════════════════════
   CHART CARD (Enhanced)
   ══════════════════════════════════════════════════════════ */

D.chartCard = function ({ title, height, placeholder, canvasId, actions }) {
  const h = height || 200;
  const actionsHtml = actions || '';

  let bodyHtml;
  if (canvasId) {
    bodyHtml = `<canvas id="${canvasId}" style="width:100%;height:${h}px"></canvas>`;
  } else if (placeholder !== false) {
    bodyHtml = `
      <div class="d-chart-placeholder" style="min-height:${h}px">
        <div class="d-chart-placeholder-icon">&#x1F4CA;</div>
        <div>${placeholder || 'Chart data will appear here'}</div>
      </div>`;
  } else {
    bodyHtml = '';
  }

  return `
    <div class="d-chart-card">
      <div class="d-chart-header">
        <div class="d-chart-title">${D.fmt.escapeHtml(title)}</div>
        ${actionsHtml ? `<div class="d-chart-actions">${actionsHtml}</div>` : ''}
      </div>
      <div class="d-chart-body" style="min-height:${h}px">
        ${bodyHtml}
      </div>
    </div>`;
};


/* ── Chart Grid ── */

D.chartGrid = function (items, cols = 2) {
  return `<div class="d-chart-grid" data-cols="${cols}">${items.join('')}</div>`;
};

/* ── Chart Loading ── */
D.chartLoading = function (count = 2, cols = 2) {
  const items = [];
  for (let i = 0; i < count; i++) {
    items.push(`
      <div class="d-chart-card">
        <div class="d-chart-header"><div class="d-skeleton d-skeleton-text" style="width:120px"></div></div>
        <div class="d-skeleton d-skeleton-chart"></div>
      </div>`);
  }
  return `<div class="d-chart-grid" data-cols="${cols}">${items.join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   STATUS BADGE
   ══════════════════════════════════════════════════════════ */

D.badge = function (text, variant = 'neutral', dot = false) {
  const dotHtml = dot ? '<span class="d-badge-dot"></span>' : '';
  return `<span class="d-badge d-badge-${variant}">${dotHtml}${D.fmt.escapeHtml(text)}</span>`;
};


/* ── Trend Badge ── */

D.trend = function (value, label) {
  if (value == null) return '';
  const cls = value > 0 ? 'd-trend-up' : value < 0 ? 'd-trend-down' : 'd-trend-flat';
  const arrow = value > 0 ? '&#x2191;' : value < 0 ? '&#x2193;' : '&#x2192;';
  const text = label || (value > 0 ? '+' + D.fmt.pct(Math.abs(value)) : D.fmt.pct(Math.abs(value)));
  return `<span class="d-trend ${cls}">${arrow} ${text}</span>`;
};


/* ══════════════════════════════════════════════════════════
   SECTION HEADER
   ══════════════════════════════════════════════════════════ */

D.sectionHeader = function (title, actions = '') {
  return `
    <div class="d-section-header">
      <div class="d-section-title">${D.fmt.escapeHtml(title)}</div>
      ${actions ? `<div class="d-section-actions">${actions}</div>` : ''}
    </div>`;
};


/* ══════════════════════════════════════════════════════════
   TABLE
   ══════════════════════════════════════════════════════════ */

D.table = function ({ title, headers, rows, emptyText }) {
  const headerHtml = headers.map(h => {
    const align = h.align === 'right' ? ' style="text-align:right"' : '';
    return `<th${align}>${D.fmt.escapeHtml(h.label || h)}</th>`;
  }).join('');

  let bodyHtml;
  if (!rows || rows.length === 0) {
    bodyHtml = `<tr><td colspan="${headers.length}" style="text-align:center;padding:32px;color:var(--d-text-3)">
      ${emptyText || 'No data yet'}
    </td></tr>`;
  } else {
    bodyHtml = rows.map(row => {
      const cls = row.clickable ? ' class="clickable"' : '';
      const onclick = row.onclick ? ` onclick="${row.onclick}"` : '';
      const cells = row.cells.map((c, i) => {
        const align = headers[i] && headers[i].align === 'right' ? ' style="text-align:right"' : '';
        return `<td${align}>${c}</td>`;
      }).join('');
      return `<tr${cls}${onclick}>${cells}</tr>`;
    }).join('');
  }

  const titleHtml = title
    ? `<div class="d-table-header"><div class="d-table-title">${D.fmt.escapeHtml(title)}</div></div>`
    : '';

  return `
    <div class="d-table-wrap">
      ${titleHtml}
      <table class="d-table">
        <thead><tr>${headerHtml}</tr></thead>
        <tbody>${bodyHtml}</tbody>
      </table>
    </div>`;
};

/* ── Table Loading ── */
D.tableLoading = function (cols = 4, rowCount = 3) {
  const headers = Array(cols).fill(0).map(() =>
    `<th><div class="d-skeleton d-skeleton-text" style="width:60%"></div></th>`
  ).join('');
  const rows = Array(rowCount).fill(0).map(() => {
    const cells = Array(cols).fill(0).map(() =>
      `<td><div class="d-skeleton d-skeleton-text" style="width:${50 + Math.random() * 40}%"></div></td>`
    ).join('');
    return `<tr>${cells}</tr>`;
  }).join('');

  return `
    <div class="d-table-wrap">
      <table class="d-table">
        <thead><tr>${headers}</tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
};


/* ══════════════════════════════════════════════════════════
   FILTER BAR
   ══════════════════════════════════════════════════════════ */

D.filterBar = function (filters, activeId) {
  const btns = filters.map(f => {
    const cls = f.id === activeId ? ' active' : '';
    return `<button class="d-filter-btn${cls}" data-filter="${f.id}" onclick="D.onFilter && D.onFilter('${f.id}')">${D.fmt.escapeHtml(f.label)}</button>`;
  }).join('');
  return `<div class="d-filters">${btns}</div>`;
};


/* ── Date Range Picker (simple — use globalFilterBar for full version) ── */

D.dateRange = function (active) {
  const ranges = [
    { id: 'today', label: 'Today' },
    { id: '7d',    label: '7 days' },
    { id: '30d',   label: '30 days' },
    { id: '90d',   label: '90 days' },
  ];
  return D.filterBar(ranges, active || '7d');
};


/* ══════════════════════════════════════════════════════════
   DRILL-DOWN DRAWER
   ══════════════════════════════════════════════════════════ */

D.drillDown = {
  open(title, contentHtml) {
    const drawer = document.getElementById('d-drill-down');
    if (!drawer) return;
    drawer.querySelector('.d-drawer-title').textContent = title;
    drawer.querySelector('.d-drawer-body').innerHTML = contentHtml;
    drawer.classList.add('open');
    document.body.classList.add('d-drawer-open');
  },

  close() {
    const drawer = document.getElementById('d-drill-down');
    if (!drawer) return;
    drawer.classList.remove('open');
    document.body.classList.remove('d-drawer-open');
  },

  /** Export data as JSON or CSV */
  exportData(data, filename, format = 'json') {
    let blob;
    if (format === 'csv' && Array.isArray(data)) {
      const keys = Object.keys(data[0] || {});
      const csv = [keys.join(','), ...data.map(r => keys.map(k => JSON.stringify(r[k] ?? '')).join(','))].join('\n');
      blob = new Blob([csv], { type: 'text/csv' });
    } else {
      blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    }
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  },
};


/* ══════════════════════════════════════════════════════════
   LOADING / EMPTY / ERROR STATES
   ══════════════════════════════════════════════════════════ */

D.loading = function (type) {
  if (type === 'kpi') {
    return `
      <div class="d-kpi">
        <div class="d-skeleton d-skeleton-text"></div>
        <div class="d-skeleton d-skeleton-value"></div>
      </div>`;
  }
  if (type === 'chart') {
    return `
      <div class="d-chart-card">
        <div class="d-chart-header"><div class="d-skeleton d-skeleton-text" style="width:120px"></div></div>
        <div class="d-skeleton d-skeleton-chart"></div>
      </div>`;
  }
  // Default: generic loading
  return `
    <div class="d-empty">
      <div class="d-empty-icon d-spin">&#x21BB;</div>
      <div class="d-empty-title">Loading...</div>
    </div>`;
};

D.empty = function (icon, title, desc) {
  return `
    <div class="d-empty">
      <div class="d-empty-icon">${icon || '&#x1F4AD;'}</div>
      <div class="d-empty-title">${D.fmt.escapeHtml(title || 'No data')}</div>
      ${desc ? `<div class="d-empty-desc">${D.fmt.escapeHtml(desc)}</div>` : ''}
    </div>`;
};

D.error = function (title, desc, retryFn) {
  const retryBtn = retryFn
    ? `<button class="d-btn d-btn-sm" onclick="${retryFn}">Retry</button>`
    : '';
  return `
    <div class="d-error">
      <div class="d-error-icon">&#x26A0;</div>
      <div class="d-error-title">${D.fmt.escapeHtml(title || 'Something went wrong')}</div>
      ${desc ? `<div class="d-error-desc">${D.fmt.escapeHtml(desc)}</div>` : ''}
      ${retryBtn}
    </div>`;
};


/* ══════════════════════════════════════════════════════════
   TIMELINE
   ══════════════════════════════════════════════════════════ */

D.timeline = function (items) {
  if (!items || !items.length) {
    return D.empty('&#x1F4AC;', 'No recent events', 'Events will appear here as activity occurs');
  }
  const html = items.map(item => `
    <div class="d-timeline-item">
      <div class="d-timeline-dot" data-type="${item.type || ''}"></div>
      <div class="d-timeline-time">${D.fmt.escapeHtml(item.time)}</div>
      <div class="d-timeline-text">${D.fmt.escapeHtml(item.text)}</div>
      ${item.meta ? `<div class="d-timeline-meta">${D.fmt.escapeHtml(item.meta)}</div>` : ''}
    </div>
  `).join('');
  return `<div class="d-timeline">${html}</div>`;
};


/* ══════════════════════════════════════════════════════════
   PROGRESS BAR
   ══════════════════════════════════════════════════════════ */

D.progressBar = function (value, max, opts = {}) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  const color = opts.color || 'var(--d-brand)';
  const label = opts.label || '';
  return `
    <div class="d-progress">
      <div class="d-progress-bar" style="width:${pct}%;background:${color}"></div>
      ${label ? `<span class="d-progress-label">${label}</span>` : ''}
    </div>`;
};
