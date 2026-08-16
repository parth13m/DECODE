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
  ctx.strokeStyle = 'rgba(0,0,0,0.06)';
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
    ctx.fillStyle = 'rgba(0,0,0,0.4)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(yFormat(val), padLeft - 8, y + 3);
  }

  // X-axis labels (show a few)
  ctx.fillStyle = 'rgba(0,0,0,0.4)';
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

  // Tooltip
  const seriesName = opts.seriesName || '';
  _attachChartTooltip(canvas, (mx, my) => {
    const idx = _nearestIndex(mx, padLeft, step, data.length);
    if (idx < 0) return null;
    // Redraw to show hover dot
    const px = xPos(idx), py = yPos(data[idx]);
    if (Math.abs(mx - px) > step * 0.6) return null;
    const lbl = labels[idx] != null ? labels[idx] : idx;
    const val = yFormat(data[idx]);
    let html = `<div style="color:rgba(0,0,0,.45);margin-bottom:2px">${lbl}</div>`;
    html += _tipLine(color, seriesName || 'Value', val);
    return { html };
  });
};

function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r},${g},${b}`;
}


/* ══════════════════════════════════════════════════════════
   CHART TOOLTIP (Shared)
   ══════════════════════════════════════════════════════════ */

const _chartTooltip = (() => {
  let el = null;
  function ensure() {
    if (el) return el;
    el = document.createElement('div');
    el.className = 'd-chart-tooltip';
    el.style.cssText =
      'position:fixed;pointer-events:none;z-index:99999;opacity:0;transition:opacity .12s;' +
      'background:rgba(255,255,255,.95);border:1px solid rgba(0,0,0,.1);border-radius:6px;' +
      'padding:6px 10px;font:11px/1.5 Inter,sans-serif;color:#1f1d1a;' +
      'backdrop-filter:blur(8px);max-width:240px;white-space:nowrap;box-shadow:0 4px 12px rgba(0,0,0,.1);';
    document.body.appendChild(el);
    return el;
  }
  function show(html, x, y) {
    const tip = ensure();
    tip.innerHTML = html;
    tip.style.opacity = '1';
    // Position: prefer right of cursor, flip if clipping
    const pad = 12;
    let left = x + pad;
    let top = y - tip.offsetHeight - 6;
    if (left + tip.offsetWidth > window.innerWidth - 8) left = x - tip.offsetWidth - pad;
    if (top < 4) top = y + pad;
    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
  }
  function hide() {
    if (el) el.style.opacity = '0';
  }
  return { show, hide };
})();

/** Get mouse position relative to canvas in CSS pixels */
function _canvasMousePos(canvas, e) {
  const r = canvas.getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top };
}

/** Attach tooltip handlers to a canvas that has hitTest metadata stored on it.
 *  hitTest(x, y) should return { html } or null. */
function _attachChartTooltip(canvas, hitTest) {
  canvas.addEventListener('mousemove', e => {
    const pos = _canvasMousePos(canvas, e);
    const hit = hitTest(pos.x, pos.y);
    if (hit) {
      _chartTooltip.show(hit.html, e.clientX, e.clientY);
    } else {
      _chartTooltip.hide();
    }
  });
  canvas.addEventListener('mouseleave', () => _chartTooltip.hide());
}

/** Build a tooltip line: colored dot + label + value */
function _tipLine(color, label, value) {
  const dot = color
    ? `<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${color};margin-right:5px;vertical-align:middle"></span>`
    : '';
  return `<div>${dot}<span style="color:rgba(0,0,0,.5)">${label}:</span> <strong>${value}</strong></div>`;
}

/** Find nearest data-point index for a given x in a line/area chart */
function _nearestIndex(x, padLeft, step, len) {
  const idx = Math.round((x - padLeft) / step);
  return idx >= 0 && idx < len ? idx : -1;
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
  ctx.strokeStyle = 'rgba(0,0,0,0.06)';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padTop + (chartH / 4) * i;
    ctx.beginPath();
    ctx.moveTo(padLeft, y);
    ctx.lineTo(w - padRight, y);
    ctx.stroke();

    const val = max - (max / 4) * i;
    ctx.fillStyle = 'rgba(0,0,0,0.4)';
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
    ctx.fillStyle = 'rgba(0,0,0,0.45)';
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

  // Tooltip
  _attachChartTooltip(canvas, (mx, my) => {
    for (let i = 0; i < data.length; i++) {
      const bx = padLeft + gap * i + (gap - barW) / 2;
      const barH = (data[i] / max) * chartH;
      const by = padTop + chartH - barH;
      if (mx >= bx && mx <= bx + barW && my >= by && my <= padTop + chartH) {
        const lbl = labels[i] != null ? labels[i] : `Bar ${i + 1}`;
        const val = yFormat(data[i]);
        const c = typeof colors === 'string' ? colors : (colors[i] || '#e87830');
        let html = `<div style="color:rgba(0,0,0,.45);margin-bottom:2px">${lbl}</div>`;
        html += _tipLine(c, 'Value', val);
        return { html };
      }
    }
    return null;
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


/* ══════════════════════════════════════════════════════════
   DONUT CHART (Canvas)
   ══════════════════════════════════════════════════════════ */

D.renderDonutChart = function (canvasId, segments, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !segments || !segments.length) return;

  const parent = canvas.parentElement;
  const size = Math.min(parent.offsetWidth || 240, opts.height || 240);
  const dpr = window.devicePixelRatio || 1;

  canvas.width = size * dpr;
  canvas.height = size * dpr;
  canvas.style.width = size + 'px';
  canvas.style.height = size + 'px';

  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);

  const cx = size / 2;
  const cy = size / 2;
  const outerR = size / 2 - 8;
  const innerR = outerR * 0.62;
  const total = segments.reduce((s, seg) => s + (seg.value || 0), 0);
  if (total === 0) return;

  let startAngle = -Math.PI / 2;
  segments.forEach(seg => {
    const sweep = (seg.value / total) * Math.PI * 2;
    ctx.beginPath();
    ctx.arc(cx, cy, outerR, startAngle, startAngle + sweep);
    ctx.arc(cx, cy, innerR, startAngle + sweep, startAngle, true);
    ctx.closePath();
    ctx.fillStyle = seg.color || '#e87830';
    ctx.fill();
    startAngle += sweep;
  });

  // Center text
  if (opts.centerLabel) {
    ctx.fillStyle = 'rgba(0,0,0,0.85)';
    ctx.font = 'bold 22px Inter, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(opts.centerLabel, cx, cy - 6);
    if (opts.centerSub) {
      ctx.fillStyle = 'rgba(0,0,0,0.4)';
      ctx.font = '11px Inter, sans-serif';
      ctx.fillText(opts.centerSub, cx, cy + 14);
    }
  }

  // Tooltip
  _attachChartTooltip(canvas, (mx, my) => {
    const dx = mx - cx, dy = my - cy;
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (dist < innerR || dist > outerR) return null;
    let angle = Math.atan2(dy, dx);
    if (angle < -Math.PI / 2) angle += Math.PI * 2;
    let cumAngle = -Math.PI / 2;
    for (let i = 0; i < segments.length; i++) {
      const sweep = (segments[i].value / total) * Math.PI * 2;
      if (angle >= cumAngle && angle < cumAngle + sweep) {
        const pct = ((segments[i].value / total) * 100).toFixed(1);
        let html = _tipLine(segments[i].color, segments[i].label, D.fmt.num(segments[i].value));
        html += `<div style="color:rgba(0,0,0,.45);font-size:10px">${pct}% of total</div>`;
        return { html };
      }
      cumAngle += sweep;
    }
    return null;
  });
};

/** HTML legend for donut charts */
D.donutLegend = function (segments, total) {
  return `<div class="d-donut-legend">${segments.map(s => {
    const pct = total > 0 ? ((s.value / total) * 100).toFixed(1) : 0;
    return `<div class="d-donut-legend-item">
      <span class="d-donut-legend-dot" style="background:${s.color}"></span>
      <span class="d-donut-legend-label">${D.fmt.escapeHtml(s.label)}</span>
      <span class="d-donut-legend-value">${D.fmt.num(s.value)}</span>
      <span class="d-donut-legend-pct">${pct}%</span>
    </div>`;
  }).join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   HORIZONTAL BAR CHART (CSS-based)
   ══════════════════════════════════════════════════════════ */

D.horizontalBars = function (items, opts = {}) {
  if (!items || !items.length) return D.empty(null, 'No data');
  const max = Math.max(...items.map(i => i.value), 1);
  const valueFormat = opts.valueFormat || (v => D.fmt.num(v));
  return `<div class="d-hbar-list">${items.map(item => {
    const pct = (item.value / max) * 100;
    const color = item.color || 'var(--d-brand)';
    return `<div class="d-hbar-item">
      <div class="d-hbar-label">${D.fmt.escapeHtml(item.label)}</div>
      <div class="d-hbar-track">
        <div class="d-hbar-fill" style="width:${pct}%;background:${color}"></div>
      </div>
      <div class="d-hbar-value">${valueFormat(item.value)}</div>
    </div>`;
  }).join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   STACKED AREA CHART (Canvas)
   ══════════════════════════════════════════════════════════ */

D.renderStackedAreaChart = function (canvasId, series, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !series || !series.length) return;

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

  const labels = opts.labels || [];
  const padLeft = 48, padRight = 16, padTop = 16, padBottom = 28;
  const chartW = w - padLeft - padRight;
  const chartH = h - padTop - padBottom;

  const len = series[0]?.data?.length || 0;
  if (len === 0) return;

  // Compute stacked totals per point
  const stacked = Array(len).fill(0);
  series.forEach(s => s.data.forEach((v, i) => stacked[i] += v));
  const max = Math.max(...stacked, 1);
  const step = chartW / (len - 1 || 1);

  function xPos(i) { return padLeft + i * step; }
  function yPos(v) { return padTop + chartH - (v / max) * chartH; }

  // Grid
  ctx.strokeStyle = 'rgba(0,0,0,0.06)';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padTop + (chartH / 4) * i;
    ctx.beginPath(); ctx.moveTo(padLeft, y); ctx.lineTo(w - padRight, y); ctx.stroke();
    ctx.fillStyle = 'rgba(0,0,0,0.4)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(D.fmt.num(Math.round(max - (max / 4) * i)), padLeft - 8, y + 3);
  }

  // X labels
  ctx.fillStyle = 'rgba(0,0,0,0.4)';
  ctx.textAlign = 'center';
  const labelStep = Math.max(1, Math.floor(len / 6));
  labels.forEach((l, i) => {
    if (i % labelStep === 0 || i === len - 1) ctx.fillText(l, xPos(i), h - 6);
  });

  // Draw stacked areas bottom to top
  const cumulative = Array(len).fill(0);
  series.forEach(s => {
    const prev = [...cumulative];
    s.data.forEach((v, i) => cumulative[i] += v);

    ctx.beginPath();
    for (let i = 0; i < len; i++) {
      const x = xPos(i), y = yPos(cumulative[i]);
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    }
    for (let i = len - 1; i >= 0; i--) {
      ctx.lineTo(xPos(i), yPos(prev[i]));
    }
    ctx.closePath();
    const rgb = hexToRgb(s.color || '#e87830');
    ctx.fillStyle = `rgba(${rgb},0.35)`;
    ctx.fill();

    // Top line
    ctx.beginPath();
    for (let i = 0; i < len; i++) {
      const x = xPos(i), y = yPos(cumulative[i]);
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    }
    ctx.strokeStyle = s.color || '#e87830';
    ctx.lineWidth = 1.5;
    ctx.stroke();
  });

  // Tooltip
  const yFormat = opts.yFormat || (v => D.fmt.num(Math.round(v)));
  _attachChartTooltip(canvas, (mx, my) => {
    const idx = _nearestIndex(mx, padLeft, step, len);
    if (idx < 0 || Math.abs(mx - xPos(idx)) > step * 0.6) return null;
    const lbl = labels[idx] != null ? labels[idx] : idx;
    let html = `<div style="color:rgba(0,0,0,.45);margin-bottom:2px">${lbl}</div>`;
    series.forEach(s => {
      html += _tipLine(s.color || '#e87830', s.label || 'Series', yFormat(s.data[idx]));
    });
    html += `<div style="border-top:1px solid rgba(0,0,0,.1);margin-top:3px;padding-top:3px;color:rgba(0,0,0,.45)">Total: <strong>${yFormat(stacked[idx])}</strong></div>`;
    return { html };
  });
};


/* ══════════════════════════════════════════════════════════
   HEATMAP (Canvas — e.g. hour × day-of-week)
   ══════════════════════════════════════════════════════════ */

D.renderHeatmap = function (canvasId, grid, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !grid || !grid.length) return;

  const parent = canvas.parentElement;
  const w = parent.offsetWidth || 600;
  const h = opts.height || 180;
  const dpr = window.devicePixelRatio || 1;

  canvas.width = w * dpr;
  canvas.height = h * dpr;
  canvas.style.width = w + 'px';
  canvas.style.height = h + 'px';

  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);

  const rows = grid.length;
  const cols = grid[0]?.length || 0;
  if (cols === 0) return;

  const rowLabels = opts.rowLabels || [];
  const colLabels = opts.colLabels || [];
  const padLeft = 40, padTop = 20, padRight = 8, padBottom = 8;
  const cellW = (w - padLeft - padRight) / cols;
  const cellH = (h - padTop - padBottom) / rows;
  const gap = 2;

  const flat = grid.flat();
  const max = Math.max(...flat, 1);
  const color = opts.color || '#e87830';
  const rgb = hexToRgb(color);

  // Row labels
  ctx.fillStyle = 'rgba(0,0,0,0.4)';
  ctx.font = '10px Inter, sans-serif';
  ctx.textAlign = 'right';
  rowLabels.forEach((l, i) => {
    ctx.fillText(l, padLeft - 6, padTop + i * cellH + cellH / 2 + 3);
  });

  // Col labels
  ctx.textAlign = 'center';
  colLabels.forEach((l, i) => {
    if (i % Math.max(1, Math.floor(cols / 12)) === 0) {
      ctx.fillText(l, padLeft + i * cellW + cellW / 2, padTop - 6);
    }
  });

  // Cells
  grid.forEach((row, ri) => {
    row.forEach((val, ci) => {
      const intensity = max > 0 ? val / max : 0;
      ctx.fillStyle = `rgba(${rgb},${0.05 + intensity * 0.8})`;
      ctx.beginPath();
      ctx.roundRect(
        padLeft + ci * cellW + gap / 2,
        padTop + ri * cellH + gap / 2,
        cellW - gap, cellH - gap, 3
      );
      ctx.fill();
    });
  });

  // Tooltip
  const valFormat = opts.valueFormat || (v => D.fmt.num(v));
  _attachChartTooltip(canvas, (mx, my) => {
    const ci = Math.floor((mx - padLeft) / cellW);
    const ri = Math.floor((my - padTop) / cellH);
    if (ri < 0 || ri >= rows || ci < 0 || ci >= cols) return null;
    const val = grid[ri][ci];
    const rowLbl = rowLabels[ri] || `Row ${ri}`;
    const colLbl = colLabels[ci] || `Col ${ci}`;
    let html = `<div style="color:rgba(0,0,0,.45);margin-bottom:2px">${colLbl} · ${rowLbl}</div>`;
    html += `<div><strong>${valFormat(val)}</strong></div>`;
    return { html };
  });
};


/* ══════════════════════════════════════════════════════════
   MULTI-LINE CHART (Canvas)
   ══════════════════════════════════════════════════════════ */

D.renderMultiLineChart = function (canvasId, series, opts = {}) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !series || !series.length) return;

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

  const labels = opts.labels || [];
  const yFormat = opts.yFormat || (v => v);
  const padLeft = 48, padRight = 16, padTop = 16, padBottom = 28;
  const chartW = w - padLeft - padRight;
  const chartH = h - padTop - padBottom;

  const allVals = series.flatMap(s => s.data);
  const max = Math.max(...allVals, 1);
  const min = opts.min != null ? opts.min : 0;
  const range = max - min || 1;
  const len = series[0]?.data?.length || 0;
  if (len === 0) return;
  const step = chartW / (len - 1 || 1);

  function xPos(i) { return padLeft + i * step; }
  function yPos(v) { return padTop + chartH - ((v - min) / range) * chartH; }

  // Grid
  ctx.strokeStyle = 'rgba(0,0,0,0.06)';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padTop + (chartH / 4) * i;
    ctx.beginPath(); ctx.moveTo(padLeft, y); ctx.lineTo(w - padRight, y); ctx.stroke();
    ctx.fillStyle = 'rgba(0,0,0,0.4)';
    ctx.font = '10px Inter, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(yFormat(max - (range / 4) * i), padLeft - 8, y + 3);
  }

  // X labels
  ctx.fillStyle = 'rgba(0,0,0,0.4)';
  ctx.textAlign = 'center';
  const labelStep = Math.max(1, Math.floor(len / 6));
  labels.forEach((l, i) => {
    if (i % labelStep === 0 || i === len - 1) ctx.fillText(l, xPos(i), h - 6);
  });

  // Lines
  series.forEach(s => {
    ctx.beginPath();
    s.data.forEach((v, i) => {
      i === 0 ? ctx.moveTo(xPos(i), yPos(v)) : ctx.lineTo(xPos(i), yPos(v));
    });
    ctx.strokeStyle = s.color || '#e87830';
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();
  });

  // Tooltip
  _attachChartTooltip(canvas, (mx, my) => {
    const idx = _nearestIndex(mx, padLeft, step, len);
    if (idx < 0 || Math.abs(mx - xPos(idx)) > step * 0.6) return null;
    const lbl = labels[idx] != null ? labels[idx] : idx;
    let html = `<div style="color:rgba(0,0,0,.45);margin-bottom:2px">${lbl}</div>`;
    series.forEach(s => {
      html += _tipLine(s.color || '#e87830', s.label || 'Series', yFormat(s.data[idx]));
    });
    return { html };
  });
};

/** Inline legend for multi-series charts */
D.chartLegend = function (items) {
  return `<div class="d-chart-legend">${items.map(i =>
    `<span class="d-chart-legend-item"><span class="d-chart-legend-dot" style="background:${i.color}"></span>${D.fmt.escapeHtml(i.label)}</span>`
  ).join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   STAT CARD (compact inline stat)
   ══════════════════════════════════════════════════════════ */

D.statRow = function (items) {
  return `<div class="d-stat-row">${items.map(i => `
    <div class="d-stat-item">
      <div class="d-stat-value" style="${i.color ? 'color:' + i.color : ''}">${i.value}</div>
      <div class="d-stat-label">${D.fmt.escapeHtml(i.label)}</div>
    </div>`).join('')}</div>`;
};


/* ══════════════════════════════════════════════════════════
   TOKEN BREAKDOWN TABLE
   ══════════════════════════════════════════════════════════ */

/** Renders a full token analytics table from an array of row objects.
 *  Each row: { key, requests, prompt_tokens, completion_tokens, total_tokens,
 *              avg_prompt_tokens, avg_completion_tokens, avg_total_tokens,
 *              total_cost_usd, avg_cost_usd, success_rate, avg_latency_ms }
 */
D.tokenBreakdownTable = function (rows, opts = {}) {
  if (!rows || !rows.length) return D.empty(null, opts.emptyTitle || 'No token data', opts.emptySub || 'No requests found for this breakdown');
  const labelHeader = opts.labelHeader || 'Category';
  return D.table({
    headers: [
      labelHeader,
      { label: 'Requests', align: 'right' },
      { label: 'Input Tok', align: 'right' },
      { label: 'Output Tok', align: 'right' },
      { label: 'Total Tok', align: 'right' },
      { label: 'Avg In', align: 'right' },
      { label: 'Avg Out', align: 'right' },
      { label: 'Avg Total', align: 'right' },
      { label: 'Cost', align: 'right' },
      { label: 'Avg Cost', align: 'right' },
    ],
    rows: rows.map(r => ({
      cells: [
        `<strong>${D.fmt.escapeHtml(r.key)}</strong>`,
        D.fmt.num(r.requests),
        D.fmt.num(r.prompt_tokens),
        D.fmt.num(r.completion_tokens),
        D.fmt.num(r.total_tokens),
        D.fmt.num(r.avg_prompt_tokens),
        D.fmt.num(r.avg_completion_tokens),
        D.fmt.num(r.avg_total_tokens),
        D.fmt.usd(r.total_cost_usd),
        D.fmt.usd(r.avg_cost_usd, 4),
      ],
      clickable: opts.onRowClick ? true : false,
      onclick: opts.onRowClick ? opts.onRowClick(r) : undefined,
    })),
    emptyText: opts.emptyTitle || 'No data',
  });
};


/* ══════════════════════════════════════════════════════════
   RATIO BAR — stacked horizontal bar showing input vs output
   ══════════════════════════════════════════════════════════ */

/** Renders a list of features with stacked input/output token bars.
 *  items: [{ label, input, output }]
 */
D.ratioBarList = function (items, opts = {}) {
  if (!items || !items.length) return '';
  const inputColor = opts.inputColor || '#3b82f6';
  const outputColor = opts.outputColor || '#10b981';
  return `<div class="d-ratio-bar-list">
    ${items.map(item => {
      const total = (item.input || 0) + (item.output || 0);
      const inputPct = total > 0 ? (item.input / total * 100) : 50;
      const outputPct = total > 0 ? (item.output / total * 100) : 50;
      const ratio = item.input > 0 ? (item.output / item.input).toFixed(2) : '—';
      return `<div class="d-ratio-bar-item">
        <div class="d-ratio-bar-header">
          <span class="d-ratio-bar-label">${D.fmt.escapeHtml(item.label)}</span>
          <span class="d-ratio-bar-meta">
            <span style="color:${inputColor}">In: ${D.fmt.num(item.input)}</span>
            <span style="color:${outputColor};margin-left:8px">Out: ${D.fmt.num(item.output)}</span>
            <span style="color:var(--d-text-3);margin-left:8px">Ratio: ${ratio}</span>
          </span>
        </div>
        <div class="d-ratio-bar-track">
          <div class="d-ratio-bar-fill" style="width:${inputPct.toFixed(1)}%;background:${inputColor}" title="Input: ${inputPct.toFixed(1)}%"></div>
          <div class="d-ratio-bar-fill" style="width:${outputPct.toFixed(1)}%;background:${outputColor}" title="Output: ${outputPct.toFixed(1)}%"></div>
        </div>
        <div class="d-ratio-bar-pcts">
          <span style="color:${inputColor}">${inputPct.toFixed(1)}% input</span>
          <span style="color:${outputColor}">${outputPct.toFixed(1)}% output</span>
        </div>
      </div>`;
    }).join('')}
  </div>`;
};


/** Percentile cards — side-by-side display for input/output distributions */
D.percentileCard = function (label, data, opts = {}) {
  if (!data) return '';
  const color = opts.color || 'var(--d-text-1)';
  const maxVal = data.max || 1;
  const bars = [
    { label: 'P50', value: data.p50, pct: data.p50 / maxVal * 100 },
    { label: 'P95', value: data.p95, pct: data.p95 / maxVal * 100 },
    { label: 'P99', value: data.p99, pct: data.p99 / maxVal * 100 },
    { label: 'Max', value: data.max, pct: 100 },
  ];
  return `<div class="d-percentile-card">
    <div class="d-percentile-title" style="color:${color}">${D.fmt.escapeHtml(label)}</div>
    ${bars.map(b => `
      <div class="d-percentile-row">
        <span class="d-percentile-label">${b.label}</span>
        <div class="d-percentile-track">
          <div class="d-percentile-fill" style="width:${Math.min(b.pct, 100).toFixed(1)}%;background:${color};opacity:${b.label === 'Max' ? 0.3 : 0.6}"></div>
        </div>
        <span class="d-percentile-value">${D.fmt.num(b.value)}</span>
      </div>
    `).join('')}
  </div>`;
};
