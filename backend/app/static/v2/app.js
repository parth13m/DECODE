/* ══════════════════════════════════════════════════════════
   Decode Dashboard v2 — Application Shell
   ══════════════════════════════════════════════════════════ */

const App = {
  token: null,
  currentPage: null,
  pages: {},
  _userDetailId: null,

  /* ── Global Filter State ── */
  filters: {
    preset: '7d',
    days: 7,
    start: null,
    end: null,
  },

  /* ── Bootstrap ── */

  init() {
    const saved = sessionStorage.getItem('decode_admin_v2_token');
    if (saved) {
      this.token = saved;
      this.validateAndStart();
    } else {
      this.showAuth();
    }
    this._initKeyboardShortcuts();
  },

  /* ── Auth ── */

  showAuth() {
    document.getElementById('d-auth').classList.remove('d-hidden');
    document.getElementById('d-shell').classList.add('d-hidden');
    const input = document.getElementById('d-auth-token');
    if (input) input.focus();
  },

  hideAuth() {
    document.getElementById('d-auth').classList.add('d-hidden');
    document.getElementById('d-shell').classList.remove('d-hidden');
  },

  async authenticate() {
    const input = document.getElementById('d-auth-token');
    const errEl = document.getElementById('d-auth-error');
    const token = input.value.trim();
    if (!token) { errEl.textContent = 'Please enter an admin token'; return; }
    errEl.textContent = '';
    try {
      const res = await this.apiFetch('/api/admin/analytics', { token });
      if (res.ok) {
        this.token = token;
        sessionStorage.setItem('decode_admin_v2_token', token);
        this.hideAuth();
        this.navigate('executive');
      } else {
        errEl.textContent = res.status === 401 ? 'Invalid token' : `Error: ${res.status}`;
      }
    } catch (e) { errEl.textContent = 'Connection failed'; }
  },

  logout() {
    this.token = null;
    sessionStorage.removeItem('decode_admin_v2_token');
    D.api.clearCache();
    this.showAuth();
  },

  async validateAndStart() {
    try {
      const res = await this.apiFetch('/api/admin/analytics');
      if (res.ok) { this.hideAuth(); this.navigate('executive'); }
      else { this.showAuth(); }
    } catch { this.showAuth(); }
  },

  /* ── Raw API ── */

  async apiFetch(path, opts = {}) {
    const token = opts.token || this.token;
    const headers = { 'Authorization': `Bearer ${token}` };
    if (opts.body) headers['Content-Type'] = 'application/json';
    return fetch(path, {
      method: opts.method || 'GET',
      headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
  },

  /* ── Navigation ── */

  navigate(pageId) {
    const sidebarId = pageId === 'userDetail' ? 'users' : pageId;
    document.querySelectorAll('.d-nav-item').forEach(el => {
      el.classList.toggle('active', el.dataset.page === sidebarId);
    });

    const meta = this.pageMeta[pageId] || {};
    document.getElementById('d-topbar-title').textContent = meta.title || pageId;
    document.getElementById('d-topbar-subtitle').textContent = meta.subtitle || '';

    document.querySelectorAll('.d-page-view').forEach(el => {
      el.classList.toggle('active', el.id === `page-${pageId}`);
    });

    this.currentPage = pageId;
    if (this.pages[pageId] && this.pages[pageId].render) {
      this.pages[pageId].render();
    }
  },

  navigateToUser(userId) {
    this._userDetailId = userId;
    this.navigate('userDetail');
  },

  pageMeta: {
    executive:  { title: 'Executive Overview',   subtitle: 'Platform health at a glance' },
    product:    { title: 'Product Intelligence',  subtitle: 'Feature adoption and engagement' },
    ai:         { title: 'AI Platform',           subtitle: 'Provider performance and cost efficiency' },
    users:      { title: 'Users',                 subtitle: 'User management' },
    userDetail: { title: 'User Detail',           subtitle: '' },
    workspaces: { title: 'Workspaces',            subtitle: 'Session mode and language analytics' },
    quality:    { title: 'Quality & Reliability', subtitle: 'Error analysis and latency' },
    cost:       { title: 'Cost Intelligence',     subtitle: 'AI spending and optimization' },
    settings:   { title: 'Settings',              subtitle: 'Configuration and invites' },
    feedback:   { title: 'Feedback',              subtitle: 'User satisfaction' },
  },

  /* ── Global Filter Actions ── */

  setDatePreset(presetId, days) {
    this.filters = { preset: presetId, days, start: null, end: null };
    D.api.clearCache();
    document.querySelectorAll('.d-global-filter-bar [data-preset]').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.preset === presetId);
    });
    this.refreshPage();
  },

  refreshPage() {
    D.api.clearCache();
    if (this.currentPage && this.pages[this.currentPage]?.render) {
      this.pages[this.currentPage].render();
    }
  },

  exportPage() {
    const page = this.pages[this.currentPage];
    if (page && page._lastData) {
      D.drillDown.exportData(page._lastData, `decode-${this.currentPage}-${new Date().toISOString().slice(0,10)}.json`);
    }
  },

  toggleSearch() {
    const modal = document.getElementById('d-search-modal');
    if (!modal) return;
    const isOpen = modal.classList.contains('open');
    if (isOpen) {
      modal.classList.remove('open');
    } else {
      modal.classList.add('open');
      const input = modal.querySelector('.d-search-input');
      if (input) { input.value = ''; input.focus(); }
      const results = modal.querySelector('.d-search-results');
      if (results) results.innerHTML = '<div class="d-search-hint">Type to search users, requests, events...</div>';
    }
  },

  async performSearch(query) {
    const resultsEl = document.querySelector('#d-search-modal .d-search-results');
    if (!resultsEl) return;
    if (!query || query.length < 1) {
      resultsEl.innerHTML = '<div class="d-search-hint">Type to search users, requests, events...</div>';
      return;
    }
    resultsEl.innerHTML = '<div class="d-search-hint">Searching...</div>';
    try {
      const data = await D.api.fetch(D.api.url('/api/v2/analytics/search', { q: query, limit: 20 }), { noCache: true, retries: 0 });
      if (!data.results || data.results.length === 0) {
        resultsEl.innerHTML = '<div class="d-search-hint">No results found</div>';
        return;
      }
      resultsEl.innerHTML = data.results.map(r => {
        const icon = r.type === 'user' ? '&#x1F464;' : r.type === 'ai_request' ? '&#x26A1;' : '&#x1F4CB;';
        return `
          <div class="d-search-result" onclick="App._onSearchResult('${r.type}', '${D.fmt.escapeHtml(r.id)}')">
            <span class="d-search-result-icon">${icon}</span>
            <div class="d-search-result-text">
              <div class="d-search-result-title">${D.fmt.escapeHtml(r.title)}</div>
              <div class="d-search-result-sub">${D.fmt.escapeHtml(r.subtitle || '')}</div>
            </div>
            <span class="d-badge d-badge-neutral">${r.type}</span>
          </div>`;
      }).join('');
      if (data.has_more) {
        resultsEl.innerHTML += `<div class="d-search-hint" style="border-top:1px solid var(--d-border);padding-top:8px">More results available — refine your query</div>`;
      }
    } catch (e) {
      resultsEl.innerHTML = `<div class="d-search-hint" style="color:var(--d-danger)">Search failed: ${e.message}</div>`;
    }
  },

  _onSearchResult(type, id) {
    this.toggleSearch();
    if (type === 'user') {
      this.navigateToUser(id);
    }
  },

  /* ── Keyboard Shortcuts ── */

  _initKeyboardShortcuts() {
    document.addEventListener('keydown', e => {
      const tag = e.target.tagName;
      const isInput = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';

      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        this.toggleSearch();
        return;
      }
      if (e.key === 'Escape') {
        D.drillDown.close();
        const searchModal = document.getElementById('d-search-modal');
        if (searchModal?.classList.contains('open')) this.toggleSearch();
        return;
      }
      if (isInput) return;
      if (e.key === 'r' || e.key === 'R') { e.preventDefault(); this.refreshPage(); return; }
      if (e.key === '1') { this.setDatePreset('today', 1); return; }
      if (e.key === '2') { this.setDatePreset('7d', 7); return; }
      if (e.key === '3') { this.setDatePreset('30d', 30); return; }
      if (e.key === '4') { this.setDatePreset('90d', 90); return; }
    });
  },
};


/* ══════════════════════════════════════════════════════════
   EXECUTIVE OVERVIEW
   ══════════════════════════════════════════════════════════ */

App.pages.executive = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-executive');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Key Metrics')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.sectionHeader('Trends')}${D.chartLoading(2, 2)}</div>`;

    try {
      const [exec, cost, timeline, founder] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
        D.api.fetch(D.api.url('/api/v2/analytics/cost')),
        D.api.fetch(D.api.url('/api/v2/analytics/timeline', { limit: 12 })),
        D.api.fetch('/api/admin/analytics/founder').catch(() => null),
      ]);
      this._lastData = { exec, cost, timeline, founder };
      this._renderLive(el, exec, cost, timeline, founder);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load executive data', err.message, "App.pages.executive.render()")}`;
    }
  },

  _renderLive(el, exec, cost, timeline, founder) {
    const dailyRequests = exec.daily_trend?.map(d => d.requests) || [];
    const dailyUsers = exec.daily_trend?.map(d => d.users) || [];
    const dailyLabels = exec.daily_trend?.map(d => D.fmt.dateShort(d.date)) || [];
    const dailyCost = cost.daily_trend?.map(d => d.cost_usd) || [];
    const dailyCostLabels = cost.daily_trend?.map(d => D.fmt.dateShort(d.date)) || [];
    const costPerReq = exec.total_requests > 0 && cost.total_cost_usd > 0
      ? cost.total_cost_usd / exec.total_requests : null;

    const timelineEvents = (timeline.events || []).slice(0, 10).map(e => {
      let type = 'info';
      if (e.type === 'error') type = 'danger';
      else if (e.type === 'user_activation') type = 'success';
      else if (e.type === 'daily_summary') type = 'brand';
      return {
        type,
        time: D.fmt.timeAgo(e.timestamp),
        text: e.title,
        meta: e.detail?.cost_usd != null ? `Cost: ${D.fmt.usd(e.detail.cost_usd)}` :
              e.detail?.provider ? e.detail.provider : '',
      };
    });

    const sourceHtml = exec._source === 'legacy'
      ? `<span class="d-badge d-badge-warning" style="margin-left:8px">Legacy data</span>` : '';

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Key Metrics', sourceHtml)}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Requests', value: D.fmt.num(exec.total_requests),
          sub: `${D.fmt.dateShort(exec.period?.start)} — ${D.fmt.dateShort(exec.period?.end)}`,
          accent: 'brand', sparkData: dailyRequests }),
        D.kpi({ label: 'Active Users', value: D.fmt.num(exec.unique_users),
          sub: 'Unique users in period', accent: 'info', sparkData: dailyUsers }),
        D.kpi({ label: 'Success Rate', value: D.fmt.pct(exec.success_rate),
          sub: exec.failed_requests > 0 ? `${D.fmt.num(exec.failed_requests)} failed` : 'All requests succeeded',
          accent: exec.success_rate >= 95 ? 'success' : exec.success_rate >= 80 ? 'warning' : 'danger' }),
        D.kpi({ label: 'Total Cost', value: D.fmt.usdCompact(cost.total_cost_usd),
          sub: costPerReq ? `${D.fmt.usd(costPerReq, 4)}/request` : 'No cost data',
          accent: 'warning', sparkData: dailyCost }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests per Day', canvasId: 'exec-chart-requests', height: 220 }),
          D.chartCard({ title: 'Cost per Day', canvasId: 'exec-chart-cost', height: 220 }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Recent Activity', `<span class="d-text-dim" style="font-size:11px">${D.fmt.num(timeline.events?.length || 0)} events</span>`)}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          ${timelineEvents.length ? D.timeline(timelineEvents) : '<div style="text-align:center;color:var(--d-text-3);padding:24px">No recent activity</div>'}
        </div>
      </div>

      ${founder ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Activation Funnel')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars([
              { label: 'Invites Generated', value: founder.activation_funnel.invites_generated, color: '#6b7280' },
              { label: 'Activated (' + D.fmt.pct(founder.activation_funnel.activated_pct) + ')', value: founder.activation_funnel.activated, color: '#3b82f6' },
              { label: 'First Request (' + D.fmt.pct(founder.activation_funnel.first_request_pct) + ')', value: founder.activation_funnel.made_first_request, color: '#10b981' },
              { label: 'Active 7d (' + D.fmt.pct(founder.activation_funnel.active_7d_pct) + ')', value: founder.activation_funnel.active_after_7d, color: '#8b5cf6' },
              { label: 'Active 30d (' + D.fmt.pct(founder.activation_funnel.active_30d_pct) + ')', value: founder.activation_funnel.active_after_30d, color: '#e87830' },
            ])}
          </div>

          <div class="d-mt-4">
            ${D.kpiGrid([
              D.kpi({ label: 'Avg Time to First Value', value: founder.time_to_first_value.average_seconds != null ? D.fmt.latency(founder.time_to_first_value.average_seconds * 1000) : '\u2014', sub: D.fmt.num(founder.time_to_first_value.sample_size) + ' users sampled', accent: 'brand' }),
              D.kpi({ label: 'Median TTFV', value: founder.time_to_first_value.median_seconds != null ? D.fmt.latency(founder.time_to_first_value.median_seconds * 1000) : '\u2014', accent: 'info' }),
              D.kpi({ label: 'Cost / User (7d)', value: founder.cost_per_active_user.last_7d != null ? D.fmt.usd(founder.cost_per_active_user.last_7d) : '\u2014', sub: D.fmt.num(founder.cost_per_active_user.active_users_7d) + ' active', accent: 'warning' }),
              D.kpi({ label: 'Cost / User (All)', value: founder.cost_per_active_user.all_time != null ? D.fmt.usd(founder.cost_per_active_user.all_time) : '\u2014', sub: D.fmt.num(founder.cost_per_active_user.active_users_all_time) + ' total', accent: 'success' }),
            ], 4)}
          </div>
        </div>
      ` : ''}
    `;

    requestAnimationFrame(() => {
      D.renderAreaChart('exec-chart-requests', dailyRequests, {
        labels: dailyLabels, height: 220, color: '#e87830',
        yFormat: v => D.fmt.num(Math.round(v)), seriesName: 'Requests',
      });
      D.renderAreaChart('exec-chart-cost', dailyCost, {
        labels: dailyCostLabels, height: 220, color: '#f59e0b',
        yFormat: v => D.fmt.usdCompact(v), seriesName: 'Cost',
      });
      D.renderSparklines(el);
    });
  },
};


/* ══════════════════════════════════════════════════════════
   PRODUCT INTELLIGENCE
   ══════════════════════════════════════════════════════════ */

App.pages.product = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-product');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Feature Adoption')}
      ${D.kpiLoading(4, 4)}`;

    try {
      const [product, exec, history, improve] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/product')),
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
        D.api.fetch(D.api.url('/api/v2/analytics/history')),
        D.api.fetch(D.api.url('/api/v2/analytics/improve')),
      ]);
      this._lastData = { product, exec, history, improve };
      this._renderLive(el, product, exec, history, improve);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load product data', err.message, "App.pages.product.render()")}`;
    }
  },

  _renderLive(el, product, exec, history, improve) {
    const modes = product.by_mode || [];
    const types = product.by_request_type || [];

    const modeMap = {};
    modes.forEach(m => modeMap[m.mode] = m);
    const sel = modeMap['selection'] || { count: 0, users: 0 };
    const ses = modeMap['session'] || { count: 0, users: 0 };
    const scr = modeMap['screenshot'] || { count: 0, users: 0 };

    const typeMap = {};
    types.forEach(t => typeMap[t.request_type] = t);
    const explains = (typeMap['explain'] || { count: 0 }).count;
    const followups = (typeMap['followup'] || { count: 0 }).count;
    const followupRate = explains > 0 ? (followups / explains * 100) : 0;

    const modeSegments = modes.filter(m => m.count > 0).map(m => ({
      label: D.label(m.mode), value: m.count, color: D.featureColor(m.mode),
    }));

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Feature Adoption')}
      ${D.kpiGrid([
        D.kpi({ label: 'Selection Mode', value: D.fmt.num(sel.count), sub: `${D.fmt.num(sel.users)} users`, accent: 'brand' }),
        D.kpi({ label: 'Session Mode', value: D.fmt.num(ses.count), sub: `${D.fmt.num(ses.users)} users`, accent: 'info' }),
        D.kpi({ label: 'Follow-up Rate', value: D.fmt.pct(followupRate), sub: `${D.fmt.num(followups)} follow-ups on ${D.fmt.num(explains)} explanations`, accent: followupRate > 20 ? 'success' : 'warning' }),
        D.kpi({ label: 'Active Users', value: D.fmt.num(exec.unique_users), sub: 'Across all modes', accent: 'purple' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Usage by Mode')}
        ${D.chartGrid([
          D.chartCard({ title: 'Request Distribution', canvasId: 'product-donut-mode', height: 260, placeholder: false }),
          `<div class="d-chart-card" style="padding:var(--d-sp-5)">
            <h4 style="margin:0 0 16px;font-size:0.85rem;font-weight:600">Mode Breakdown</h4>
            ${D.horizontalBars(modes.filter(m => m.count > 0).map(m => ({
              label: D.label(m.mode), value: m.count, color: D.featureColor(m.mode),
            })))}
          </div>`,
        ], 2)}
      </div>

      ${(improve && improve.total_outcomes > 0) ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Improve Code')}
          ${D.kpiGrid([
            D.kpi({ label: 'Improve Requests', value: D.fmt.num(improve.improve_requests), sub: improve.adoption_rate !== null ? D.fmt.pct(improve.adoption_rate) + ' adoption' : '', accent: 'brand' }),
            D.kpi({ label: 'Acceptance Rate', value: improve.acceptance_rate !== null ? D.fmt.pct(improve.acceptance_rate) : '\u2014', sub: D.fmt.num(improve.copy_count + improve.replace_count) + ' accepted', accent: 'success' }),
            D.kpi({ label: 'No Change Rate', value: improve.no_change_rate !== null ? D.fmt.pct(improve.no_change_rate) : '\u2014', sub: 'Code already clean', accent: 'info' }),
            D.kpi({ label: 'Improve Users', value: D.fmt.num(improve.improve_users), accent: 'purple' }),
          ], 4)}

          <div class="d-mt-4">
            <div class="d-chart-card" style="padding:var(--d-sp-5)">
              <h4 style="margin:0 0 12px;font-size:0.85rem;font-weight:600">Outcome Distribution</h4>
              ${D.horizontalBars([
                { label: 'Copy', value: improve.copy_count, color: '#10b981' },
                { label: 'Replace', value: improve.replace_count, color: '#3b82f6' },
                { label: 'Dismiss', value: improve.dismiss_count, color: '#f59e0b' },
                { label: 'No Change', value: improve.no_change_count, color: '#6b7280' },
              ].filter(b => b.value > 0))}
            </div>
          </div>

          ${(improve.daily_trend || []).length > 0 ? `
            <div class="d-mt-4">
              ${D.chartCard({ title: 'Improve Outcome Trend', canvasId: 'improve-trend-chart', height: 200, placeholder: false })}
            </div>
          ` : ''}
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('History Analytics')}
        ${(history && (history.history_opens > 0 || history.history_followups > 0 || history.history_clears > 0)) ? `
          ${D.kpiGrid([
            D.kpi({ label: 'History Users', value: D.fmt.num(history.history_users), sub: history.adoption !== null ? D.fmt.pct(history.adoption) + ' adoption' : 'No active users', accent: 'brand' }),
            D.kpi({ label: 'History Opens', value: D.fmt.num(history.history_opens), accent: 'info' }),
            D.kpi({ label: 'History Follow-Ups', value: D.fmt.num(history.history_followups), sub: history.followup_rate !== null ? D.fmt.pct(history.followup_rate) + ' rate' : '', accent: 'success' }),
            D.kpi({ label: 'History Clears', value: D.fmt.num(history.history_clears), accent: 'warning' }),
          ], 4)}

          ${(history.daily_trend || []).length > 0 ? `
            <div class="d-mt-4">
              ${D.chartCard({ title: 'History Usage Trend', canvasId: 'history-trend-chart', height: 200, placeholder: false })}
            </div>
          ` : ''}
        ` : `
          <div class="d-chart-card" style="padding:var(--d-sp-8);text-align:center">
            <div style="font-size:2rem;margin-bottom:8px">&#x1F4DA;</div>
            <div style="font-weight:600;margin-bottom:4px">No history activity yet</div>
            <div style="color:var(--d-text-3);font-size:0.85rem">History analytics will appear here once users start using the History feature.</div>
          </div>
        `}
      </div>
    `;

    requestAnimationFrame(() => {
      const modeTotal = modeSegments.reduce((s, x) => s + x.value, 0);
      const modeCanvas = document.getElementById('product-donut-mode');
      if (modeCanvas && modeSegments.length) {
        const body = modeCanvas.closest('.d-chart-body');
        body.innerHTML = `<div class="d-donut-wrap"><canvas id="product-donut-mode" style="width:180px;height:180px"></canvas>${D.donutLegend(modeSegments, modeTotal)}</div>`;
        D.renderDonutChart('product-donut-mode', modeSegments, { height: 180, centerLabel: D.fmt.num(modeTotal), centerSub: 'requests' });
      }

      const improveTrendCanvas = document.getElementById('improve-trend-chart');
      if (improveTrendCanvas && improve && (improve.daily_trend || []).length > 0) {
        const trend = improve.daily_trend;
        const body = improveTrendCanvas.closest('.d-chart-body');
        body.innerHTML = `<canvas id="improve-trend-chart" style="width:100%;height:200px"></canvas>`;
        D.renderAreaChart('improve-trend-chart',
          trend.map(d => (d.copies || 0) + (d.replaces || 0) + (d.dismissals || 0) + (d.no_changes || 0)),
          { labels: trend.map(d => D.fmt.dateShort(d.date)), height: 200, color: '#10b981', yFormat: v => D.fmt.num(Math.round(v)), seriesName: 'Improve Actions' }
        );
      }

      const historyTrendCanvas = document.getElementById('history-trend-chart');
      if (historyTrendCanvas && history && (history.daily_trend || []).length > 0) {
        const trend = history.daily_trend;
        const body = historyTrendCanvas.closest('.d-chart-body');
        body.innerHTML = `<canvas id="history-trend-chart" style="width:100%;height:200px"></canvas>`;
        D.renderAreaChart('history-trend-chart',
          trend.map(d => (d.opens || 0) + (d.followups || 0) + (d.clears || 0)),
          { labels: trend.map(d => D.fmt.dateShort(d.date)), height: 200, color: '#e87830', yFormat: v => D.fmt.num(Math.round(v)), seriesName: 'History Events' }
        );
      }
    });
  },
};


/* ══════════════════════════════════════════════════════════
   AI PLATFORM
   ══════════════════════════════════════════════════════════ */

App.pages.ai = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-ai');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Platform Health')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.sectionHeader('Cost by Feature')}${D.tableLoading(6)}</div>`;

    try {
      const [ai, quality, tokens] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/ai-platform')),
        D.api.fetch(D.api.url('/api/v2/analytics/quality')),
        D.api.fetch(D.api.url('/api/v2/analytics/token-breakdown')),
      ]);
      this._lastData = { ai, quality, tokens };
      this._renderLive(el, ai, quality, tokens);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load AI platform data', err.message, "App.pages.ai.render()")}`;
    }
  },

  _renderLive(el, ai, quality, tokens) {
    const providers = ai.by_provider || [];
    const models = ai.by_model || [];
    const lat = quality.latency || {};
    const byFeature = tokens.by_feature || [];
    const byMode = tokens.by_mode || [];
    const byType = tokens.by_request_type || [];
    const tokenDaily = tokens.daily_trend || [];
    const topUsers = tokens.top_users || [];

    const totalReqs = providers.reduce((s, p) => s + p.count, 0);
    const totalSuccess = providers.reduce((s, p) => s + p.successful, 0);
    const successRate = totalReqs > 0 ? (totalSuccess / totalReqs * 100) : 0;
    const totalCost = byFeature.reduce((s, f) => s + (f.total_cost_usd || 0), 0);
    const totalPrompt = byFeature.reduce((s, f) => s + (f.prompt_tokens || 0), 0);
    const totalCompletion = byFeature.reduce((s, f) => s + (f.completion_tokens || 0), 0);
    const totalTokens = totalPrompt + totalCompletion;

    // Forecast
    const numDays = tokenDaily.length || 1;
    const avgDailyCost = totalCost / numDays;
    const estMonthlyCost = avgDailyCost * 30;
    const costPer100 = totalReqs > 0 ? (totalCost / totalReqs) * 100 : 0;
    const avgTokensPerReq = totalReqs > 0 ? totalTokens / totalReqs : 0;

    const tdLabels = tokenDaily.map(d => D.fmt.dateShort(d.date));
    const tdCost = tokenDaily.map(d => d.cost_usd);

    const provColors = p => {
      if (p.includes('anthropic')) return '#e87830';
      if (p.includes('groq')) return '#3b82f6';
      if (p.includes('openai')) return '#10b981';
      return '#8b5cf6';
    };

    const provSegments = providers.map(p => ({ label: p.provider, value: p.count, color: provColors(p.provider) }));

    // Feature cost donut
    const featureCostSegs = byFeature.filter(f => f.total_cost_usd > 0).map(f => ({
      label: D.label(f.key), value: f.total_cost_usd, color: D.featureColor(f.key),
    }));

    // Token overview stats
    const avgPromptPerReq = totalReqs > 0 ? Math.round(totalPrompt / totalReqs) : 0;
    const avgCompletionPerReq = totalReqs > 0 ? Math.round(totalCompletion / totalReqs) : 0;
    const avgTotalPerReq = totalReqs > 0 ? Math.round(totalTokens / totalReqs) : 0;

    // Sort by-mode and by-feature/type for tables
    const sortedByMode = byMode.slice().sort((a, b) => (b.total_tokens || 0) - (a.total_tokens || 0));
    const sortedByFeature = byFeature.slice().sort((a, b) => (b.total_tokens || 0) - (a.total_tokens || 0));

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Platform Health')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total AI Requests', value: D.fmt.num(totalReqs), accent: 'brand' }),
        D.kpi({ label: 'Success Rate', value: D.fmt.pct(successRate), accent: successRate >= 95 ? 'success' : 'warning' }),
        D.kpi({ label: 'p95 Latency', value: D.fmt.latency(lat.p95_ms), sub: 'p50: ' + D.fmt.latency(lat.p50_ms), accent: lat.p95_ms > 5000 ? 'danger' : 'warning' }),
        D.kpi({ label: 'Total AI Cost', value: D.fmt.usdCompact(totalCost), sub: totalReqs > 0 ? D.fmt.usd(totalCost / totalReqs, 4) + '/request' : '', accent: 'warning' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Cost by Feature', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._exportTokens()">Export</button>`)}
        ${D.chartGrid([
          D.chartCard({ title: 'Cost Distribution', canvasId: 'ai-donut-feature-cost', height: 260, placeholder: false }),
          `<div class="d-chart-card">${byFeature.length > 0 ? D.table({
            headers: [
              'Feature',
              { label: 'Requests', align: 'right' },
              { label: 'Cost', align: 'right' },
              { label: 'Avg Cost', align: 'right' },
              { label: '% of Spend', align: 'right' },
            ],
            rows: byFeature.filter(f => f.total_cost_usd > 0).sort((a, b) => b.total_cost_usd - a.total_cost_usd).map(f => ({
              clickable: true,
              onclick: `App.pages.ai._drillDownFeature('${D.fmt.escapeHtml(f.key)}')`,
              cells: [
                `<strong style="color:${D.featureColor(f.key)}">${D.label(f.key)}</strong>`,
                D.fmt.num(f.requests),
                D.fmt.usd(f.total_cost_usd),
                D.fmt.usd(f.avg_cost_usd, 4),
                D.fmt.pct(totalCost > 0 ? (f.total_cost_usd / totalCost * 100) : 0),
              ],
            })),
            emptyText: 'No cost data',
          }) : D.empty(null, 'No cost data')}</div>`,
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Usage')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <table style="width:100%;border-collapse:collapse;font-size:0.85rem">
            <thead>
              <tr style="border-bottom:1px solid var(--d-border)">
                <th style="text-align:left;padding:6px 12px;color:var(--d-text-3);font-weight:500"></th>
                <th style="text-align:right;padding:6px 12px;color:var(--d-text-3);font-weight:500">Total</th>
                <th style="text-align:right;padding:6px 12px;color:var(--d-text-3);font-weight:500">Avg / Request</th>
              </tr>
            </thead>
            <tbody>
              <tr><td style="padding:8px 12px;font-weight:600">Input Tokens</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalPrompt)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgPromptPerReq)}</td></tr>
              <tr><td style="padding:8px 12px;font-weight:600">Output Tokens</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalCompletion)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgCompletionPerReq)}</td></tr>
              <tr style="border-top:1px solid var(--d-border);font-weight:700"><td style="padding:8px 12px">Total</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalTokens)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgTotalPerReq)}</td></tr>
            </tbody>
          </table>
          <div style="margin-top:8px;padding:4px 12px;color:var(--d-text-4);font-size:0.78rem">AI Requests: ${D.fmt.num(totalReqs)} &middot; Est. Cost: ${D.fmt.usdCompact(totalCost)}</div>
        </div>
      </div>

      ${sortedByMode.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Usage by Mode', `<span class="d-text-dim" style="font-size:11px">User-facing surface that generated the usage</span>`)}
          <div class="d-chart-card">${D.table({
            headers: [
              'Mode',
              { label: 'Requests', align: 'right' },
              { label: 'Input', align: 'right' },
              { label: 'Output', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Avg / Req', align: 'right' },
              { label: 'Cost', align: 'right' },
            ],
            rows: sortedByMode.map(m => ({
              cells: [
                `<strong style="color:${D.featureColor(m.key)}">${D.label(m.key)}</strong>`,
                D.fmt.num(m.requests),
                D.fmt.num(m.prompt_tokens),
                D.fmt.num(m.completion_tokens),
                D.fmt.num(m.total_tokens),
                D.fmt.num(m.avg_total_tokens),
                D.fmt.usd(m.total_cost_usd),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      ${sortedByFeature.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Usage by Feature', `<span class="d-text-dim" style="font-size:11px">AI operation that was performed</span>`)}
          <div class="d-chart-card">${D.table({
            headers: [
              'Feature',
              { label: 'Requests', align: 'right' },
              { label: 'Input', align: 'right' },
              { label: 'Output', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Avg / Req', align: 'right' },
              { label: 'Cost', align: 'right' },
            ],
            rows: sortedByFeature.map(f => ({
              clickable: true,
              onclick: `App.pages.ai._drillDownFeature('${D.fmt.escapeHtml(f.key)}')`,
              cells: [
                `<strong style="color:${D.featureColor(f.key)}">${D.label(f.key)}</strong>`,
                D.fmt.num(f.requests),
                D.fmt.num(f.prompt_tokens),
                D.fmt.num(f.completion_tokens),
                D.fmt.num(f.total_tokens),
                D.fmt.num(f.avg_total_tokens),
                D.fmt.usd(f.total_cost_usd),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      ${tdLabels.length > 1 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Daily AI Cost')}
          ${D.chartCard({ title: 'Token Cost Trend', canvasId: 'ai-trend-cost', height: 220 })}
        </div>
      ` : ''}

      ${providers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Providers')}
          ${D.chartGrid([
            D.chartCard({ title: 'Requests by Provider', canvasId: 'ai-donut-provider', height: 260, placeholder: false }),
            `<div class="d-chart-card">${D.table({
              headers: [
                'Provider',
                { label: 'Requests', align: 'right' },
                { label: 'Success', align: 'right' },
                { label: 'Latency', align: 'right' },
                { label: 'Cost', align: 'right' },
              ],
              rows: providers.map(p => ({
                cells: [
                  `<strong style="color:${provColors(p.provider)}">${D.fmt.escapeHtml(p.provider)}</strong>`,
                  D.fmt.num(p.count),
                  D.badge(D.fmt.pct(p.success_rate), p.success_rate >= 95 ? 'success' : 'warning'),
                  D.fmt.latency(p.avg_latency_ms),
                  D.fmt.usd(p.total_cost_usd),
                ],
              })),
            })}</div>`,
          ], 2)}
        </div>
      ` : ''}

      ${models.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Models')}
          ${D.table({
            headers: [
              'Model',
              'Provider',
              { label: 'Requests', align: 'right' },
              { label: 'Success', align: 'right' },
              { label: 'Latency', align: 'right' },
              { label: 'Cost', align: 'right' },
            ],
            rows: models.map(m => ({
              clickable: true,
              onclick: `App.pages.ai._drillDownModel('${D.fmt.escapeHtml(m.model)}')`,
              cells: [
                `<span class="d-text-mono">${D.fmt.escapeHtml(m.model)}</span>`,
                D.fmt.escapeHtml(m.provider),
                D.fmt.num(m.count),
                D.badge(D.fmt.pct(m.success_rate), m.success_rate >= 95 ? 'success' : 'danger'),
                D.fmt.latency(m.avg_latency_ms),
                D.fmt.usd(m.total_cost_usd),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${topUsers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Top Consumers')}
          ${D.table({
            headers: [
              'User',
              { label: 'Requests', align: 'right' },
              { label: 'Input', align: 'right' },
              { label: 'Output', align: 'right' },
              { label: 'Total Tokens', align: 'right' },
              { label: 'Cost', align: 'right' },
            ],
            rows: topUsers.slice(0, 8).map(u => ({
              clickable: true,
              onclick: `App.navigateToUser('${u.user_id}')`,
              cells: [
                `<strong>${D.fmt.escapeHtml(u.name || u.email || u.user_id.substring(0, 8))}</strong>`,
                D.fmt.num(u.requests),
                D.fmt.num(u.prompt_tokens),
                D.fmt.num(u.completion_tokens),
                D.fmt.num(u.total_tokens),
                D.fmt.usd(u.cost_usd),
              ],
            })),
          })}
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Forecast', `<span class="d-text-dim" style="font-size:11px">Based on ${D.fmt.num(numDays)}-day average</span>`)}
        ${D.kpiGrid([
          D.kpi({ label: 'Est. Monthly Cost', value: D.fmt.usdCompact(estMonthlyCost), sub: D.fmt.usd(avgDailyCost) + '/day', accent: 'danger' }),
          D.kpi({ label: 'Cost / 100 Requests', value: D.fmt.usd(costPer100), accent: 'warning' }),
          D.kpi({ label: 'Avg Tokens / Request', value: D.fmt.num(Math.round(avgTokensPerReq)), accent: 'purple' }),
          D.kpi({ label: 'Avg Daily Cost', value: D.fmt.usd(avgDailyCost), accent: 'info' }),
        ], 4)}
      </div>
    `;

    requestAnimationFrame(() => {
      // Feature cost donut
      if (featureCostSegs.length) {
        const fcCanvas = document.getElementById('ai-donut-feature-cost');
        if (fcCanvas) {
          const body = fcCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-feature-cost" style="width:180px;height:180px"></canvas>${D.donutLegend(featureCostSegs, totalCost)}</div>`;
          D.renderDonutChart('ai-donut-feature-cost', featureCostSegs, { height: 180, centerLabel: D.fmt.usdCompact(totalCost), centerSub: 'total' });
        }
      }
      // Cost trend
      if (tdLabels.length > 1) {
        D.renderAreaChart('ai-trend-cost', tdCost, {
          labels: tdLabels, height: 220, color: '#f59e0b',
          yFormat: v => D.fmt.usdCompact(v), seriesName: 'Cost',
        });
      }
      // Provider donut
      const provTotal = provSegments.reduce((s, x) => s + x.value, 0);
      const pCanvas = document.getElementById('ai-donut-provider');
      if (pCanvas && provSegments.length) {
        const body = pCanvas.closest('.d-chart-body');
        body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-provider" style="width:180px;height:180px"></canvas>${D.donutLegend(provSegments, provTotal)}</div>`;
        D.renderDonutChart('ai-donut-provider', provSegments, { height: 180, centerLabel: D.fmt.num(provTotal), centerSub: 'requests' });
      }
    });
  },

  _exportTokens() {
    if (!this._lastData?.tokens) return;
    D.drillDown.exportData(this._lastData.tokens, 'token-breakdown.json');
  },

  _drillDownFeature(featureKey) {
    if (!this._lastData?.tokens) return;
    const f = (this._lastData.tokens.by_feature || []).find(x => x.key === featureKey);
    if (!f) return;
    const label = D.label(featureKey);
    const ratio = f.avg_prompt_tokens > 0 ? (f.avg_completion_tokens / f.avg_prompt_tokens).toFixed(2) : '\u2014';
    const fpRows = (this._lastData.tokens.feature_by_provider || []).filter(r => r.feature === featureKey);
    const fmRows = (this._lastData.tokens.feature_by_model || []).filter(r => r.feature === featureKey);
    D.drillDown.open(`Feature: ${label}`, `
      ${D.statRow([
        { label: 'Requests', value: D.fmt.num(f.requests) },
        { label: 'Success Rate', value: D.fmt.pct(f.success_rate), color: f.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
        { label: 'Avg Latency', value: D.fmt.latency(f.avg_latency_ms) },
      ])}
      ${D.statRow([
        { label: 'Input Tokens', value: D.fmt.num(f.prompt_tokens) },
        { label: 'Output Tokens', value: D.fmt.num(f.completion_tokens) },
        { label: 'Out/In Ratio', value: ratio + 'x' },
      ])}
      ${D.statRow([
        { label: 'Total Cost', value: D.fmt.usd(f.total_cost_usd) },
        { label: 'Avg Cost/Req', value: D.fmt.usd(f.avg_cost_usd, 4) },
      ])}
      ${fpRows.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('Provider Breakdown')}
          ${D.table({
            headers: ['Provider', { label: 'Requests', align: 'right' }, { label: 'Cost', align: 'right' }, { label: 'Latency', align: 'right' }],
            rows: fpRows.map(r => ({ cells: [
              `<strong>${D.fmt.escapeHtml(r.provider)}</strong>`,
              D.fmt.num(r.requests), D.fmt.usd(r.cost_usd), D.fmt.latency(r.avg_latency_ms),
            ]})),
          })}
        </div>
      ` : ''}
      ${fmRows.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('Model Breakdown')}
          ${D.table({
            headers: ['Model', { label: 'Requests', align: 'right' }, { label: 'Cost', align: 'right' }, { label: 'Latency', align: 'right' }],
            rows: fmRows.map(r => ({ cells: [
              `<span class="d-text-mono">${D.fmt.escapeHtml(r.model)}</span>`,
              D.fmt.num(r.requests), D.fmt.usd(r.cost_usd), D.fmt.latency(r.avg_latency_ms),
            ]})),
          })}
        </div>
      ` : ''}
      <div class="d-mt-6">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify({feature: f, providers: fpRows, models: fmRows}))}')), '${featureKey}.json')">Export JSON</button>
      </div>
    `);
  },

  _drillDownModel(model) {
    if (!this._lastData) return;
    const m = this._lastData.ai.by_model?.find(x => x.model === model);
    if (!m) return;
    D.drillDown.open(`Model: ${model}`, `
      ${D.statRow([
        { label: 'Requests', value: D.fmt.num(m.count) },
        { label: 'Success', value: D.fmt.pct(m.success_rate), color: m.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
        { label: 'Latency', value: D.fmt.latency(m.avg_latency_ms) },
        { label: 'Cost', value: D.fmt.usd(m.total_cost_usd) },
      ])}
      <div class="d-mt-6">
        ${D.sectionHeader('Token Usage')}
        ${D.statRow([
          { label: 'Input', value: D.fmt.num(m.prompt_tokens) },
          { label: 'Output', value: D.fmt.num(m.completion_tokens) },
          { label: 'Total', value: D.fmt.num(m.prompt_tokens + m.completion_tokens) },
        ])}
      </div>
    `);
  },
};


/* ══════════════════════════════════════════════════════════
   USERS
   ══════════════════════════════════════════════════════════ */

App.pages.users = {
  _lastData: null,
  _page: 0,
  _limit: 25,

  async render() {
    const el = document.getElementById('page-users');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Users')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.tableLoading(6, 5)}</div>`;

    try {
      const [users, settings] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/users', { limit: this._limit, offset: this._page * this._limit })),
        D.api.fetch('/api/v2/analytics/settings'),
      ]);
      this._lastData = { users, settings };
      this._renderLive(el, users, settings);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load user data', err.message, "App.pages.users.render()")}`;
    }
  },

  _renderLive(el, users, settings) {
    const userList = users.users || [];
    const totalCount = users.total_count || 0;
    const totalUsers = settings.users?.total || 0;
    const activeUsers = settings.users?.active || 0;

    const avatarColors = ['#e87830', '#3b82f6', '#10b981', '#8b5cf6', '#f59e0b', '#ef4444', '#06b6d4', '#ec4899'];

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('User Overview')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Users', value: D.fmt.num(totalUsers), accent: 'brand' }),
        D.kpi({ label: 'Active Users', value: D.fmt.num(activeUsers), accent: 'success' }),
        D.kpi({ label: 'Users in Period', value: D.fmt.num(totalCount), sub: 'With requests', accent: 'info' }),
        D.kpi({ label: 'Avg Req / User', value: totalCount > 0 ? D.fmt.num(Math.round(userList.reduce((s, u) => s + u.total_requests, 0) / userList.length)) : '\u2014' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('All Users', `
          <span class="d-text-dim" style="font-size:11px">${D.fmt.num(totalCount)} total</span>
          <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.users._exportUsers()">Export</button>
        `)}
        ${userList.length > 0 ? D.table({
          headers: [
            'User',
            { label: 'Requests', align: 'right' },
            { label: 'Success', align: 'right' },
            { label: 'Cost', align: 'right' },
            'Last Active',
          ],
          rows: userList.map((u, i) => ({
            clickable: true,
            onclick: `App.navigateToUser('${u.user_id}')`,
            cells: [
              `<div class="d-user-cell">
                <div class="d-avatar" style="background:${avatarColors[i % avatarColors.length]}">${D.fmt.initials(u.name, u.email)}</div>
                <div><div class="d-user-name">${D.fmt.escapeHtml(u.name || 'Unknown')}</div><div class="d-user-email">${D.fmt.escapeHtml(u.email || u.user_id.substring(0, 8))}</div></div>
              </div>`,
              D.fmt.num(u.total_requests),
              D.badge(D.fmt.pct(u.total_requests > 0 ? u.successful_requests / u.total_requests * 100 : 0), u.successful_requests === u.total_requests ? 'success' : 'warning'),
              D.fmt.usd(u.total_cost_usd),
              D.fmt.timeAgo(u.last_active),
            ],
          })),
        }) : D.empty(null, 'No users found', 'Adjust the date range to find users')}

        ${totalCount > this._limit ? `
          <div class="d-flex d-items-center d-justify-between" style="padding:12px 16px;border-top:1px solid var(--d-border)">
            <button class="d-btn d-btn-sm" ${this._page === 0 ? 'disabled' : ''} onclick="App.pages.users._page--;App.pages.users.render()">&#x2190; Previous</button>
            <span class="d-text-dim" style="font-size:12px">Page ${this._page + 1} of ${Math.ceil(totalCount / this._limit)}</span>
            <button class="d-btn d-btn-sm" ${(this._page + 1) * this._limit >= totalCount ? 'disabled' : ''} onclick="App.pages.users._page++;App.pages.users.render()">Next &#x2192;</button>
          </div>
        ` : ''}
      </div>
    `;
  },

  _exportUsers() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.users.users, 'users.csv', 'csv');
  },
};


/* ══════════════════════════════════════════════════════════
   USER DETAIL — Full Page
   ══════════════════════════════════════════════════════════ */

App.pages.userDetail = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-userDetail');
    const userId = App._userDetailId;
    if (!userId) { App.navigate('users'); return; }

    el.innerHTML = `
      <div style="margin-bottom:20px">
        <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.navigate('users')">&#x2190; Back to Users</button>
      </div>
      ${D.loading()}`;

    try {
      const detail = await D.api.fetch(D.api.url(`/api/v2/analytics/users/${userId}`, { recent_limit: 20 }));
      this._lastData = detail;
      this._renderLive(el, detail, userId);
    } catch (err) {
      el.innerHTML = `
        <div style="margin-bottom:20px">
          <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.navigate('users')">&#x2190; Back to Users</button>
        </div>
        ${D.error('Failed to load user', err.message, "App.pages.userDetail.render()")}`;
    }
  },

  _renderLive(el, detail, userId) {
    const u = detail.user || {};
    const recentReqs = detail.recent_requests || [];
    const dailyTrend = detail.daily_trend || [];
    const modeDetail = detail.mode_detail || [];

    // Update topbar with user name
    document.getElementById('d-topbar-title').textContent = u.name || u.email || 'User Detail';
    document.getElementById('d-topbar-subtitle').textContent = u.email || '';

    const statusColor = u.status === 'active' ? 'success' : u.status === 'disabled' ? 'danger' : 'warning';

    // Token totals from API (computed server-side from all mode_detail rows)
    const totalPrompt = detail.total_prompt_tokens || 0;
    const totalCompletion = detail.total_completion_tokens || 0;
    const totalTokens = detail.total_tokens || 0;
    const totalReqs = detail.total_requests || 0;
    const avgPrompt = totalReqs > 0 ? Math.round(totalPrompt / totalReqs) : 0;
    const avgCompletion = totalReqs > 0 ? Math.round(totalCompletion / totalReqs) : 0;
    const avgTotal = totalReqs > 0 ? Math.round(totalTokens / totalReqs) : 0;

    // Group mode_detail by origin_mode for "by mode" token table
    const modeTokenMap = {};
    modeDetail.forEach(m => {
      const modeKey = m.origin_mode || m.request_type || 'other';
      if (!modeTokenMap[modeKey]) {
        modeTokenMap[modeKey] = { requests: 0, prompt: 0, completion: 0, total: 0 };
      }
      modeTokenMap[modeKey].requests += m.total;
      modeTokenMap[modeKey].prompt += m.prompt_tokens || 0;
      modeTokenMap[modeKey].completion += m.completion_tokens || 0;
      modeTokenMap[modeKey].total += m.total_tokens || 0;
    });
    const modeTokenRows = Object.entries(modeTokenMap)
      .sort((a, b) => b[1].total - a[1].total)
      .map(([key, v]) => ({
        key,
        requests: v.requests,
        prompt: v.prompt,
        completion: v.completion,
        total: v.total,
        avg: v.requests > 0 ? Math.round(v.total / v.requests) : 0,
      }));

    // Feature-level (each mode_detail row is a unique origin_mode × request_type)
    const featureTokenRows = modeDetail
      .filter(m => (m.total_tokens || 0) > 0 || m.total > 0)
      .sort((a, b) => (b.total_tokens || 0) - (a.total_tokens || 0))
      .map(m => {
        // Derive a feature key for color/label from display_name or request_type
        const featureKey = m.origin_mode && m.request_type
          ? (m.request_type === 'explain' ? m.origin_mode : `${m.origin_mode}_${m.request_type}`)
          : m.request_type || 'other';
        return {
          label: m.display_name,
          key: featureKey,
          requests: m.total,
          prompt: m.prompt_tokens || 0,
          completion: m.completion_tokens || 0,
          total: m.total_tokens || 0,
          avg: m.total > 0 ? Math.round((m.total_tokens || 0) / m.total) : 0,
        };
      });

    el.innerHTML = `
      <div style="margin-bottom:24px">
        <button class="d-btn d-btn-sm d-btn-ghost" onclick="App.navigate('users')">&#x2190; Back to Users</button>
      </div>

      <div class="d-chart-card" style="padding:var(--d-sp-6);margin-bottom:24px">
        <div style="display:flex;align-items:center;gap:16px;margin-bottom:16px">
          <div class="d-avatar" style="width:48px;height:48px;font-size:18px;background:#e87830">${D.fmt.initials(u.name, u.email)}</div>
          <div>
            <div style="font-size:1.1rem;font-weight:700">${D.fmt.escapeHtml(u.name || 'Unknown User')}</div>
            <div style="color:var(--d-text-3);font-size:0.85rem">${D.fmt.escapeHtml(u.email || u.id || '')}</div>
          </div>
          <div style="margin-left:auto">${D.badge(u.status || 'unknown', statusColor)}</div>
        </div>

        ${D.kpiGrid([
          D.kpi({ label: 'Total Requests', value: D.fmt.num(detail.total_requests), accent: 'brand' }),
          D.kpi({ label: 'Success Rate', value: D.fmt.pct(detail.success_rate), accent: detail.success_rate >= 95 ? 'success' : 'danger' }),
          D.kpi({ label: 'Total Cost', value: D.fmt.usd(detail.total_cost_usd), accent: 'warning' }),
          D.kpi({ label: 'Last Active', value: detail.last_active ? D.fmt.timeAgo(detail.last_active) : '\u2014', accent: 'info' }),
        ], 4)}
      </div>

      ${dailyTrend.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Activity Trend')}
          ${D.chartCard({ title: 'Requests per Day', canvasId: 'user-detail-trend', height: 180 })}
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Usage', `<span class="d-text-dim" style="font-size:11px">All AI requests by this user</span>`)}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <table style="width:100%;border-collapse:collapse;font-size:0.85rem">
            <thead>
              <tr style="border-bottom:1px solid var(--d-border)">
                <th style="text-align:left;padding:6px 12px;color:var(--d-text-3);font-weight:500"></th>
                <th style="text-align:right;padding:6px 12px;color:var(--d-text-3);font-weight:500">Total</th>
                <th style="text-align:right;padding:6px 12px;color:var(--d-text-3);font-weight:500">Avg / Request</th>
              </tr>
            </thead>
            <tbody>
              <tr><td style="padding:8px 12px;font-weight:600">Input Tokens</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalPrompt)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgPrompt)}</td></tr>
              <tr><td style="padding:8px 12px;font-weight:600">Output Tokens</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalCompletion)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgCompletion)}</td></tr>
              <tr style="border-top:1px solid var(--d-border);font-weight:700"><td style="padding:8px 12px">Total</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(totalTokens)}</td><td style="text-align:right;padding:8px 12px;font-variant-numeric:tabular-nums">${D.fmt.num(avgTotal)}</td></tr>
            </tbody>
          </table>
          <div style="margin-top:8px;padding:4px 12px;color:var(--d-text-4);font-size:0.78rem">AI Requests: ${D.fmt.num(totalReqs)} &middot; Est. Cost: ${D.fmt.usd(detail.total_cost_usd)}</div>
        </div>
      </div>

      ${modeTokenRows.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Usage by Mode', `<span class="d-text-dim" style="font-size:11px">User-facing surface</span>`)}
          <div class="d-chart-card">${D.table({
            headers: [
              'Mode',
              { label: 'Requests', align: 'right' },
              { label: 'Input', align: 'right' },
              { label: 'Output', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Avg / Req', align: 'right' },
            ],
            rows: modeTokenRows.map(m => ({
              cells: [
                `<strong style="color:${D.featureColor(m.key)}">${D.label(m.key)}</strong>`,
                D.fmt.num(m.requests),
                D.fmt.num(m.prompt),
                D.fmt.num(m.completion),
                D.fmt.num(m.total),
                D.fmt.num(m.avg),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      ${featureTokenRows.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Usage by Feature', `<span class="d-text-dim" style="font-size:11px">AI operation performed</span>`)}
          <div class="d-chart-card">${D.table({
            headers: [
              'Feature',
              { label: 'Requests', align: 'right' },
              { label: 'Input', align: 'right' },
              { label: 'Output', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Avg / Req', align: 'right' },
            ],
            rows: featureTokenRows.map(f => ({
              cells: [
                `<strong style="color:${D.featureColor(f.key)}">${D.label(f.label)}</strong>`,
                D.fmt.num(f.requests),
                D.fmt.num(f.prompt),
                D.fmt.num(f.completion),
                D.fmt.num(f.total),
                D.fmt.num(f.avg),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      ${detail.improve_breakdown ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Improve Code')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.statRow([
              { label: 'Improve Requests', value: D.fmt.num(detail.improve_breakdown.improve_requests) },
              { label: 'Acceptance Rate', value: detail.improve_breakdown.acceptance_rate !== null ? D.fmt.pct(detail.improve_breakdown.acceptance_rate) : '\u2014', color: 'var(--d-success)' },
              { label: 'No Change Rate', value: detail.improve_breakdown.no_change_rate !== null ? D.fmt.pct(detail.improve_breakdown.no_change_rate) : '\u2014' },
            ])}
            <div class="d-mt-4">
              ${D.horizontalBars([
                { label: 'Copy', value: detail.improve_breakdown.copy_count, color: '#10b981' },
                { label: 'Replace', value: detail.improve_breakdown.replace_count, color: '#3b82f6' },
                { label: 'Dismiss', value: detail.improve_breakdown.dismiss_count, color: '#f59e0b' },
                { label: 'No Change', value: detail.improve_breakdown.no_change_count, color: '#6b7280' },
              ].filter(b => b.value > 0))}
            </div>
          </div>
        </div>
      ` : ''}

      ${detail.history_breakdown ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('History Usage')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.statRow([
              { label: 'Opens', value: D.fmt.num(detail.history_breakdown.history_opens) },
              { label: 'Follow-Ups', value: D.fmt.num(detail.history_breakdown.history_followups) },
              { label: 'Clears', value: D.fmt.num(detail.history_breakdown.history_clears) },
            ])}
          </div>
        </div>
      ` : ''}

      ${recentReqs.length ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Recent Requests')}
          <div class="d-chart-card">${D.table({
            headers: ['Type', 'Status', { label: 'Tokens', align: 'right' }, { label: 'Latency', align: 'right' }, { label: 'Cost', align: 'right' }, 'Time'],
            rows: recentReqs.slice(0, 20).map(r => ({
              cells: [
                `<strong>${D.label(r.request_type)}</strong>`,
                r.success ? D.badge('OK', 'success') : D.badge(r.error_type || 'FAIL', 'danger'),
                r.total_tokens ? D.fmt.num(r.total_tokens) : '\u2014',
                D.fmt.latency(r.latency_ms),
                D.fmt.usd(r.estimated_cost_usd),
                D.fmt.timeAgo(r.created_at),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
            <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(detail))}')), 'user-${userId}.json')">Export JSON</button>
            ${u.status === 'active' ? `<button class="d-btn d-btn-sm d-btn-ghost" style="color:var(--d-warning)" onclick="App.pages.userDetail._toggleUser('${userId}', 'disable')">Disable User</button>` : ''}
            ${u.status === 'disabled' ? `<button class="d-btn d-btn-sm d-btn-ghost" style="color:var(--d-success)" onclick="App.pages.userDetail._toggleUser('${userId}', 'enable')">Enable User</button>` : ''}
          </div>
        </div>
      </div>
    `;

    requestAnimationFrame(() => {
      if (dailyTrend.length) {
        D.renderAreaChart('user-detail-trend', dailyTrend.map(d => d.requests), {
          labels: dailyTrend.map(d => D.fmt.dateShort(d.date)),
          height: 180, color: '#3b82f6',
          yFormat: v => D.fmt.num(Math.round(v)), seriesName: 'Requests',
        });
      }
    });
  },

  async _toggleUser(userId, action) {
    if (!confirm(`Are you sure you want to ${action} this user?`)) return;
    try {
      const res = await fetch(`/api/admin/users/${userId}/${action}`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${App.token}` },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      D.api.clearCache();
      this.render();
    } catch (err) {
      alert(`Failed to ${action} user: ${err.message}`);
    }
  },
};


/* ══════════════════════════════════════════════════════════
   WORKSPACES
   ══════════════════════════════════════════════════════════ */

App.pages.workspaces = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-workspaces');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Workspace Activity')}
      ${D.kpiLoading(4, 4)}`;

    try {
      const product = await D.api.fetch(D.api.url('/api/v2/analytics/product'));
      this._lastData = { product };
      this._renderLive(el, product);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load workspace data', err.message, "App.pages.workspaces.render()")}`;
    }
  },

  _renderLive(el, product) {
    const modes = product.by_mode || [];
    const sessionMode = modes.find(m => m.mode === 'session') || { count: 0, users: 0 };
    const languages = product.by_language || [];

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Session Mode Activity')}
      ${D.kpiGrid([
        D.kpi({ label: 'Session Requests', value: D.fmt.num(sessionMode.count), sub: 'Workspace-based queries', accent: 'brand' }),
        D.kpi({ label: 'Session Users', value: D.fmt.num(sessionMode.users), sub: 'Active workspace users', accent: 'info' }),
        D.kpi({ label: 'Avg Latency', value: D.fmt.latency(sessionMode.avg_latency_ms), accent: 'warning' }),
        D.kpi({ label: 'Languages', value: D.fmt.num(languages.filter(l => l.language !== 'unspecified').length), sub: 'Distinct languages', accent: 'success' }),
      ], 4)}

      ${languages.filter(l => l.language !== 'unspecified').length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Language Distribution')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(languages.filter(l => l.language !== 'unspecified').slice(0, 10).map((l, i) => ({
              label: l.language,
              value: l.count,
              color: ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b','#ef4444','#06b6d4','#f97316','#84cc16','#ec4899'][i % 10],
            })))}
          </div>
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        <div class="d-chart-card" style="padding:var(--d-sp-6);text-align:center">
          <div style="font-size:1.5rem;margin-bottom:8px">&#x1F4C1;</div>
          <div style="font-weight:600;margin-bottom:4px;font-size:0.9rem">Limited Workspace Telemetry</div>
          <div style="color:var(--d-text-3);font-size:0.85rem;max-width:480px;margin:0 auto">
            Workspace-level analytics (file counts, indexing health, per-workspace metrics) require client-side telemetry not yet instrumented.
            Current data shows Session Mode and language usage as proxies for workspace activity.
          </div>
        </div>
      </div>
    `;
  },
};


/* ══════════════════════════════════════════════════════════
   QUALITY & RELIABILITY
   ══════════════════════════════════════════════════════════ */

App.pages.quality = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-quality');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Reliability')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.sectionHeader('Trends')}${D.chartLoading(2, 2)}</div>`;

    try {
      const [quality, live] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/quality')),
        D.api.fetch(D.api.url('/api/v2/analytics/live', { minutes: 60, limit: 50 })),
      ]);
      this._lastData = { quality, live };
      this._renderLive(el, quality, live);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load quality data', err.message, "App.pages.quality.render()")}`;
    }
  },

  _renderLive(el, quality, live) {
    const rel = quality.reliability || {};
    const lat = quality.latency || {};
    const errors = quality.errors || [];
    const dailyTrend = quality.daily_trend || [];
    const totalErrors = rel.failed || 0;

    const dailyLabels = dailyTrend.map(d => D.fmt.dateShort(d.date));
    const dailySuccessRate = dailyTrend.map(d => d.success_rate);
    const dailyLatency = dailyTrend.map(d => d.avg_latency_ms);

    const failedReqs = (live.requests || []).filter(r => !r.success).slice(0, 10);

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Reliability')}
      ${D.kpiGrid([
        D.kpi({ label: 'Success Rate', value: D.fmt.pct(rel.success_rate), accent: rel.success_rate >= 95 ? 'success' : rel.success_rate >= 80 ? 'warning' : 'danger' }),
        D.kpi({ label: 'Total Requests', value: D.fmt.num(rel.total_requests), accent: 'brand' }),
        D.kpi({ label: 'Failed Requests', value: D.fmt.num(totalErrors), accent: totalErrors === 0 ? 'success' : 'danger' }),
        D.kpi({ label: 'p95 Latency', value: D.fmt.latency(lat.p95_ms), sub: 'p50: ' + D.fmt.latency(lat.p50_ms), accent: lat.p95_ms > 5000 ? 'danger' : 'warning' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Success Rate over Time', canvasId: 'quality-line-success', height: 220 }),
          D.chartCard({ title: 'Avg Latency over Time', canvasId: 'quality-line-latency', height: 220 }),
        ], 2)}
      </div>

      ${errors.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Error Distribution', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.quality._exportErrors()">Export</button>`)}
          ${D.chartGrid([
            D.chartCard({ title: 'Error Types', canvasId: 'quality-donut-errors', height: 260, placeholder: false }),
            `<div class="d-chart-card" style="padding:var(--d-sp-5)">
              <h4 style="margin:0 0 12px;font-size:0.85rem;font-weight:600">Error Breakdown</h4>
              ${D.horizontalBars(errors.map(e => ({
                label: e.error_type, value: e.count, color: '#ef4444',
              })))}
            </div>`,
          ], 2)}
        </div>
      ` : ''}

      ${failedReqs.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Recent Failures (Last Hour)')}
          <div class="d-chart-card">${D.table({
            headers: ['Error', 'Mode', 'Provider', { label: 'Latency', align: 'right' }, 'Time'],
            rows: failedReqs.map(r => ({
              cells: [
                `<span class="d-text-danger">${D.fmt.escapeHtml(r.error_type || 'unknown')}</span>`,
                D.label(r.origin_mode),
                `<span class="d-text-mono">${D.fmt.escapeHtml(r.ai_provider || '')}</span>`,
                D.fmt.latency(r.latency_ms),
                D.fmt.timeAgo(r.created_at),
              ],
            })),
          })}</div>
        </div>
      ` : ''}
    `;

    requestAnimationFrame(() => {
      if (dailySuccessRate.length) {
        D.renderAreaChart('quality-line-success', dailySuccessRate, {
          labels: dailyLabels, height: 220, color: '#10b981',
          min: Math.max(0, Math.min(...dailySuccessRate) - 5),
          yFormat: v => D.fmt.pct(v, 0), seriesName: 'Success Rate',
        });
      }
      if (dailyLatency.length) {
        D.renderAreaChart('quality-line-latency', dailyLatency, {
          labels: dailyLabels, height: 220, color: '#f59e0b',
          yFormat: v => D.fmt.latency(v), seriesName: 'Latency',
        });
      }
      if (errors.length) {
        const errorColors = ['#ef4444','#f97316','#f59e0b','#84cc16','#8b5cf6','#ec4899','#06b6d4'];
        const errSegs = errors.map((e, i) => ({ label: e.error_type, value: e.count, color: errorColors[i % errorColors.length] }));
        const errCanvas = document.getElementById('quality-donut-errors');
        if (errCanvas) {
          const body = errCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="quality-donut-errors" style="width:180px;height:180px"></canvas>${D.donutLegend(errSegs, totalErrors)}</div>`;
          D.renderDonutChart('quality-donut-errors', errSegs, { height: 180, centerLabel: D.fmt.num(totalErrors), centerSub: 'errors' });
        }
      }
    });
  },

  _exportErrors() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.quality.errors, 'errors.csv', 'csv');
  },
};


/* ══════════════════════════════════════════════════════════
   COST INTELLIGENCE
   ══════════════════════════════════════════════════════════ */

App.pages.cost = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-cost');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Cost Overview')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.sectionHeader('Trends')}${D.chartLoading(2, 2)}</div>`;

    try {
      const [cost, exec] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/cost')),
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
      ]);
      this._lastData = { cost, exec };
      this._renderLive(el, cost, exec);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load cost data', err.message, "App.pages.cost.render()")}`;
    }
  },

  _renderLive(el, cost, exec) {
    const totalCost = cost.total_cost_usd || 0;
    const providers = cost.by_provider || [];
    const byType = cost.by_request_type || [];
    const dailyTrend = cost.daily_trend || [];

    const costPerReq = exec.total_requests > 0 ? totalCost / exec.total_requests : 0;
    const costPerUser = exec.unique_users > 0 ? totalCost / exec.unique_users : 0;
    const todayCost = dailyTrend.length > 0 ? dailyTrend[dailyTrend.length - 1].cost_usd : 0;

    const dailyLabels = dailyTrend.map(d => D.fmt.dateShort(d.date));
    const dailyCostData = dailyTrend.map(d => d.cost_usd);
    const dailyCPR = dailyTrend.map(d => d.requests > 0 ? d.cost_usd / d.requests : 0);

    const provColors = ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b','#ef4444'];

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Cost Overview')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Cost', value: D.fmt.usdCompact(totalCost), accent: 'brand', sparkData: dailyCostData }),
        D.kpi({ label: 'Today\'s Cost', value: D.fmt.usd(todayCost), accent: 'warning' }),
        D.kpi({ label: 'Cost / Request', value: D.fmt.usd(costPerReq, 4), sub: `${D.fmt.num(exec.total_requests)} requests` }),
        D.kpi({ label: 'Cost / User', value: D.fmt.usd(costPerUser, 2), sub: `${D.fmt.num(exec.unique_users)} users`, accent: 'info' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Cost Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Daily Cost', canvasId: 'cost-chart-daily', height: 220 }),
          D.chartCard({ title: 'Cost per Request Trend', canvasId: 'cost-chart-cpr', height: 220 }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Cost Breakdown')}
        ${D.chartGrid([
          D.chartCard({ title: 'Cost by Provider', canvasId: 'cost-donut-provider', height: 260, placeholder: false }),
          D.chartCard({ title: 'Cost by Operation', canvasId: 'cost-donut-type', height: 260, placeholder: false }),
        ], 2)}
      </div>

      ${providers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Provider Economics', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.cost._exportProviders()">Export</button>`)}
          <div class="d-chart-card">${D.table({
            headers: [
              'Provider',
              { label: 'Cost', align: 'right' },
              { label: 'Requests', align: 'right' },
              { label: 'Cost / Req', align: 'right' },
              { label: '% of Spend', align: 'right' },
            ],
            rows: providers.map(p => ({
              cells: [
                `<strong>${D.fmt.escapeHtml(p.provider)}</strong>`,
                D.fmt.usd(p.cost_usd),
                D.fmt.num(p.requests),
                D.fmt.usd(p.requests > 0 ? p.cost_usd / p.requests : 0, 4),
                D.fmt.pct(totalCost > 0 ? (p.cost_usd / totalCost * 100) : 0),
              ],
            })),
          })}</div>
        </div>
      ` : ''}

      ${byType.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Cost by Operation Type')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(byType.map(t => ({
              label: D.label(t.request_type),
              value: t.cost_usd,
              color: D.featureColor(t.request_type),
            })), { valueFormat: v => D.fmt.usd(v) })}
          </div>
        </div>
      ` : ''}
    `;

    requestAnimationFrame(() => {
      D.renderAreaChart('cost-chart-daily', dailyCostData, {
        labels: dailyLabels, height: 220, color: '#f59e0b',
        yFormat: v => D.fmt.usdCompact(v), seriesName: 'Cost',
      });
      D.renderAreaChart('cost-chart-cpr', dailyCPR, {
        labels: dailyLabels, height: 220, color: '#8b5cf6',
        yFormat: v => D.fmt.usd(v, 4), seriesName: 'Cost/Request',
      });

      if (providers.length) {
        const provSegs = providers.map((p, i) => ({ label: p.provider, value: p.cost_usd, color: provColors[i % provColors.length] }));
        const pCanvas = document.getElementById('cost-donut-provider');
        if (pCanvas) {
          const body = pCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="cost-donut-provider" style="width:180px;height:180px"></canvas>${D.donutLegend(provSegs, totalCost)}</div>`;
          D.renderDonutChart('cost-donut-provider', provSegs, { height: 180, centerLabel: D.fmt.usdCompact(totalCost), centerSub: 'total' });
        }
      }
      if (byType.length) {
        const typeTot = byType.reduce((s, t) => s + t.cost_usd, 0);
        const typeSegs = byType.map(t => ({ label: D.label(t.request_type), value: t.cost_usd, color: D.featureColor(t.request_type) }));
        const tCanvas = document.getElementById('cost-donut-type');
        if (tCanvas) {
          const body = tCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="cost-donut-type" style="width:180px;height:180px"></canvas>${D.donutLegend(typeSegs, typeTot)}</div>`;
          D.renderDonutChart('cost-donut-type', typeSegs, { height: 180, centerLabel: D.fmt.usdCompact(typeTot), centerSub: 'by type' });
        }
      }

      D.renderSparklines(el);
    });
  },

  _exportProviders() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.cost.by_provider, 'cost-providers.csv', 'csv');
  },
};


/* ══════════════════════════════════════════════════════════
   SETTINGS
   ══════════════════════════════════════════════════════════ */

App.pages.settings = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-settings');
    el.innerHTML = `${D.sectionHeader('System Configuration')}${D.loading()}`;

    try {
      const settings = await D.api.fetch('/api/v2/analytics/settings');
      this._lastData = settings;
      this._renderLive(el, settings);
    } catch (err) {
      el.innerHTML = D.error('Failed to load settings', err.message, "App.pages.settings.render()");
    }
  },

  _renderLive(el, s) {
    const aiConfig = s.ai_config || {};
    const data = s.data || {};
    const users = s.users || {};

    el.innerHTML = `
      ${D.sectionHeader('System Configuration')}

      ${D.kpiGrid([
        D.kpi({ label: 'Total Users', value: D.fmt.num(users.total), accent: 'brand' }),
        D.kpi({ label: 'Active Users', value: D.fmt.num(users.active), accent: 'success' }),
        D.kpi({ label: 'V2 Requests', value: D.fmt.num(data.v2_ai_requests), accent: 'info' }),
        D.kpi({ label: 'Legacy Requests', value: D.fmt.num(data.legacy_request_logs), accent: 'warning' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('AI Configuration')}
        <div class="d-chart-card">
          ${D.table({
            headers: ['Setting', 'Value'],
            rows: [
              { cells: ['<strong>Adapter</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.adapter || '\u2014')}</span>`] },
              { cells: ['<strong>Anthropic Model</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.anthropic_model || '\u2014')}</span>`] },
              { cells: ['<strong>Groq Model</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.groq_model || '\u2014')}</span>`] },
              { cells: ['<strong>Vision Provider</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.vision_provider || '\u2014')}</span>`] },
            ],
          })}
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Invite Management')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <div style="display:grid;grid-template-columns:1fr 1fr auto;gap:12px;align-items:end">
            <div>
              <label style="display:block;font-size:12px;font-weight:550;color:var(--d-text-2);margin-bottom:6px">Name <span style="font-weight:400;color:var(--d-text-3)">(optional)</span></label>
              <input type="text" id="invite-name" class="d-input" placeholder="e.g. Jane Doe" style="font-size:13px;padding:8px 12px">
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:550;color:var(--d-text-2);margin-bottom:6px">Email <span style="font-weight:400;color:var(--d-text-3)">(optional)</span></label>
              <input type="email" id="invite-email" class="d-input" placeholder="e.g. jane@company.com" style="font-size:13px;padding:8px 12px">
            </div>
            <button id="invite-generate-btn" class="d-btn d-btn-primary" style="height:38px" onclick="App.pages.settings._generateInvite()">Generate</button>
          </div>
          <div id="invite-result" style="display:none;margin-top:16px;padding:14px 16px;border-radius:var(--d-r-sm);background:var(--d-success-subtle);border:1px solid rgba(16, 185, 129, 0.2)">
            <div style="display:flex;align-items:center;justify-content:space-between">
              <div>
                <div style="font-size:11px;font-weight:550;color:var(--d-text-2);margin-bottom:4px">Invite Code</div>
                <span id="invite-code-display" class="d-text-mono" style="font-size:18px;font-weight:700;letter-spacing:0.5px;color:var(--d-success)"></span>
              </div>
              <button class="d-btn d-btn-sm" onclick="App.pages.settings._copyInviteCode()">Copy</button>
            </div>
          </div>
          <div id="invite-error" style="display:none;margin-top:12px;font-size:13px;color:var(--d-danger)"></div>
          <div id="invite-list" style="margin-top:20px"></div>
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Dashboard')}
        <div class="d-chart-card" style="padding:var(--d-sp-6)">
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
            <div>
              <div style="font-size:12px;font-weight:600;color:var(--d-text-2);margin-bottom:8px">API Connection</div>
              <div class="d-flex d-items-center" style="gap:8px">
                ${D.badge('Connected', 'success', true)}
                <span style="font-size:12px;color:var(--d-text-3)">Analytics v2 API</span>
              </div>
            </div>
            <div>
              <div style="font-size:12px;font-weight:600;color:var(--d-text-2);margin-bottom:8px">Data Source</div>
              <div class="d-flex d-items-center" style="gap:8px">
                ${D.badge(s._source || 'v2', s._source === 'legacy' ? 'warning' : 'info', true)}
              </div>
            </div>
          </div>

          <div style="margin-top:20px">
            <div style="font-size:12px;font-weight:600;color:var(--d-text-2);margin-bottom:8px">Keyboard Shortcuts</div>
            <div style="font-size:12px;color:var(--d-text-3);line-height:2.2">
              <kbd class="d-kbd">&#x2318;K</kbd> Search &nbsp;&nbsp;
              <kbd class="d-kbd">R</kbd> Refresh &nbsp;&nbsp;
              <kbd class="d-kbd">1-4</kbd> Date presets &nbsp;&nbsp;
              <kbd class="d-kbd">Esc</kbd> Close panels
            </div>
          </div>

          <div style="margin-top:20px;display:flex;gap:12px;flex-wrap:wrap">
            <button class="d-btn d-btn-sm" onclick="App.logout()">Sign Out</button>
            <button class="d-btn d-btn-sm d-btn-ghost" onclick="D.api.clearCache();App.refreshPage()">Clear Cache</button>
          </div>
        </div>
      </div>
    `;

    this._loadInviteList();
  },

  _inviteInFlight: false,

  async _generateInvite() {
    if (this._inviteInFlight) return;

    const btn = document.getElementById('invite-generate-btn');
    const nameInput = document.getElementById('invite-name');
    const emailInput = document.getElementById('invite-email');
    const resultEl = document.getElementById('invite-result');
    const errorEl = document.getElementById('invite-error');
    const codeEl = document.getElementById('invite-code-display');

    errorEl.style.display = 'none';
    errorEl.textContent = '';

    const body = {};
    const name = (nameInput.value || '').trim();
    const email = (emailInput.value || '').trim();
    if (name) body.name = name;
    if (email) body.email = email;

    this._inviteInFlight = true;
    const origText = btn.textContent;
    btn.textContent = 'Generating\u2026';
    btn.disabled = true;
    btn.style.opacity = '0.6';

    try {
      const res = await fetch('/api/admin/invite', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${App.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try { const d = await res.json(); if (d.detail) msg = d.detail; } catch {}
        throw new Error(msg);
      }
      const data = await res.json();
      codeEl.textContent = data.invite_code;
      resultEl.style.display = 'block';
      nameInput.value = '';
      emailInput.value = '';
      this._loadInviteList();
    } catch (err) {
      errorEl.textContent = 'Failed to generate invite: ' + err.message;
      errorEl.style.display = 'block';
    } finally {
      this._inviteInFlight = false;
      btn.textContent = origText;
      btn.disabled = false;
      btn.style.opacity = '';
    }
  },

  _copyInviteCode() {
    const code = document.getElementById('invite-code-display')?.textContent;
    if (!code) return;
    navigator.clipboard.writeText(code).then(() => {
      const btn = event.target;
      const orig = btn.textContent;
      btn.textContent = 'Copied!';
      setTimeout(() => { btn.textContent = orig; }, 1500);
    }).catch(() => {});
  },

  async _loadInviteList() {
    const container = document.getElementById('invite-list');
    if (!container) return;
    try {
      const res = await fetch('/api/admin/users', {
        headers: { 'Authorization': `Bearer ${App.token}` },
      });
      if (!res.ok) return;
      const users = await res.json();

      const withInvites = users.filter(u => u.invite_code);
      if (withInvites.length === 0) {
        container.innerHTML = '<div style="font-size:12px;color:var(--d-text-3)">No invites generated yet</div>';
        return;
      }

      const statusOrder = { pending: 0, active: 1, disabled: 2 };
      withInvites.sort((a, b) => {
        const so = (statusOrder[a.status] ?? 3) - (statusOrder[b.status] ?? 3);
        if (so !== 0) return so;
        return new Date(b.created_at || 0) - new Date(a.created_at || 0);
      });

      container.innerHTML = D.table({
        headers: ['Invite Code', 'Name', 'Email', 'Status', { label: 'Requests', align: 'right' }, 'Activated'],
        rows: withInvites.map(u => ({
          cells: [
            `<span class="d-text-mono" style="font-size:12px">${D.fmt.escapeHtml(u.invite_code)}</span>`,
            D.fmt.escapeHtml(u.name || '\u2014'),
            u.email && !u.email.startsWith('pending-') ? D.fmt.escapeHtml(u.email) : '\u2014',
            D.badge(u.status, u.status === 'active' ? 'success' : u.status === 'pending' ? 'warning' : 'danger'),
            D.fmt.num(u.total_requests || 0),
            u.activated_at ? D.fmt.timeAgo(u.activated_at) : '\u2014',
          ],
        })),
      });
    } catch (err) {
      container.innerHTML = '';
    }
  },
};


/* ══════════════════════════════════════════════════════════
   FEEDBACK
   ══════════════════════════════════════════════════════════ */

App.pages.feedback = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-feedback');
    el.innerHTML = `${D.globalFilterBar()}${D.loading()}`;

    try {
      const data = await D.api.fetch(D.api.url('/api/v2/analytics/feedback'));
      this._lastData = data;
      this._renderLive(el, data);
    } catch (e) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load feedback data', e.message, "App.pages.feedback.render()")}`;
    }
  },

  _renderLive(el, data) {
    const satisfactionAccent = data.satisfaction >= 70 ? 'success' : data.satisfaction >= 40 ? 'warning' : 'danger';

    let html = D.globalFilterBar();

    html += D.sectionHeader('Satisfaction Overview');
    html += D.kpiGrid([
      D.kpi({ label: 'Satisfaction', value: D.fmt.pct(data.satisfaction), accent: satisfactionAccent }),
      D.kpi({ label: 'Total Feedback', value: D.fmt.num(data.total_feedback), accent: 'brand' }),
      D.kpi({ label: 'Likes', value: D.fmt.num(data.likes), accent: 'success' }),
      D.kpi({ label: 'Dislikes', value: D.fmt.num(data.dislikes), accent: 'danger' }),
    ], 4);

    if (data.by_feature && data.by_feature.length) {
      html += '<div class="d-section d-mt-6">';
      html += D.sectionHeader('By Feature');
      html += '<div class="d-chart-card">' + D.table({
        headers: ['Feature', { label: 'Total', align: 'right' }, { label: 'Likes', align: 'right' }, { label: 'Dislikes', align: 'right' }, { label: 'Satisfaction', align: 'right' }],
        rows: data.by_feature.map(r => ({
          cells: [
            `<strong style="color:${D.featureColor(r.feature)}">${D.label(r.feature)}</strong>`,
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ],
        })),
      }) + '</div></div>';
    }

    if (data.by_mode && data.by_mode.length) {
      html += '<div class="d-section d-mt-6">';
      html += D.sectionHeader('By Mode');
      html += '<div class="d-chart-card">' + D.table({
        headers: ['Mode', { label: 'Total', align: 'right' }, { label: 'Likes', align: 'right' }, { label: 'Dislikes', align: 'right' }, { label: 'Satisfaction', align: 'right' }],
        rows: data.by_mode.map(r => ({
          cells: [
            `<strong style="color:${D.featureColor(r.mode)}">${D.label(r.mode)}</strong>`,
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ],
        })),
      }) + '</div></div>';
    }

    if (data.daily_trend && data.daily_trend.length > 1) {
      html += '<div class="d-section d-mt-6">';
      html += D.sectionHeader('Feedback Over Time');
      html += D.chartGrid([
        D.chartCard({ title: 'Daily Feedback', height: 220, canvasId: 'feedback-daily-chart' }),
        D.chartCard({ title: 'Daily Satisfaction', height: 220, canvasId: 'feedback-satisfaction-chart' }),
      ], 2);
      html += '</div>';
    }

    el.innerHTML = html;

    if (data.daily_trend && data.daily_trend.length > 1) {
      requestAnimationFrame(() => {
        D.renderBarChart('feedback-daily-chart',
          data.daily_trend.map(d => d.total),
          { labels: data.daily_trend.map(d => D.fmt.dateShort(d.date)), colors: '#e87830' }
        );
        const satValues = data.daily_trend.map(d => d.total > 0 ? Math.round(d.likes / d.total * 100) : 0);
        D.renderAreaChart('feedback-satisfaction-chart', satValues, {
          labels: data.daily_trend.map(d => D.fmt.dateShort(d.date)),
          color: '#10b981', yFormat: v => v + '%', seriesName: 'Satisfaction',
        });
      });
    }
  },
};


/* ── Initialize on DOM ready ── */
document.addEventListener('DOMContentLoaded', () => App.init());
