/* ══════════════════════════════════════════════════════════
   Decode Dashboard v2 — Application Shell
   ══════════════════════════════════════════════════════════
   Navigation, auth, page routing, global filters,
   keyboard shortcuts, and lifecycle management.
   ────────────────────────────────────────────────────────── */

const App = {
  token: null,
  currentPage: null,
  pages: {},

  /* ── Global Filter State ── */
  filters: {
    preset: '7d',
    days: 7,
    start: null,
    end: null,
  },

  /* ── Bootstrap ── */

  init() {
    // Try auto-login from sessionStorage
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
    if (!token) {
      errEl.textContent = 'Please enter an admin token';
      return;
    }

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
    } catch (e) {
      errEl.textContent = 'Connection failed';
    }
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
      if (res.ok) {
        this.hideAuth();
        this.navigate('executive');
      } else {
        this.showAuth();
      }
    } catch {
      this.showAuth();
    }
  },

  /* ── Raw API (for auth validation) ── */

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
    // Update sidebar
    document.querySelectorAll('.d-nav-item').forEach(el => {
      el.classList.toggle('active', el.dataset.page === pageId);
    });

    // Update topbar title
    const meta = this.pageMeta[pageId] || {};
    document.getElementById('d-topbar-title').textContent = meta.title || pageId;
    const subtitle = document.getElementById('d-topbar-subtitle');
    subtitle.textContent = meta.subtitle || '';

    // Show/hide page views
    document.querySelectorAll('.d-page-view').forEach(el => {
      el.classList.toggle('active', el.id === `page-${pageId}`);
    });

    this.currentPage = pageId;

    // Load page content if a renderer exists
    if (this.pages[pageId] && this.pages[pageId].render) {
      this.pages[pageId].render();
    }
  },

  pageMeta: {
    executive:  { title: 'Executive Overview',    subtitle: 'Platform health at a glance' },
    product:    { title: 'Product Intelligence',   subtitle: 'Feature adoption and engagement' },
    ai:         { title: 'AI Platform',            subtitle: 'Provider health and operations' },
    users:      { title: 'Users',                  subtitle: 'User management and profiles' },
    workspaces: { title: 'Workspaces',             subtitle: 'Workspace and project analytics' },
    quality:    { title: 'Quality & Errors',       subtitle: 'Reliability and error analysis' },
    cost:       { title: 'Cost Intelligence',      subtitle: 'AI economics and optimization' },
    settings:   { title: 'Settings',               subtitle: 'Dashboard configuration' },
  },

  /* ── Global Filter Actions ── */

  setDatePreset(presetId, days) {
    this.filters = { preset: presetId, days, start: null, end: null };
    D.api.clearCache();

    // Update filter button active states
    document.querySelectorAll('.d-global-filter-bar [data-preset]').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.preset === presetId);
    });

    // Re-render current page
    this.refreshPage();
  },

  refreshPage() {
    D.api.clearCache();
    if (this.currentPage && this.pages[this.currentPage]?.render) {
      this.pages[this.currentPage].render();
    }
  },

  exportPage() {
    // Export the last fetched data for the current page
    const page = this.pages[this.currentPage];
    if (page && page._lastData) {
      D.drillDown.exportData(
        page._lastData,
        `decode-${this.currentPage}-${new Date().toISOString().slice(0,10)}.json`
      );
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
      const data = await D.api.fetch(
        D.api.url('/api/v2/analytics/search', { q: query, limit: 20 }),
        { noCache: true, retries: 0 }
      );
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
      this.navigate('users');
    }
  },

  /* ── Keyboard Shortcuts ── */

  _initKeyboardShortcuts() {
    document.addEventListener('keydown', e => {
      // Don't capture when in input fields
      const tag = e.target.tagName;
      const isInput = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';

      // Cmd+K / Ctrl+K — Search
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        this.toggleSearch();
        return;
      }

      // Escape — Close drawers/modals
      if (e.key === 'Escape') {
        D.drillDown.close();
        const searchModal = document.getElementById('d-search-modal');
        if (searchModal?.classList.contains('open')) this.toggleSearch();
        return;
      }

      if (isInput) return;

      // R — Refresh
      if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        this.refreshPage();
        return;
      }

      // Number keys for date presets
      if (e.key === '1') { this.setDatePreset('today', 1); return; }
      if (e.key === '2') { this.setDatePreset('7d', 7); return; }
      if (e.key === '3') { this.setDatePreset('30d', 30); return; }
      if (e.key === '4') { this.setDatePreset('90d', 90); return; }
    });
  },
};


/* ══════════════════════════════════════════════════════════
   PAGE MODULES — Each page is self-contained
   ══════════════════════════════════════════════════════════ */


/* ═══════════════════════════════════════════════════════════
   EXECUTIVE OVERVIEW — Live Data
   ═══════════════════════════════════════════════════════════ */

App.pages.executive = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-executive');

    // Show loading state
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Key Metrics')}
      ${D.kpiLoading(4, 4)}
      <div class="d-mt-6">${D.kpiLoading(4, 4)}</div>
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Trends')}
        ${D.chartLoading(2, 2)}
      </div>
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Platform Breakdown')}
        ${D.chartLoading(2, 2)}
      </div>
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Recent Activity')}
        ${D.loading()}
      </div>`;

    try {
      // Fetch all data in parallel
      const [exec, quality, aiPlatform, cost, timeline] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
        D.api.fetch(D.api.url('/api/v2/analytics/quality')),
        D.api.fetch(D.api.url('/api/v2/analytics/ai-platform')),
        D.api.fetch(D.api.url('/api/v2/analytics/cost')),
        D.api.fetch(D.api.url('/api/v2/analytics/timeline', { limit: 15 })),
      ]);

      this._lastData = { exec, quality, aiPlatform, cost, timeline };
      this._renderLive(el, exec, quality, aiPlatform, cost, timeline);
    } catch (err) {
      el.innerHTML = `
        ${D.globalFilterBar()}
        ${D.error('Failed to load executive data', err.message, "App.pages.executive.render()")}`;
    }
  },

  _renderLive(el, exec, quality, aiPlatform, cost, timeline) {
    const dailyRequests = exec.daily_trend?.map(d => d.requests) || [];
    const dailyUsers = exec.daily_trend?.map(d => d.users) || [];
    const dailyLabels = exec.daily_trend?.map(d => D.fmt.dateShort(d.date)) || [];
    const dailyCost = cost.daily_trend?.map(d => d.cost_usd) || [];
    const dailyCostLabels = cost.daily_trend?.map(d => D.fmt.dateShort(d.date)) || [];

    // Calculate cost per request
    const costPerReq = exec.total_requests > 0 && cost.total_cost_usd > 0
      ? cost.total_cost_usd / exec.total_requests
      : null;

    // Provider breakdown for the bar chart
    const providers = aiPlatform.by_provider || [];
    const providerNames = providers.map(p => p.provider);
    const providerCounts = providers.map(p => p.count);
    const providerColors = providers.map(p => {
      if (p.provider.includes('anthropic')) return '#e87830';
      if (p.provider.includes('groq')) return '#3b82f6';
      if (p.provider.includes('openai')) return '#10b981';
      return '#8b5cf6';
    });

    // Mode breakdown
    const modes = (aiPlatform.by_model || []).slice(0, 6);
    const modeNames = modes.map(m => m.model.split('/').pop().substring(0, 16));
    const modeCounts = modes.map(m => m.count);

    // Timeline events
    const timelineEvents = (timeline.events || []).slice(0, 12).map(e => {
      let type = 'info';
      if (e.type === 'error') type = 'danger';
      else if (e.type === 'user_activation') type = 'success';
      else if (e.type === 'daily_summary') type = 'brand';
      return {
        type,
        time: D.fmt.timeAgo(e.timestamp),
        text: e.title,
        meta: e.detail?.cost_usd != null ? `Cost: ${D.fmt.usd(e.detail.cost_usd)}` :
              e.detail?.provider ? `${e.detail.provider} / ${e.detail.model || ''}` : '',
      };
    });

    // Data source indicator
    const sourceHtml = exec._source === 'legacy'
      ? `<span class="d-badge d-badge-warning" style="margin-left:8px">Legacy data</span>`
      : '';

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Key Metrics', sourceHtml)}
      ${D.kpiGrid([
        D.kpi({
          label: 'Total Requests',
          value: D.fmt.num(exec.total_requests),
          sub: `${D.fmt.dateShort(exec.period?.start)} — ${D.fmt.dateShort(exec.period?.end)}`,
          accent: 'brand',
          sparkData: dailyRequests,
        }),
        D.kpi({
          label: 'Active Users',
          value: D.fmt.num(exec.unique_users),
          sub: 'Unique users in period',
          accent: 'info',
          sparkData: dailyUsers,
        }),
        D.kpi({
          label: 'Success Rate',
          value: D.fmt.pct(exec.success_rate),
          sub: `${D.fmt.num(exec.failed_requests)} failed`,
          accent: exec.success_rate >= 95 ? 'success' : exec.success_rate >= 80 ? 'warning' : 'danger',
        }),
        D.kpi({
          label: 'Total Cost',
          value: D.fmt.usdCompact(cost.total_cost_usd),
          sub: costPerReq ? `${D.fmt.usd(costPerReq, 4)}/request` : 'No cost data',
          accent: 'warning',
          sparkData: dailyCost,
        }),
      ], 4)}

      <div class="d-mt-6">
        ${D.kpiGrid([
          D.kpi({
            label: 'Avg Latency',
            value: D.fmt.latency(exec.avg_latency_ms),
            sub: 'Successful requests',
          }),
          D.kpi({
            label: 'p95 Latency',
            value: D.fmt.latency(quality.latency?.p95_ms),
            sub: quality.latency?.p50_ms ? 'p50: ' + D.fmt.latency(quality.latency.p50_ms) : '',
            accent: quality.latency?.p95_ms > 5000 ? 'danger' : quality.latency?.p95_ms > 3000 ? 'warning' : 'success',
          }),
          D.kpi({
            label: 'Error Rate',
            value: exec.total_requests > 0 ? D.fmt.pct((exec.failed_requests / exec.total_requests) * 100) : '0%',
            sub: `${D.fmt.num(exec.failed_requests)} errors total`,
            accent: exec.failed_requests === 0 ? 'success' : 'danger',
          }),
          D.kpi({
            label: 'Providers Active',
            value: D.fmt.num(providers.length),
            sub: providerNames.join(', ') || 'None',
            accent: 'purple',
          }),
        ], 4)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests per Day', canvasId: 'exec-chart-requests', height: 220 }),
          D.chartCard({ title: 'Cost per Day', canvasId: 'exec-chart-cost', height: 220 }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Platform Breakdown')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests by Provider', canvasId: 'exec-chart-providers', height: 220 }),
          D.chartCard({ title: 'Requests by Model', canvasId: 'exec-chart-models', height: 220 }),
        ], 2)}
      </div>

      ${quality.errors && quality.errors.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Error Breakdown')}
          ${D.table({
            title: 'Errors by Type',
            headers: [
              'Error Type',
              { label: 'Count', align: 'right' },
              { label: '% of Errors', align: 'right' },
            ],
            rows: quality.errors.map(e => ({
              cells: [
                `<span class="d-text-danger">${D.fmt.escapeHtml(e.error_type)}</span>`,
                D.fmt.num(e.count),
                D.fmt.pct(exec.failed_requests > 0 ? (e.count / exec.failed_requests) * 100 : 0),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${providers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Provider Details')}
          ${D.table({
            headers: [
              'Provider',
              { label: 'Requests', align: 'right' },
              { label: 'Success %', align: 'right' },
              { label: 'Avg Latency', align: 'right' },
              { label: 'Cost', align: 'right' },
              { label: 'Tokens', align: 'right' },
            ],
            rows: providers.map(p => ({
              cells: [
                `<strong>${D.fmt.escapeHtml(p.provider)}</strong>`,
                D.fmt.num(p.count),
                `${D.badge(D.fmt.pct(p.success_rate), p.success_rate >= 95 ? 'success' : p.success_rate >= 80 ? 'warning' : 'danger')}`,
                D.fmt.latency(p.avg_latency_ms),
                D.fmt.usd(p.total_cost_usd),
                D.fmt.num(p.prompt_tokens + p.completion_tokens),
              ],
            })),
          })}
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Recent Activity', `<span class="d-text-dim" style="font-size:11px">${D.fmt.num(timeline.events?.length || 0)} events</span>`)}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          ${D.timeline(timelineEvents)}
        </div>
      </div>
    `;

    // Render charts after DOM update
    requestAnimationFrame(() => {
      D.renderAreaChart('exec-chart-requests', dailyRequests, {
        labels: dailyLabels,
        height: 220,
        color: '#e87830',
        yFormat: v => D.fmt.num(Math.round(v)),
      });
      D.renderAreaChart('exec-chart-cost', dailyCost, {
        labels: dailyCostLabels,
        height: 220,
        color: '#f59e0b',
        yFormat: v => D.fmt.usdCompact(v),
      });
      if (providerCounts.length) {
        D.renderBarChart('exec-chart-providers', providerCounts, {
          labels: providerNames,
          colors: providerColors,
          height: 220,
          yFormat: v => D.fmt.num(Math.round(v)),
        });
      }
      if (modeCounts.length) {
        D.renderBarChart('exec-chart-models', modeCounts, {
          labels: modeNames,
          colors: '#8b5cf6',
          height: 220,
          yFormat: v => D.fmt.num(Math.round(v)),
        });
      }
      D.renderSparklines(el);
    });
  },
};


/* ── Product Intelligence ── */

App.pages.product = {
  render() {
    const el = document.getElementById('page-product');
    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Feature Adoption')}
      ${D.kpiGrid([
        D.kpi({ label: 'Selection Mode', value: '—', accent: 'brand' }),
        D.kpi({ label: 'Session Mode', value: '—', accent: 'info' }),
        D.kpi({ label: 'Screenshot Mode', value: '—' }),
        D.kpi({ label: 'Follow-up Rate', value: '—', accent: 'purple' }),
      ], 4)}

      <div class="d-mt-6">
        ${D.kpiGrid([
          D.kpi({ label: 'Improve Adoption', value: '—', sub: 'of explanations' }),
          D.kpi({ label: 'Improve Acceptance', value: '—', sub: 'copy + replace' }),
          D.kpi({ label: 'Vision Trigger Rate', value: '—', sub: 'custom questions / total' }),
          D.kpi({ label: 'Virtual Session Adoption', value: '—', sub: 'users with VS enabled' }),
        ], 4)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Engagement')}
        ${D.chartGrid([
          D.chartCard({ title: 'Feature Adoption Waterfall', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Default vs Custom Questions', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Follow-up Depth Distribution', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Engagement Distribution', placeholder: 'Coming in Phase 2' }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Improve Code')}
        ${D.kpiGrid([
          D.kpi({ label: 'Improve Requests', value: '—' }),
          D.kpi({ label: 'Copies', value: '—', accent: 'info' }),
          D.kpi({ label: 'Replaces', value: '—', accent: 'success' }),
          D.kpi({ label: 'No Changes', value: '—' }),
          D.kpi({ label: 'Dismissals', value: '—' }),
          D.kpi({ label: 'Replace Failures', value: '—', accent: 'danger' }),
        ], 3)}
      </div>
    `;
  },
};


/* ── AI Platform ── */

App.pages.ai = {
  render() {
    const el = document.getElementById('page-ai');
    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Platform Health')}
      ${D.kpiGrid([
        D.kpi({ label: 'Requests (24h)', value: '—', accent: 'brand' }),
        D.kpi({ label: 'Success Rate', value: '—', accent: 'success' }),
        D.kpi({ label: 'p50 Latency', value: '—' }),
        D.kpi({ label: 'p95 Latency', value: '—', accent: 'warning' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Provider Performance')}
        ${D.chartGrid([
          D.chartCard({ title: 'Provider Latency', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Provider Error Rate', placeholder: 'Coming in Phase 2' }),
        ], 2)}

        <div class="d-mt-4">
          ${D.table({
            title: 'Provider Analytics',
            headers: ['Provider', 'Model', {label: 'Requests', align: 'right'}, {label: 'Success %', align: 'right'}, {label: 'Avg Latency', align: 'right'}, {label: 'Avg Tokens', align: 'right'}, {label: 'Est. Cost', align: 'right'}],
            rows: [],
            emptyText: 'Coming in Phase 2',
          })}
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Error Breakdown')}
        ${D.table({
          title: 'Errors by Type',
          headers: ['Error Type', {label: 'Count', align: 'right'}, {label: '% of Errors', align: 'right'}],
          rows: [],
          emptyText: 'Coming in Phase 2',
        })}
      </div>
    `;
  },
};


/* ── Users ── */

App.pages.users = {
  render() {
    const el = document.getElementById('page-users');
    el.innerHTML = `
      ${D.globalFilterBar()}

      <div class="d-flex d-items-center d-justify-between d-mb-6">
        <div class="d-filters" style="margin-bottom:0">
          <button class="d-filter-btn active">All Users</button>
          <button class="d-filter-btn">Active</button>
          <button class="d-filter-btn">Power</button>
          <button class="d-filter-btn">Dormant</button>
        </div>
        <button class="d-btn d-btn-primary" onclick="App.pages.users.showInvite()">+ Generate Invite</button>
      </div>

      ${D.sectionHeader('User Lifecycle')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Users', value: '—', accent: 'brand' }),
        D.kpi({ label: 'Active', value: '—', accent: 'success' }),
        D.kpi({ label: 'Power Users', value: '—', accent: 'purple' }),
        D.kpi({ label: 'Dormant', value: '—', accent: 'warning' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.table({
          title: 'All Users',
          headers: [
            'User', 'Status', {label: 'Requests', align: 'right'},
            {label: 'Avg Latency', align: 'right'}, {label: 'Est. Cost', align: 'right'},
            'Last Active',
          ],
          rows: [],
          emptyText: 'Coming in Phase 2',
        })}
      </div>
    `;
  },

  showInvite() {
    alert('Invite generation will be connected in a future milestone.');
  },
};


/* ── Workspaces ── */

App.pages.workspaces = {
  render() {
    const el = document.getElementById('page-workspaces');
    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Overview')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Workspaces', value: '—', accent: 'brand' }),
        D.kpi({ label: 'File Workspaces', value: '—' }),
        D.kpi({ label: 'Directory Workspaces', value: '—', accent: 'info' }),
        D.kpi({ label: 'Active (7d)', value: '—', accent: 'success' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Project Intelligence')}
        ${D.chartGrid([
          D.chartCard({ title: 'Workspace Growth', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Workspace Kind Distribution', placeholder: 'Coming in Phase 2' }),
        ], 2)}
      </div>
    `;
  },
};


/* ── Quality & Errors ── */

App.pages.quality = {
  render() {
    const el = document.getElementById('page-quality');
    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Reliability')}
      ${D.kpiGrid([
        D.kpi({ label: 'Success Rate', value: '—', accent: 'success' }),
        D.kpi({ label: 'Total Errors', value: '—', accent: 'danger' }),
        D.kpi({ label: 'Client Errors', value: '—', accent: 'warning' }),
        D.kpi({ label: 'Avg Latency', value: '—' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Error Analysis')}
        ${D.chartGrid([
          D.chartCard({ title: 'Error Trend', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Error Type Distribution', placeholder: 'Coming in Phase 2' }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.table({
          title: 'Error Breakdown',
          headers: ['Error Type', {label: 'Count', align: 'right'}, {label: '% of Errors', align: 'right'}],
          rows: [],
          emptyText: 'Coming in Phase 2',
        })}
      </div>
    `;
  },
};


/* ── Cost Intelligence ── */

App.pages.cost = {
  render() {
    const el = document.getElementById('page-cost');
    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Overview')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Cost', value: '—', accent: 'brand' }),
        D.kpi({ label: 'Cost Today', value: '—', accent: 'warning' }),
        D.kpi({ label: 'Cost per Explanation', value: '—' }),
        D.kpi({ label: 'Cost per Active User', value: '—', accent: 'info' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Cost Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Daily Cost', placeholder: 'Coming in Phase 2' }),
          D.chartCard({ title: 'Cost per Explanation Trend', placeholder: 'Coming in Phase 2' }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.table({
          title: 'Cost by Provider',
          headers: ['Provider', {label: 'Total Cost', align: 'right'}, {label: 'Requests', align: 'right'}, {label: 'Cost/Request', align: 'right'}],
          rows: [],
          emptyText: 'Coming in Phase 2',
        })}
      </div>
    `;
  },
};


/* ── Settings ── */

App.pages.settings = {
  render() {
    const el = document.getElementById('page-settings');
    el.innerHTML = `
      ${D.sectionHeader('Dashboard')}
      <div class="d-chart-card">
        <div style="padding: var(--d-sp-6)">
          <h3 style="font-size:14px; font-weight:600; margin-bottom:var(--d-sp-4); color:var(--d-text-0)">Dashboard Settings</h3>
          <p style="font-size:13px; color:var(--d-text-2); margin-bottom:var(--d-sp-6)">
            Configuration options will be available in a future milestone.
          </p>

          <div style="margin-bottom:var(--d-sp-5)">
            <label style="display:block; font-size:12px; font-weight:600; color:var(--d-text-2); margin-bottom:var(--d-sp-2)">API Connection</label>
            <div class="d-flex d-items-center" style="gap:var(--d-sp-2)">
              ${D.badge('Connected', 'success', true)}
              <span style="font-size:12px; color:var(--d-text-3)">Reading from Analytics v2 API</span>
            </div>
          </div>

          <div style="margin-bottom:var(--d-sp-5)">
            <label style="display:block; font-size:12px; font-weight:600; color:var(--d-text-2); margin-bottom:var(--d-sp-2)">Keyboard Shortcuts</label>
            <div style="font-size:12px; color:var(--d-text-3); line-height:2">
              <kbd class="d-kbd">&#x2318;K</kbd> Search &nbsp;&nbsp;
              <kbd class="d-kbd">R</kbd> Refresh &nbsp;&nbsp;
              <kbd class="d-kbd">1-4</kbd> Date presets &nbsp;&nbsp;
              <kbd class="d-kbd">Esc</kbd> Close panels
            </div>
          </div>

          <div style="margin-bottom:var(--d-sp-5)">
            <label style="display:block; font-size:12px; font-weight:600; color:var(--d-text-2); margin-bottom:var(--d-sp-2)">Old Dashboard</label>
            <a href="/admin" style="font-size:12px; color:var(--d-brand); text-decoration:none">Open v1 Dashboard &#x2197;</a>
          </div>

          <div>
            <label style="display:block; font-size:12px; font-weight:600; color:var(--d-text-2); margin-bottom:var(--d-sp-2)">Session</label>
            <button class="d-btn d-btn-sm" onclick="App.logout()">Sign Out</button>
          </div>
        </div>
      </div>
    `;
  },
};


/* ── Initialize on DOM ready ── */
document.addEventListener('DOMContentLoaded', () => App.init());
