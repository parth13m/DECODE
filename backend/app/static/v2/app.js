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
    feedback:   { title: 'Feedback',               subtitle: 'User satisfaction analytics' },
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
      const [exec, quality, aiPlatform, cost, timeline, founder] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
        D.api.fetch(D.api.url('/api/v2/analytics/quality')),
        D.api.fetch(D.api.url('/api/v2/analytics/ai-platform')),
        D.api.fetch(D.api.url('/api/v2/analytics/cost')),
        D.api.fetch(D.api.url('/api/v2/analytics/timeline', { limit: 15 })),
        D.api.fetch('/api/admin/analytics/founder').catch(() => null),
      ]);

      this._lastData = { exec, quality, aiPlatform, cost, timeline, founder };
      this._renderLive(el, exec, quality, aiPlatform, cost, timeline, founder);
    } catch (err) {
      el.innerHTML = `
        ${D.globalFilterBar()}
        ${D.error('Failed to load executive data', err.message, "App.pages.executive.render()")}`;
    }
  },

  _renderLive(el, exec, quality, aiPlatform, cost, timeline, founder) {
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

      ${founder ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Founder Intelligence')}

          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            <h4 style="margin:0 0 16px;font-size:0.85rem;font-weight:600">Activation Funnel</h4>
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
              D.kpi({ label: 'Avg TTFV', value: founder.time_to_first_value.average_seconds != null ? D.fmt.latency(founder.time_to_first_value.average_seconds * 1000) : '\u2014', sub: 'Time to First Value', accent: 'brand' }),
              D.kpi({ label: 'Median TTFV', value: founder.time_to_first_value.median_seconds != null ? D.fmt.latency(founder.time_to_first_value.median_seconds * 1000) : '\u2014', sub: D.fmt.num(founder.time_to_first_value.sample_size) + ' users sampled', accent: 'info' }),
              D.kpi({ label: 'Cost/User (7d)', value: founder.cost_per_active_user.last_7d != null ? D.fmt.usd(founder.cost_per_active_user.last_7d) : '\u2014', sub: D.fmt.num(founder.cost_per_active_user.active_users_7d) + ' active users', accent: 'warning' }),
              D.kpi({ label: 'Cost/User (All)', value: founder.cost_per_active_user.all_time != null ? D.fmt.usd(founder.cost_per_active_user.all_time) : '\u2014', sub: D.fmt.num(founder.cost_per_active_user.active_users_all_time) + ' total users', accent: 'success' }),
            ], 4)}
          </div>

          ${founder.slowest_requests && founder.slowest_requests.length > 0 ? `
            <div class="d-mt-4">
              ${D.table({
                title: 'Slowest Requests (Top 10)',
                headers: ['User', 'Mode', { label: 'Latency', align: 'right' }, 'Provider', 'Status', 'Time'],
                rows: founder.slowest_requests.slice(0, 10).map(r => ({
                  cells: [
                    D.fmt.escapeHtml(r.user_name || r.user_email || '\u2014'),
                    D.badge(r.mode || '\u2014', 'neutral'),
                    D.fmt.latency(r.latency_ms),
                    r.ai_provider ? D.badge(r.ai_provider, 'info') : '\u2014',
                    r.success ? D.badge('OK', 'success') : D.badge('FAIL', 'danger'),
                    D.fmt.timeAgo(r.created_at),
                  ],
                })),
              })}
            </div>
          ` : ''}

          ${founder.language_analytics && founder.language_analytics.length > 0 ? `
            <div class="d-mt-4">
              ${D.table({
                title: 'Language Analytics',
                headers: ['Language', { label: 'Requests', align: 'right' }, { label: 'Success', align: 'right' }, { label: 'Avg Latency', align: 'right' }, { label: 'Cost', align: 'right' }],
                rows: founder.language_analytics.slice(0, 15).map(l => ({
                  cells: [
                    `<strong>${D.fmt.escapeHtml(l.language)}</strong>`,
                    D.fmt.num(l.request_count),
                    D.badge(D.fmt.pct(l.success_rate), l.success_rate >= 95 ? 'success' : 'warning'),
                    D.fmt.latency(l.avg_latency_ms),
                    D.fmt.usd(l.estimated_cost_usd),
                  ],
                })),
              })}
            </div>
          ` : ''}
        </div>
      ` : ''}
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


/* ═══════════════════════════════════════════════════════════
   PRODUCT INTELLIGENCE — Live Data
   ═══════════════════════════════════════════════════════════ */

App.pages.product = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-product');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Feature Adoption')}
      ${D.kpiLoading(4, 4)}
      <div class="d-mt-6">${D.kpiLoading(4, 4)}</div>
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Mode Distribution')}
        ${D.chartLoading(2, 2)}
      </div>`;

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
    const profiles = product.by_profile || [];
    const languages = product.by_language || [];
    const totalReqs = exec.total_requests || 0;

    // Find mode counts
    const modeMap = {};
    modes.forEach(m => modeMap[m.mode] = m);
    const sel = modeMap['selection'] || { count: 0, users: 0 };
    const ses = modeMap['session'] || { count: 0, users: 0 };
    const scr = modeMap['screenshot'] || { count: 0, users: 0 };

    // Find type counts
    const typeMap = {};
    types.forEach(t => typeMap[t.request_type] = t);
    const explains = (typeMap['explain'] || { count: 0 }).count;
    const followups = (typeMap['followup'] || { count: 0 }).count;
    const improves = (typeMap['improve'] || { count: 0 }).count;
    const visions = (typeMap['vision'] || { count: 0 }).count;

    const followupRate = explains > 0 ? (followups / explains * 100) : 0;
    const improveRate = explains > 0 ? (improves / explains * 100) : 0;
    const visionRate = totalReqs > 0 ? (visions / totalReqs * 100) : 0;

    // Colors for modes/types
    const modeColors = { selection: '#e87830', session: '#3b82f6', screenshot: '#8b5cf6', unknown: '#6b7280' };
    const typeColors = { explain: '#e87830', followup: '#3b82f6', improve: '#10b981', vision: '#8b5cf6', enrichment: '#f59e0b', unknown: '#6b7280' };

    const modeSegments = modes.map(m => ({ label: m.mode, value: m.count, color: modeColors[m.mode] || '#6b7280' }));
    const typeSegments = types.map(t => ({ label: t.request_type, value: t.count, color: typeColors[t.request_type] || '#6b7280' }));

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Feature Adoption')}
      ${D.kpiGrid([
        D.kpi({ label: 'Selection Mode', value: D.fmt.num(sel.count), sub: `${D.fmt.num(sel.users)} users`, accent: 'brand' }),
        D.kpi({ label: 'Session Mode', value: D.fmt.num(ses.count), sub: `${D.fmt.num(ses.users)} users`, accent: 'info' }),
        D.kpi({ label: 'Screenshot Mode', value: D.fmt.num(scr.count), sub: `${D.fmt.num(scr.users)} users`, accent: 'purple' }),
        D.kpi({ label: 'Follow-up Rate', value: D.fmt.pct(followupRate), sub: `${D.fmt.num(followups)} follow-ups`, accent: followupRate > 20 ? 'success' : 'warning' }),
      ], 4)}

      <div class="d-mt-6">
        ${D.kpiGrid([
          D.kpi({ label: 'Explanations', value: D.fmt.num(explains), sub: 'Total explain requests', accent: 'brand' }),
          D.kpi({ label: 'Improve Rate', value: D.fmt.pct(improveRate), sub: `${D.fmt.num(improves)} improvements`, accent: 'success' }),
          D.kpi({ label: 'Vision Requests', value: D.fmt.num(visions), sub: D.fmt.pct(visionRate) + ' of total', accent: 'purple' }),
          D.kpi({ label: 'Active Users', value: D.fmt.num(exec.unique_users), sub: 'Across all modes', accent: 'info' }),
        ], 4)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Mode Distribution')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests by Mode', canvasId: 'product-donut-mode', height: 260, placeholder: false }),
          D.chartCard({ title: 'Requests by Type', canvasId: 'product-donut-type', height: 260, placeholder: false }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Mode Adoption', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.product._drillDownModes()">View details</button>`)}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          ${D.horizontalBars(modes.map(m => ({
            label: m.mode,
            value: m.count,
            color: modeColors[m.mode] || '#6b7280',
          })))}
        </div>
      </div>

      ${profiles.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Explanation Profiles')}
          ${D.table({
            title: 'Profile Comparison',
            headers: ['Profile', { label: 'Requests', align: 'right' }, { label: '% of Total', align: 'right' }],
            rows: profiles.map(p => ({
              cells: [
                `<strong>${D.fmt.escapeHtml(p.profile)}</strong>`,
                D.fmt.num(p.count),
                D.fmt.pct(totalReqs > 0 ? (p.count / totalReqs * 100) : 0),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${languages.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Language Distribution')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(languages.slice(0, 10).map((l, i) => ({
              label: l.language,
              value: l.count,
              color: ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b','#ef4444','#06b6d4','#f97316','#84cc16','#ec4899'][i % 10],
            })))}
          </div>
        </div>
      ` : ''}

      ${(improve && improve.total_outcomes > 0) ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Improve Code Analytics')}
          ${D.kpiGrid([
            D.kpi({ label: 'Improve Requests', value: D.fmt.num(improve.improve_requests), sub: improve.adoption_rate !== null ? D.fmt.pct(improve.adoption_rate) + ' adoption' : 'No explanations', accent: 'brand' }),
            D.kpi({ label: 'Acceptance Rate', value: improve.acceptance_rate !== null ? D.fmt.pct(improve.acceptance_rate) : '\u2014', sub: D.fmt.num(improve.copy_count + improve.replace_count) + ' accepted', accent: 'success' }),
            D.kpi({ label: 'No Change Rate', value: improve.no_change_rate !== null ? D.fmt.pct(improve.no_change_rate) : '\u2014', sub: D.fmt.num(improve.no_change_count) + ' already clean', accent: 'info' }),
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

          ${improve.replace_failure_count > 0 ? `
            <div class="d-mt-3">
              ${D.statRow([
                { label: 'Replace Failures', value: D.fmt.num(improve.replace_failure_count), color: 'var(--d-danger)' },
                { label: 'Replace Failure Rate', value: improve.replace_failure_rate !== null ? D.fmt.pct(improve.replace_failure_rate) : '\u2014' },
              ])}
            </div>
          ` : ''}

          ${(improve.daily_trend || []).length > 0 ? `
            <div class="d-mt-4">
              ${D.chartCard({ title: 'Improve Outcome Trend', canvasId: 'improve-trend-chart', height: 200, placeholder: false })}
            </div>
          ` : ''}
        </div>
      ` : ''}

      ${(history && (history.history_opens > 0 || history.history_followups > 0)) ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('History Analytics')}
          ${D.kpiGrid([
            D.kpi({ label: 'History Users', value: D.fmt.num(history.history_users), sub: history.adoption !== null ? D.fmt.pct(history.adoption) + ' adoption' : 'No active users', accent: 'brand' }),
            D.kpi({ label: 'History Opens', value: D.fmt.num(history.history_opens), accent: 'info' }),
            D.kpi({ label: 'History Follow-Ups', value: D.fmt.num(history.history_followups), sub: history.followup_rate !== null ? D.fmt.pct(history.followup_rate) + ' rate' : '', accent: 'success' }),
            D.kpi({ label: 'History Clears', value: D.fmt.num(history.history_clears), accent: 'warning' }),
          ], 4)}

          <div class="d-mt-4">
            ${D.kpiGrid([
              D.kpi({ label: 'Avg Depth', value: history.avg_depth !== null ? history.avg_depth : '\u2014' }),
              D.kpi({ label: 'Avg Follow-Ups / Open', value: history.avg_followups_per_open !== null ? history.avg_followups_per_open : '\u2014' }),
            ], 2)}
          </div>

          ${Object.keys(history.depth_distribution || {}).length > 0 ? `
            <div class="d-mt-4">
              <div class="d-chart-card" style="padding:var(--d-sp-5)">
                <h4 style="margin:0 0 12px;font-size:0.85rem;font-weight:600">Follow-Up Depth Distribution</h4>
                ${D.horizontalBars(Object.entries(history.depth_distribution).sort((a,b) => parseInt(a[0]) - parseInt(b[0])).map((e, i) => ({
                  label: 'Depth ' + e[0],
                  value: e[1],
                  color: ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b'][i % 5],
                })))}
              </div>
            </div>
          ` : ''}

          ${Object.keys(history.selection_source || {}).length > 0 ? `
            <div class="d-mt-4">
              <div class="d-chart-card" style="padding:var(--d-sp-5)">
                <h4 style="margin:0 0 12px;font-size:0.85rem;font-weight:600">Selection Source</h4>
                ${D.horizontalBars(Object.entries(history.selection_source).map((e, i) => {
                  const labels = { explanation: 'Explanation', followup_question: 'Follow-Up Question', followup_answer: 'Follow-Up Answer' };
                  return { label: labels[e[0]] || e[0], value: e[1], color: ['#e87830','#3b82f6','#10b981'][i % 3] };
                }))}
              </div>
            </div>
          ` : ''}

          ${(history.daily_trend || []).length > 0 ? `
            <div class="d-mt-4">
              ${D.chartCard({ title: 'History Usage Trend', canvasId: 'history-trend-chart', height: 200, placeholder: false })}
            </div>
          ` : ''}
        </div>
      ` : ''}

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('executive')">&#x2190; Executive Overview</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('ai')">AI Platform &#x2192;</button>
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
      const typeTotal = typeSegments.reduce((s, x) => s + x.value, 0);
      const typeCanvas = document.getElementById('product-donut-type');
      if (typeCanvas && typeSegments.length) {
        const body = typeCanvas.closest('.d-chart-body');
        body.innerHTML = `<div class="d-donut-wrap"><canvas id="product-donut-type" style="width:180px;height:180px"></canvas>${D.donutLegend(typeSegments, typeTotal)}</div>`;
        D.renderDonutChart('product-donut-type', typeSegments, { height: 180, centerLabel: D.fmt.num(typeTotal), centerSub: 'requests' });
      }

      // Improve trend chart
      const improveTrendCanvas = document.getElementById('improve-trend-chart');
      if (improveTrendCanvas && improve && (improve.daily_trend || []).length > 0) {
        const trend = improve.daily_trend;
        const body = improveTrendCanvas.closest('.d-chart-body');
        body.innerHTML = `<canvas id="improve-trend-chart" style="width:100%;height:200px"></canvas>`;
        D.renderAreaChart('improve-trend-chart', {
          labels: trend.map(d => d.date),
          datasets: [
            { label: 'Copy', data: trend.map(d => d.copies), color: '#10b981' },
            { label: 'Replace', data: trend.map(d => d.replaces), color: '#3b82f6' },
            { label: 'Dismiss', data: trend.map(d => d.dismissals), color: '#f59e0b' },
            { label: 'No Change', data: trend.map(d => d.no_changes), color: '#6b7280' },
          ],
        }, { height: 200 });
      }

      // History trend chart
      const historyTrendCanvas = document.getElementById('history-trend-chart');
      if (historyTrendCanvas && history && (history.daily_trend || []).length > 0) {
        const trend = history.daily_trend;
        const body = historyTrendCanvas.closest('.d-chart-body');
        body.innerHTML = `<canvas id="history-trend-chart" style="width:100%;height:200px"></canvas>`;
        D.renderAreaChart('history-trend-chart', {
          labels: trend.map(d => d.date),
          datasets: [
            { label: 'Opens', data: trend.map(d => d.opens), color: '#e87830' },
            { label: 'Follow-Ups', data: trend.map(d => d.followups), color: '#3b82f6' },
            { label: 'Clears', data: trend.map(d => d.clears), color: '#ef4444' },
          ],
        }, { height: 200 });
      }
    });
  },

  _drillDownModes() {
    if (!this._lastData) return;
    const modes = this._lastData.product.by_mode || [];
    D.drillDown.open('Mode Details', `
      <div style="margin-bottom:16px">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(modes))}')), 'modes.json')">Export JSON</button>
        <button class="d-btn d-btn-sm" style="margin-left:8px" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(modes))}')), 'modes.csv', 'csv')">Export CSV</button>
      </div>
      ${D.table({
        headers: ['Mode', { label: 'Requests', align: 'right' }, { label: 'Users', align: 'right' }, { label: 'Avg Latency', align: 'right' }],
        rows: modes.map(m => ({ cells: [m.mode, D.fmt.num(m.count), D.fmt.num(m.users), D.fmt.latency(m.avg_latency_ms)] })),
      })}
    `);
  },
};


/* ═══════════════════════════════════════════════════════════
   AI PLATFORM — Live Data
   ═══════════════════════════════════════════════════════════ */

App.pages.ai = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-ai');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Platform Health')}
      ${D.kpiLoading(4, 4)}
      <div class="d-section d-mt-6">${D.sectionHeader('Token Consumption')}${D.kpiLoading(4, 4)}</div>
      <div class="d-section d-mt-6">${D.sectionHeader('Providers')}${D.chartLoading(2, 2)}</div>
      <div class="d-section d-mt-6">${D.sectionHeader('Models')}${D.tableLoading(6)}</div>`;

    try {
      const [ai, quality, live, tokens] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/ai-platform')),
        D.api.fetch(D.api.url('/api/v2/analytics/quality')),
        D.api.fetch(D.api.url('/api/v2/analytics/live', { minutes: 60 })),
        D.api.fetch(D.api.url('/api/v2/analytics/token-breakdown')),
      ]);
      this._lastData = { ai, quality, live, tokens };
      this._renderLive(el, ai, quality, live, tokens);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load AI platform data', err.message, "App.pages.ai.render()")}`;
    }
  },

  _renderLive(el, ai, quality, live, tokens) {
    const providers = ai.by_provider || [];
    const models = ai.by_model || [];
    const errors = ai.errors || [];
    const lat = quality.latency || {};

    const totalReqs = providers.reduce((s, p) => s + p.count, 0);
    const totalSuccess = providers.reduce((s, p) => s + p.successful, 0);
    const successRate = totalReqs > 0 ? (totalSuccess / totalReqs * 100) : 0;

    const provColors = p => {
      if (p.includes('anthropic')) return '#e87830';
      if (p.includes('groq')) return '#3b82f6';
      if (p.includes('openai')) return '#10b981';
      return '#8b5cf6';
    };

    const provSegments = providers.map(p => ({ label: p.provider, value: p.count, color: provColors(p.provider) }));

    // Daily quality trend for stacked chart
    const dailyTrend = quality.daily_trend || [];
    const dailyLabels = dailyTrend.map(d => D.fmt.dateShort(d.date));
    const dailySuccess = dailyTrend.map(d => d.successful);
    const dailyFailed = dailyTrend.map(d => d.total - d.successful);

    // Token breakdown data
    const byMode = tokens.by_mode || [];
    const byType = tokens.by_request_type || [];
    const byProfile = tokens.by_profile || [];
    const byFeature = tokens.by_feature || [];
    const tokenDaily = tokens.daily_trend || [];
    const topUsers = tokens.top_users || [];
    const tokenDist = tokens.token_distribution;
    const featureByProvider = tokens.feature_by_provider || [];
    const featureByModel = tokens.feature_by_model || [];
    const vision = tokens.vision || {};
    const dsa = tokens.dsa || {};

    // Token totals across all modes
    const totalPrompt = byMode.reduce((s, m) => s + (m.prompt_tokens || 0), 0);
    const totalCompletion = byMode.reduce((s, m) => s + (m.completion_tokens || 0), 0);
    const totalTokens = byMode.reduce((s, m) => s + (m.total_tokens || 0), 0);
    const totalCost = byMode.reduce((s, m) => s + (m.total_cost_usd || 0), 0);

    // Token donut segments by mode
    const modeTokenColors = { selection: '#e87830', session: '#3b82f6', screenshot: '#8b5cf6', unknown: '#6b7280' };
    const modeTokenSegs = byMode.filter(m => m.total_tokens > 0).map(m => ({
      label: m.key, value: m.total_tokens, color: modeTokenColors[m.key] || '#6b7280',
    }));

    // Token donut segments by type
    const typeTokenColors = { explain: '#e87830', followup: '#3b82f6', improve: '#10b981', vision: '#8b5cf6', enrichment: '#f59e0b', unknown: '#6b7280' };
    const typeTokenSegs = byType.filter(t => t.total_tokens > 0).map(t => ({
      label: t.key, value: t.total_tokens, color: typeTokenColors[t.key] || '#6b7280',
    }));

    // Feature colors
    const featureColors = {
      selection: '#e87830', session: '#3b82f6', session_followup: '#06b6d4',
      session_improve: '#10b981', selection_followup: '#f97316', screenshot: '#8b5cf6',
      vision: '#ec4899', enrichment: '#f59e0b', other: '#6b7280',
    };
    const featureLabel = k => k.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());

    // Feature cost donut
    const featureCostSegs = byFeature.filter(f => f.total_cost_usd > 0).map(f => ({
      label: featureLabel(f.key), value: f.total_cost_usd, color: featureColors[f.key] || '#6b7280',
    }));

    // Vision / DSA section data
    const visionTotals = vision.totals;
    const hasVision = visionTotals && visionTotals.requests > 0;
    const dsaTotals = dsa.totals;
    const hasDSA = dsaTotals && dsaTotals.requests > 0;

    // Forecast calculations
    const numDays = tokenDaily.length || 1;
    const avgDailyReqs = totalReqs / numDays;
    const avgDailyCost = totalCost / numDays;
    const avgDailyTokens = totalTokens / numDays;
    const avgTokensPerReq = totalReqs > 0 ? totalTokens / totalReqs : 0;
    const costPer100 = totalReqs > 0 ? (totalCost / totalReqs) * 100 : 0;
    const costPer1000 = costPer100 * 10;
    const estMonthlyCost = avgDailyCost * 30;
    const estMonthlyTokens = avgDailyTokens * 30;

    // Token daily trend data
    const tdLabels = tokenDaily.map(d => D.fmt.dateShort(d.date));
    const tdPrompt = tokenDaily.map(d => d.prompt_tokens);
    const tdCompletion = tokenDaily.map(d => d.completion_tokens);
    const tdTotal = tokenDaily.map(d => d.total_tokens);
    const tdCost = tokenDaily.map(d => d.cost_usd);
    const tdReqs = tokenDaily.map(d => d.requests);

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Platform Health')}
      ${D.kpiGrid([
        D.kpi({ label: 'Total Requests', value: D.fmt.num(totalReqs), accent: 'brand' }),
        D.kpi({ label: 'Success Rate', value: D.fmt.pct(successRate), accent: successRate >= 95 ? 'success' : 'warning' }),
        D.kpi({ label: 'p50 Latency', value: D.fmt.latency(lat.p50_ms), sub: 'Median response time' }),
        D.kpi({ label: 'p95 Latency', value: D.fmt.latency(lat.p95_ms), sub: 'p99: ' + D.fmt.latency(lat.p99_ms), accent: lat.p95_ms > 5000 ? 'danger' : 'warning' }),
      ], 4)}

      <div class="d-mt-6">
        ${D.kpiGrid([
          D.kpi({ label: 'Min Latency', value: D.fmt.latency(lat.min_ms), accent: 'success' }),
          D.kpi({ label: 'Max Latency', value: D.fmt.latency(lat.max_ms), accent: 'danger' }),
          D.kpi({ label: 'Avg Latency', value: D.fmt.latency(lat.avg_ms) }),
          D.kpi({ label: 'Live (1h)', value: D.fmt.num(live.stats?.total_requests || 0), sub: D.fmt.pct(live.stats?.success_rate) + ' success', accent: 'info' }),
        ], 4)}
      </div>

      <!-- ═══ TOKEN CONSUMPTION OVERVIEW ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Consumption Overview', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownTokens()">Export</button>`)}
        ${D.kpiGrid([
          D.kpi({ label: 'Total Input Tokens', value: D.fmt.num(totalPrompt), accent: 'brand' }),
          D.kpi({ label: 'Total Output Tokens', value: D.fmt.num(totalCompletion), accent: 'info' }),
          D.kpi({ label: 'Total Tokens', value: D.fmt.num(totalTokens), accent: 'purple' }),
          D.kpi({ label: 'Total Token Cost', value: D.fmt.usdCompact(totalCost), accent: 'warning' }),
        ], 4)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Distribution')}
        ${D.chartGrid([
          D.chartCard({ title: 'Tokens by Mode', canvasId: 'ai-donut-mode-tokens', height: 260, placeholder: false }),
          D.chartCard({ title: 'Tokens by Request Type', canvasId: 'ai-donut-type-tokens', height: 260, placeholder: false }),
        ], 2)}
      </div>

      <!-- ═══ 1. TOKEN EFFICIENCY BY FEATURE ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Efficiency by Feature', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownFeatureEfficiency()">Details</button>`)}
        ${byFeature.length > 0 ? D.table({
          headers: [
            'Feature',
            { label: 'Requests', align: 'right' },
            { label: 'Avg In', align: 'right' },
            { label: 'Avg Out', align: 'right' },
            { label: 'Out/In Ratio', align: 'right' },
            { label: 'Avg Cost', align: 'right' },
            { label: 'Avg Latency', align: 'right' },
          ],
          rows: byFeature.map(f => {
            const ratio = f.avg_prompt_tokens > 0 ? f.avg_completion_tokens / f.avg_prompt_tokens : 0;
            const ratioColor = ratio > 1.5 ? 'var(--d-danger)' : ratio > 0.8 ? 'var(--d-warning)' : 'var(--d-success)';
            return {
              clickable: true,
              onclick: `App.pages.ai._drillDownFeature('${D.fmt.escapeHtml(f.key)}')`,
              cells: [
                `<strong style="color:${featureColors[f.key] || '#6b7280'}">${featureLabel(f.key)}</strong>`,
                D.fmt.num(f.requests),
                D.fmt.num(f.avg_prompt_tokens),
                D.fmt.num(f.avg_completion_tokens),
                `<span style="color:${ratioColor};font-weight:600">${ratio.toFixed(2)}x</span>`,
                D.fmt.usd(f.avg_cost_usd, 4),
                D.fmt.latency(f.avg_latency_ms),
              ],
            };
          }),
        }) : D.empty(null, 'No feature data')}
      </div>

      <!-- ═══ 2. COST PER FEATURE ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Cost per Feature')}
        ${D.chartGrid([
          D.chartCard({ title: 'Cost by Feature', canvasId: 'ai-donut-feature-cost', height: 260, placeholder: false }),
          `<div class="d-chart-card">${D.table({
            headers: [
              'Feature',
              { label: 'Cost', align: 'right' },
              { label: 'Requests', align: 'right' },
              { label: 'Avg Cost', align: 'right' },
              { label: 'Cost %', align: 'right' },
              { label: 'Tokens', align: 'right' },
            ],
            rows: byFeature.filter(f => f.total_cost_usd > 0).sort((a, b) => b.total_cost_usd - a.total_cost_usd).map(f => ({
              cells: [
                `<strong style="color:${featureColors[f.key] || '#6b7280'}">${featureLabel(f.key)}</strong>`,
                D.fmt.usd(f.total_cost_usd),
                D.fmt.num(f.requests),
                D.fmt.usd(f.avg_cost_usd, 4),
                D.fmt.pct(totalCost > 0 ? (f.total_cost_usd / totalCost * 100) : 0),
                D.fmt.num(f.total_tokens),
              ],
            })),
            emptyText: 'No cost data',
          })}</div>`,
        ], 2)}
      </div>

      <!-- ═══ 3. TOKEN TRENDS ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Trends')}
        ${D.chartGrid([
          D.chartCard({ title: 'Daily Input vs Output Tokens', canvasId: 'ai-trend-in-out', height: 220 }),
          D.chartCard({ title: 'Daily Total Tokens', canvasId: 'ai-trend-total', height: 220 }),
        ], 2)}
        <div class="d-mt-4">
          ${D.chartGrid([
            D.chartCard({ title: 'Daily Token Cost', canvasId: 'ai-trend-cost', height: 220 }),
            D.chartCard({ title: 'Daily Requests', canvasId: 'ai-trend-reqs', height: 220 }),
          ], 2)}
        </div>
      </div>

      <!-- ═══ 5. TOKEN DISTRIBUTION (PERCENTILES) ═══ -->
      ${tokenDist ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Distribution (Percentiles)')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:24px">
              ${D.percentileCard('Input Tokens', tokenDist.prompt, { color: '#3b82f6' })}
              ${D.percentileCard('Output Tokens', tokenDist.completion, { color: '#10b981' })}
            </div>
          </div>
        </div>
      ` : ''}

      <!-- ═══ 6. PROMPT VS COMPLETION RATIO ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Input vs Output Ratio by Feature')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          ${D.ratioBarList(byFeature.filter(f => f.total_tokens > 0).map(f => ({
            label: featureLabel(f.key),
            input: f.prompt_tokens,
            output: f.completion_tokens,
          })))}
        </div>
      </div>

      <!-- ═══ 7. FORECAST METRICS ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Forecast Metrics', `<span class="d-text-dim" style="font-size:11px">Based on ${D.fmt.num(numDays)}-day average</span>`)}
        ${D.kpiGrid([
          D.kpi({ label: 'Cost / 100 Reqs', value: D.fmt.usd(costPer100), accent: 'warning' }),
          D.kpi({ label: 'Cost / 1,000 Reqs', value: D.fmt.usd(costPer1000), accent: 'warning' }),
          D.kpi({ label: 'Avg Tokens / Req', value: D.fmt.num(Math.round(avgTokensPerReq)), accent: 'purple' }),
          D.kpi({ label: 'Est. Monthly Cost', value: D.fmt.usdCompact(estMonthlyCost), sub: D.fmt.usd(avgDailyCost) + '/day', accent: 'danger' }),
        ], 4)}
        <div class="d-mt-4">
          ${D.kpiGrid([
            D.kpi({ label: 'Est. Monthly Tokens', value: D.fmt.num(Math.round(estMonthlyTokens)), sub: D.fmt.num(Math.round(avgDailyTokens)) + '/day' }),
            D.kpi({ label: 'Avg Daily Requests', value: D.fmt.num(Math.round(avgDailyReqs)) }),
            D.kpi({ label: 'Avg Daily Cost', value: D.fmt.usd(avgDailyCost) }),
            D.kpi({ label: 'Input/Output Split', value: totalTokens > 0 ? D.fmt.pct(totalPrompt / totalTokens * 100, 0) + ' / ' + D.fmt.pct(totalCompletion / totalTokens * 100, 0) : '—', sub: 'Input / Output' }),
          ], 4)}
        </div>
      </div>

      <!-- ═══ 4. TOP CONSUMERS ═══ -->
      ${topUsers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Top Consumers', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._exportTopUsers()">Export</button>`)}
          ${D.table({
            headers: [
              'User',
              { label: 'Requests', align: 'right' },
              { label: 'Input Tok', align: 'right' },
              { label: 'Output Tok', align: 'right' },
              { label: 'Total Tok', align: 'right' },
              { label: 'Cost', align: 'right' },
            ],
            rows: topUsers.map(u => ({
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

      ${providers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Top Providers by Tokens')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(providers.filter(p => p.prompt_tokens + p.completion_tokens > 0).sort((a, b) => (b.prompt_tokens + b.completion_tokens) - (a.prompt_tokens + a.completion_tokens)).map(p => ({
              label: p.provider + ' (' + D.fmt.usd(p.total_cost_usd) + ')',
              value: p.prompt_tokens + p.completion_tokens,
              color: provColors(p.provider),
            })))}
          </div>
        </div>
      ` : ''}

      ${models.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Top Models by Tokens')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(models.filter(m => m.prompt_tokens + m.completion_tokens > 0).sort((a, b) => (b.prompt_tokens + b.completion_tokens) - (a.prompt_tokens + a.completion_tokens)).slice(0, 8).map(m => ({
              label: m.model.split('/').pop() + ' (' + D.fmt.usd(m.total_cost_usd) + ')',
              value: m.prompt_tokens + m.completion_tokens,
              color: '#8b5cf6',
            })))}
          </div>
        </div>
      ` : ''}

      <!-- ═══ TOKEN BREAKDOWN TABLES (EXISTING) ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Breakdown by Mode', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownModeTokens()">Details</button>`)}
        ${D.tokenBreakdownTable(byMode, { labelHeader: 'Mode' })}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Token Breakdown by Request Type')}
        ${D.tokenBreakdownTable(byType, { labelHeader: 'Request Type' })}
      </div>

      ${byProfile.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Token Breakdown by Explanation Profile')}
          ${D.tokenBreakdownTable(byProfile, { labelHeader: 'Profile' })}
        </div>
      ` : ''}

      <!-- ═══ VISION ANALYTICS ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Vision Analytics', hasVision ? `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownVision()">Details</button>` : '')}
        ${hasVision ? `
          ${D.kpiGrid([
            D.kpi({ label: 'Vision Requests', value: D.fmt.num(visionTotals.requests), accent: 'purple' }),
            D.kpi({ label: 'Input Tokens', value: D.fmt.num(visionTotals.prompt_tokens), accent: 'brand' }),
            D.kpi({ label: 'Output Tokens', value: D.fmt.num(visionTotals.completion_tokens), accent: 'info' }),
            D.kpi({ label: 'Vision Cost', value: D.fmt.usd(visionTotals.total_cost_usd), accent: 'warning' }),
          ], 4)}
          <div class="d-mt-4">
            ${D.kpiGrid([
              D.kpi({ label: 'Avg Input / Req', value: D.fmt.num(visionTotals.avg_prompt_tokens) }),
              D.kpi({ label: 'Avg Output / Req', value: D.fmt.num(visionTotals.avg_completion_tokens) }),
              D.kpi({ label: 'Success Rate', value: D.fmt.pct(visionTotals.success_rate), accent: visionTotals.success_rate >= 95 ? 'success' : 'danger' }),
              D.kpi({ label: 'Avg Latency', value: D.fmt.latency(visionTotals.avg_latency_ms) }),
            ], 4)}
          </div>
        ` : D.empty(null, 'No Vision Requests', 'Vision analytics will appear when vision requests are recorded')}
      </div>

      <!-- ═══ DSA ANALYTICS ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('DSA Analytics', hasDSA ? `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownDSA()">Details</button>` : '')}
        ${hasDSA ? `
          ${D.kpiGrid([
            D.kpi({ label: 'DSA Requests', value: D.fmt.num(dsaTotals.requests), accent: 'brand' }),
            D.kpi({ label: 'Input Tokens', value: D.fmt.num(dsaTotals.prompt_tokens), accent: 'brand' }),
            D.kpi({ label: 'Output Tokens', value: D.fmt.num(dsaTotals.completion_tokens), accent: 'info' }),
            D.kpi({ label: 'DSA Cost', value: D.fmt.usd(dsaTotals.total_cost_usd), accent: 'warning' }),
          ], 4)}
          <div class="d-mt-4">
            ${D.kpiGrid([
              D.kpi({ label: 'Avg Input / Req', value: D.fmt.num(dsaTotals.avg_prompt_tokens) }),
              D.kpi({ label: 'Avg Output / Req', value: D.fmt.num(dsaTotals.avg_completion_tokens) }),
              D.kpi({ label: 'Success Rate', value: D.fmt.pct(dsaTotals.success_rate), accent: dsaTotals.success_rate >= 95 ? 'success' : 'danger' }),
              D.kpi({ label: 'Avg Latency', value: D.fmt.latency(dsaTotals.avg_latency_ms) }),
            ], 4)}
          </div>
        ` : D.empty(null, 'No DSA Requests', 'DSA is an active explanation profile. Analytics appear when DSA requests are recorded.')}
      </div>

      <!-- ═══ 8. PROVIDER & MODEL TABLES ═══ -->
      <div class="d-section d-mt-6">
        ${D.sectionHeader('Provider Distribution')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests by Provider', canvasId: 'ai-donut-provider', height: 260, placeholder: false }),
          D.chartCard({ title: 'Success vs Failure Trend', canvasId: 'ai-stacked-trend', height: 220 }),
        ], 2)}
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Provider Performance', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.ai._drillDownProviders()">Export</button>`)}
        ${D.table({
          headers: [
            'Provider',
            { label: 'Requests', align: 'right' },
            { label: 'Success %', align: 'right' },
            { label: 'Avg Latency', align: 'right' },
            { label: 'Input Tok', align: 'right' },
            { label: 'Output Tok', align: 'right' },
            { label: 'Total Tok', align: 'right' },
            { label: 'Cost', align: 'right' },
          ],
          rows: providers.map(p => ({
            cells: [
              `<strong style="color:${provColors(p.provider)}">${D.fmt.escapeHtml(p.provider)}</strong>`,
              D.fmt.num(p.count),
              D.badge(D.fmt.pct(p.success_rate), p.success_rate >= 95 ? 'success' : p.success_rate >= 80 ? 'warning' : 'danger'),
              D.fmt.latency(p.avg_latency_ms),
              D.fmt.num(p.prompt_tokens),
              D.fmt.num(p.completion_tokens),
              D.fmt.num(p.prompt_tokens + p.completion_tokens),
              D.fmt.usd(p.total_cost_usd),
            ],
          })),
          emptyText: 'No provider data',
        })}
      </div>

      ${models.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Model Analytics')}
          ${D.table({
            headers: [
              'Model', 'Provider',
              { label: 'Requests', align: 'right' },
              { label: 'Success %', align: 'right' },
              { label: 'Input Tok', align: 'right' },
              { label: 'Output Tok', align: 'right' },
              { label: 'Avg Latency', align: 'right' },
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
                D.fmt.num(m.prompt_tokens),
                D.fmt.num(m.completion_tokens),
                D.fmt.latency(m.avg_latency_ms),
                D.fmt.usd(m.total_cost_usd),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${errors.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Error Breakdown')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(errors.map(e => ({
              label: e.error_type + ' (' + e.provider + ')',
              value: e.count,
              color: '#ef4444',
            })))}
          </div>
        </div>
      ` : ''}

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('product')">&#x2190; Product</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('quality')">Quality &#x2192;</button>
      </div>
    `;

    requestAnimationFrame(() => {
      // Token donuts
      if (modeTokenSegs.length) {
        const mtCanvas = document.getElementById('ai-donut-mode-tokens');
        if (mtCanvas) {
          const body = mtCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-mode-tokens" style="width:180px;height:180px"></canvas>${D.donutLegend(modeTokenSegs, totalTokens)}</div>`;
          D.renderDonutChart('ai-donut-mode-tokens', modeTokenSegs, { height: 180, centerLabel: D.fmt.num(totalTokens), centerSub: 'tokens' });
        }
      }
      if (typeTokenSegs.length) {
        const ttCanvas = document.getElementById('ai-donut-type-tokens');
        if (ttCanvas) {
          const body = ttCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-type-tokens" style="width:180px;height:180px"></canvas>${D.donutLegend(typeTokenSegs, totalTokens)}</div>`;
          D.renderDonutChart('ai-donut-type-tokens', typeTokenSegs, { height: 180, centerLabel: D.fmt.num(totalTokens), centerSub: 'tokens' });
        }
      }
      // Feature cost donut
      if (featureCostSegs.length) {
        const fcCanvas = document.getElementById('ai-donut-feature-cost');
        if (fcCanvas) {
          const body = fcCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-feature-cost" style="width:180px;height:180px"></canvas>${D.donutLegend(featureCostSegs, totalCost)}</div>`;
          D.renderDonutChart('ai-donut-feature-cost', featureCostSegs, { height: 180, centerLabel: D.fmt.usdCompact(totalCost), centerSub: 'total' });
        }
      }

      // Token trend charts
      if (tdLabels.length > 1) {
        D.renderMultiLineChart('ai-trend-in-out', [
          { data: tdPrompt, color: '#3b82f6', label: 'Input' },
          { data: tdCompletion, color: '#10b981', label: 'Output' },
        ], { labels: tdLabels, height: 220, yFormat: v => D.fmt.num(Math.round(v)) });
        const inOutCanvas = document.getElementById('ai-trend-in-out');
        if (inOutCanvas) {
          inOutCanvas.parentElement.insertAdjacentHTML('afterend',
            D.chartLegend([{ color: '#3b82f6', label: 'Input' }, { color: '#10b981', label: 'Output' }])
          );
        }
        D.renderAreaChart('ai-trend-total', tdTotal, { labels: tdLabels, height: 220, color: '#8b5cf6', yFormat: v => D.fmt.num(Math.round(v)) });
        D.renderAreaChart('ai-trend-cost', tdCost, { labels: tdLabels, height: 220, color: '#f59e0b', yFormat: v => D.fmt.usdCompact(v) });
        D.renderAreaChart('ai-trend-reqs', tdReqs, { labels: tdLabels, height: 220, color: '#e87830', yFormat: v => D.fmt.num(Math.round(v)) });
      }

      // Provider donut
      const provTotal = provSegments.reduce((s, x) => s + x.value, 0);
      const pCanvas = document.getElementById('ai-donut-provider');
      if (pCanvas && provSegments.length) {
        const body = pCanvas.closest('.d-chart-body');
        body.innerHTML = `<div class="d-donut-wrap"><canvas id="ai-donut-provider" style="width:180px;height:180px"></canvas>${D.donutLegend(provSegments, provTotal)}</div>`;
        D.renderDonutChart('ai-donut-provider', provSegments, { height: 180, centerLabel: D.fmt.num(provTotal), centerSub: 'requests' });
      }
      if (dailySuccess.length) {
        D.renderStackedAreaChart('ai-stacked-trend', [
          { data: dailySuccess, color: '#10b981', label: 'Success' },
          { data: dailyFailed, color: '#ef4444', label: 'Failed' },
        ], { labels: dailyLabels, height: 220 });
        const stackCanvas = document.getElementById('ai-stacked-trend');
        if (stackCanvas) {
          stackCanvas.parentElement.insertAdjacentHTML('afterend',
            D.chartLegend([{ color: '#10b981', label: 'Success' }, { color: '#ef4444', label: 'Failed' }])
          );
        }
      }
    });
  },

  _drillDownProviders() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.ai.by_provider, 'ai-providers.json');
  },

  _drillDownTokens() {
    if (!this._lastData?.tokens) return;
    D.drillDown.exportData(this._lastData.tokens, 'token-breakdown.json');
  },

  _exportTopUsers() {
    if (!this._lastData?.tokens?.top_users) return;
    D.drillDown.exportData(this._lastData.tokens.top_users, 'top-consumers.csv', 'csv');
  },

  _drillDownFeatureEfficiency() {
    if (!this._lastData?.tokens) return;
    const byFeature = this._lastData.tokens.by_feature || [];
    D.drillDown.open('Feature Efficiency Detail', `
      <div style="margin-bottom:16px">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(byFeature))}')), 'feature-efficiency.json')">Export JSON</button>
        <button class="d-btn d-btn-sm" style="margin-left:8px" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(byFeature))}')), 'feature-efficiency.csv', 'csv')">Export CSV</button>
      </div>
      ${D.tokenBreakdownTable(byFeature, { labelHeader: 'Feature' })}
    `);
  },

  _drillDownFeature(featureKey) {
    if (!this._lastData?.tokens) return;
    const f = (this._lastData.tokens.by_feature || []).find(x => x.key === featureKey);
    if (!f) return;
    const label = featureKey.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    const ratio = f.avg_prompt_tokens > 0 ? (f.avg_completion_tokens / f.avg_prompt_tokens).toFixed(2) : '—';
    // Get provider/model breakdown for this feature
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
        { label: 'Total Tokens', value: D.fmt.num(f.total_tokens) },
      ])}
      ${D.statRow([
        { label: 'Avg Input', value: D.fmt.num(f.avg_prompt_tokens) },
        { label: 'Avg Output', value: D.fmt.num(f.avg_completion_tokens) },
        { label: 'Out/In Ratio', value: ratio + 'x' },
      ])}
      ${D.statRow([
        { label: 'Total Cost', value: D.fmt.usd(f.total_cost_usd) },
        { label: 'Avg Cost/Req', value: D.fmt.usd(f.avg_cost_usd, 4) },
        { label: 'Cost %', value: D.fmt.pct(f.total_cost_usd / Math.max(1, (this._lastData.tokens.by_feature || []).reduce((s, x) => s + x.total_cost_usd, 0)) * 100) },
      ])}
      ${fpRows.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('Provider Breakdown')}
          ${D.table({
            headers: ['Provider', { label: 'Requests', align: 'right' }, { label: 'In Tok', align: 'right' }, { label: 'Out Tok', align: 'right' }, { label: 'Cost', align: 'right' }, { label: 'Success', align: 'right' }, { label: 'Latency', align: 'right' }],
            rows: fpRows.map(r => ({ cells: [
              `<strong>${D.fmt.escapeHtml(r.provider)}</strong>`,
              D.fmt.num(r.requests), D.fmt.num(r.prompt_tokens), D.fmt.num(r.completion_tokens),
              D.fmt.usd(r.cost_usd), D.fmt.pct(r.success_rate), D.fmt.latency(r.avg_latency_ms),
            ]})),
          })}
        </div>
      ` : ''}
      ${fmRows.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('Model Breakdown')}
          ${D.table({
            headers: ['Model', { label: 'Requests', align: 'right' }, { label: 'In Tok', align: 'right' }, { label: 'Out Tok', align: 'right' }, { label: 'Cost', align: 'right' }, { label: 'Success', align: 'right' }, { label: 'Latency', align: 'right' }],
            rows: fmRows.map(r => ({ cells: [
              `<span class="d-text-mono">${D.fmt.escapeHtml(r.model)}</span>`,
              D.fmt.num(r.requests), D.fmt.num(r.prompt_tokens), D.fmt.num(r.completion_tokens),
              D.fmt.usd(r.cost_usd), D.fmt.pct(r.success_rate), D.fmt.latency(r.avg_latency_ms),
            ]})),
          })}
        </div>
      ` : ''}
      <div class="d-mt-6">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify({feature: f, providers: fpRows, models: fmRows}))}')), '${featureKey}.json')">Export JSON</button>
      </div>
    `);
  },

  _drillDownModeTokens() {
    if (!this._lastData?.tokens) return;
    const byMode = this._lastData.tokens.by_mode || [];
    D.drillDown.open('Token Breakdown by Mode', `
      <div style="margin-bottom:16px">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(byMode))}')), 'tokens-by-mode.json')">Export JSON</button>
        <button class="d-btn d-btn-sm" style="margin-left:8px" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(byMode))}')), 'tokens-by-mode.csv', 'csv')">Export CSV</button>
      </div>
      ${byMode.map(m => `
        <div class="d-mt-4">
          <h4 style="font-size:14px;font-weight:600;color:var(--d-text-1);margin-bottom:8px">${D.fmt.escapeHtml(m.key)}</h4>
          ${D.statRow([
            { label: 'Requests', value: D.fmt.num(m.requests) },
            { label: 'Success Rate', value: D.fmt.pct(m.success_rate), color: m.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
            { label: 'Avg Latency', value: D.fmt.latency(m.avg_latency_ms) },
          ])}
          ${D.statRow([
            { label: 'Input Tokens', value: D.fmt.num(m.prompt_tokens) },
            { label: 'Output Tokens', value: D.fmt.num(m.completion_tokens) },
            { label: 'Total Tokens', value: D.fmt.num(m.total_tokens) },
          ])}
          ${D.statRow([
            { label: 'Avg Input', value: D.fmt.num(m.avg_prompt_tokens) },
            { label: 'Avg Output', value: D.fmt.num(m.avg_completion_tokens) },
            { label: 'Avg Total', value: D.fmt.num(m.avg_total_tokens) },
          ])}
          ${D.statRow([
            { label: 'Total Cost', value: D.fmt.usd(m.total_cost_usd) },
            { label: 'Avg Cost/Req', value: D.fmt.usd(m.avg_cost_usd, 4) },
          ])}
        </div>
      `).join('<hr style="border-color:var(--d-border);margin:12px 0">')}
    `);
  },

  _drillDownVision() {
    if (!this._lastData?.tokens?.vision) return;
    const v = this._lastData.tokens.vision;
    const t = v.totals;
    if (!t) return;
    D.drillDown.open('Vision Analytics Detail', `
      <div style="margin-bottom:16px">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(v))}')), 'vision-analytics.json')">Export JSON</button>
      </div>
      ${D.statRow([
        { label: 'Requests', value: D.fmt.num(t.requests) },
        { label: 'Success Rate', value: D.fmt.pct(t.success_rate), color: t.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
        { label: 'Avg Latency', value: D.fmt.latency(t.avg_latency_ms) },
      ])}
      ${D.statRow([
        { label: 'Input Tokens', value: D.fmt.num(t.prompt_tokens) },
        { label: 'Output Tokens', value: D.fmt.num(t.completion_tokens) },
        { label: 'Total Tokens', value: D.fmt.num(t.total_tokens) },
      ])}
      ${D.statRow([
        { label: 'Avg Input', value: D.fmt.num(t.avg_prompt_tokens) },
        { label: 'Avg Output', value: D.fmt.num(t.avg_completion_tokens) },
        { label: 'Avg Total', value: D.fmt.num(t.avg_total_tokens) },
      ])}
      ${D.statRow([
        { label: 'Total Cost', value: D.fmt.usd(t.total_cost_usd) },
        { label: 'Avg Cost/Req', value: D.fmt.usd(t.requests > 0 ? t.total_cost_usd / t.requests : 0, 4) },
      ])}
      ${v.by_provider?.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('By Provider')}
          ${D.horizontalBars(v.by_provider.map(p => ({ label: p.key, value: p.total_tokens, color: '#8b5cf6' })))}
        </div>
      ` : ''}
      ${v.by_model?.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('By Model')}
          ${D.horizontalBars(v.by_model.map(m => ({ label: m.key, value: m.total_tokens, color: '#06b6d4' })))}
        </div>
      ` : ''}
    `);
  },

  _drillDownDSA() {
    if (!this._lastData?.tokens?.dsa) return;
    const d = this._lastData.tokens.dsa;
    const t = d.totals;
    if (!t) return;
    D.drillDown.open('DSA Analytics Detail', `
      <div style="margin-bottom:16px">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(d))}')), 'dsa-analytics.json')">Export JSON</button>
      </div>
      ${D.statRow([
        { label: 'Requests', value: D.fmt.num(t.requests) },
        { label: 'Success Rate', value: D.fmt.pct(t.success_rate), color: t.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
        { label: 'Avg Latency', value: D.fmt.latency(t.avg_latency_ms) },
      ])}
      ${D.statRow([
        { label: 'Input Tokens', value: D.fmt.num(t.prompt_tokens) },
        { label: 'Output Tokens', value: D.fmt.num(t.completion_tokens) },
        { label: 'Total Tokens', value: D.fmt.num(t.total_tokens) },
      ])}
      ${D.statRow([
        { label: 'Avg Input', value: D.fmt.num(t.avg_prompt_tokens) },
        { label: 'Avg Output', value: D.fmt.num(t.avg_completion_tokens) },
        { label: 'Avg Total', value: D.fmt.num(t.avg_total_tokens) },
      ])}
      ${D.statRow([
        { label: 'Total Cost', value: D.fmt.usd(t.total_cost_usd) },
        { label: 'Avg Cost/Req', value: D.fmt.usd(t.requests > 0 ? t.total_cost_usd / t.requests : 0, 4) },
      ])}
      ${d.by_provider?.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('By Provider')}
          ${D.horizontalBars(d.by_provider.map(p => ({ label: p.key, value: p.total_tokens, color: '#e87830' })))}
        </div>
      ` : ''}
      ${d.by_model?.length ? `
        <div class="d-mt-6">
          ${D.sectionHeader('By Model')}
          ${D.horizontalBars(d.by_model.map(m => ({ label: m.key, value: m.total_tokens, color: '#3b82f6' })))}
        </div>
      ` : ''}
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
        ${D.statRow([
          { label: 'Avg Input / Req', value: m.count > 0 ? D.fmt.num(Math.round(m.prompt_tokens / m.count)) : '—' },
          { label: 'Avg Output / Req', value: m.count > 0 ? D.fmt.num(Math.round(m.completion_tokens / m.count)) : '—' },
          { label: 'Cost / Request', value: m.count > 0 ? D.fmt.usd(m.total_cost_usd / m.count, 4) : '—' },
        ])}
      </div>
      <div class="d-mt-6">
        <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(m))}')), '${model}.json')">Export JSON</button>
      </div>
    `);
  },
};


/* ═══════════════════════════════════════════════════════════
   USERS — Live Data
   ═══════════════════════════════════════════════════════════ */

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
        D.kpi({ label: 'Avg Req/User', value: totalCount > 0 ? D.fmt.num(Math.round(userList.reduce((s, u) => s + u.total_requests, 0) / userList.length)) : '—' }),
      ], 4)}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('User Activity Distribution')}
        ${D.chartGrid([
          D.chartCard({ title: 'Requests per User', canvasId: 'users-bar-requests', height: 220 }),
          D.chartCard({ title: 'Cost per User', canvasId: 'users-bar-cost', height: 220 }),
        ], 2)}
      </div>

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
            { label: 'Avg Latency', align: 'right' },
            { label: 'Cost', align: 'right' },
            'Last Active',
          ],
          rows: userList.map((u, i) => ({
            clickable: true,
            onclick: `App.pages.users._drillDownUser('${u.user_id}')`,
            cells: [
              `<div class="d-user-cell">
                <div class="d-avatar" style="background:${avatarColors[i % avatarColors.length]}">${D.fmt.initials(u.name, u.email)}</div>
                <div><div class="d-user-name">${D.fmt.escapeHtml(u.name || 'Unknown')}</div><div class="d-user-email">${D.fmt.escapeHtml(u.email || u.user_id.substring(0, 8))}</div></div>
              </div>`,
              D.fmt.num(u.total_requests),
              D.badge(D.fmt.num(u.successful_requests), u.successful_requests === u.total_requests ? 'success' : 'warning'),
              D.fmt.latency(u.avg_latency_ms),
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

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('executive')">&#x2190; Executive</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('cost')">Cost &#x2192;</button>
      </div>
    `;

    requestAnimationFrame(() => {
      if (userList.length) {
        const sorted = [...userList].sort((a, b) => b.total_requests - a.total_requests).slice(0, 12);
        D.renderBarChart('users-bar-requests', sorted.map(u => u.total_requests), {
          labels: sorted.map(u => (u.name || u.email || '').substring(0, 10) || u.user_id.substring(0, 6)),
          colors: '#e87830',
          height: 220,
          yFormat: v => D.fmt.num(Math.round(v)),
        });
        const costSorted = [...userList].sort((a, b) => (b.total_cost_usd || 0) - (a.total_cost_usd || 0)).slice(0, 12);
        D.renderBarChart('users-bar-cost', costSorted.map(u => u.total_cost_usd || 0), {
          labels: costSorted.map(u => (u.name || u.email || '').substring(0, 10) || u.user_id.substring(0, 6)),
          colors: '#f59e0b',
          height: 220,
          yFormat: v => D.fmt.usdCompact(v),
        });
      }
    });
  },

  async _drillDownUser(userId) {
    D.drillDown.open('Loading user...', D.loading());
    try {
      const detail = await D.api.fetch(D.api.url(`/api/v2/analytics/users/${userId}`, { recent_limit: 30 }));
      const u = detail.user || {};
      const recentReqs = detail.recent_requests || [];
      const dailyTrend = detail.daily_trend || [];
      const modeDetail = detail.mode_detail || [];

      D.drillDown.open(`${u.name || u.email || 'User'}`, `
        ${D.statRow([
          { label: 'Requests', value: D.fmt.num(detail.total_requests) },
          { label: 'Success Rate', value: D.fmt.pct(detail.success_rate), color: detail.success_rate >= 95 ? 'var(--d-success)' : 'var(--d-danger)' },
          { label: 'Status', value: u.status || '—' },
        ])}

        <div class="d-mt-6">
          ${D.sectionHeader('Activity Trend')}
          <div style="height:120px"><canvas id="user-drill-trend" style="width:100%;height:120px"></canvas></div>
        </div>

        ${modeDetail.length ? `
          <div class="d-mt-6">
            ${D.sectionHeader('AI Usage by Mode')}
            <div style="overflow-x:auto">
            ${D.table({
              headers: [
                'Mode',
                { label: 'Calls', align: 'right' },
                { label: 'OK', align: 'right' },
                { label: 'Fail', align: 'right' },
                { label: 'Success', align: 'right' },
                { label: 'Avg Latency', align: 'right' },
                { label: 'P95', align: 'right' },
                { label: 'In Tokens', align: 'right' },
                { label: 'Out Tokens', align: 'right' },
                { label: 'Cost', align: 'right' },
                'Provider',
                'Model',
                'Last Used',
              ],
              rows: modeDetail.map(m => ({
                cells: [
                  `<strong>${D.fmt.escapeHtml(m.display_name)}</strong>`,
                  D.fmt.num(m.total),
                  D.fmt.num(m.successful),
                  m.failed > 0 ? D.badge(String(m.failed), 'danger') : '0',
                  D.badge(D.fmt.pct(m.success_rate), m.success_rate >= 95 ? 'success' : m.success_rate >= 80 ? 'warning' : 'danger'),
                  D.fmt.latency(m.avg_latency_ms),
                  D.fmt.latency(m.p95_latency_ms),
                  D.fmt.num(m.prompt_tokens),
                  D.fmt.num(m.completion_tokens),
                  D.fmt.usd(m.estimated_cost_usd),
                  m.provider ? D.badge(m.provider, m.provider === 'groq' ? 'info' : 'neutral') : '—',
                  m.model ? `<span style="font-size:11px;opacity:0.8">${D.fmt.escapeHtml(m.model)}</span>` : '—',
                  m.last_used ? D.fmt.timeAgo(m.last_used) : '—',
                ],
              })),
            })}
            </div>
          </div>
        ` : ''}

        ${detail.improve_breakdown ? `
          <div class="d-mt-6">
            ${D.sectionHeader('Improve Code')}
            ${D.statRow([
              { label: 'Improve Requests', value: D.fmt.num(detail.improve_breakdown.improve_requests) },
              { label: 'Acceptance Rate', value: detail.improve_breakdown.acceptance_rate !== null ? D.fmt.pct(detail.improve_breakdown.acceptance_rate) : '\u2014', color: 'var(--d-success)' },
              { label: 'No Change Rate', value: detail.improve_breakdown.no_change_rate !== null ? D.fmt.pct(detail.improve_breakdown.no_change_rate) : '\u2014' },
            ])}
            <div class="d-mt-3">
              ${D.horizontalBars([
                { label: 'Copy', value: detail.improve_breakdown.copy_count, color: '#10b981' },
                { label: 'Replace', value: detail.improve_breakdown.replace_count, color: '#3b82f6' },
                { label: 'Dismiss', value: detail.improve_breakdown.dismiss_count, color: '#f59e0b' },
                { label: 'No Change', value: detail.improve_breakdown.no_change_count, color: '#6b7280' },
              ].filter(b => b.value > 0))}
            </div>
          </div>
        ` : ''}

        ${detail.history_breakdown ? `
          <div class="d-mt-6">
            ${D.sectionHeader('History')}
            ${D.statRow([
              { label: 'Opens', value: D.fmt.num(detail.history_breakdown.history_opens) },
              { label: 'Follow-Ups', value: D.fmt.num(detail.history_breakdown.history_followups) },
              { label: 'FU Rate', value: detail.history_breakdown.history_followup_rate !== null ? D.fmt.pct(detail.history_breakdown.history_followup_rate) : '\u2014' },
              { label: 'Clears', value: D.fmt.num(detail.history_breakdown.history_clears) },
            ])}
            ${D.statRow([
              { label: 'Avg Depth', value: detail.history_breakdown.avg_depth !== null ? detail.history_breakdown.avg_depth : '\u2014' },
              { label: 'Max Depth', value: detail.history_breakdown.max_depth !== null ? detail.history_breakdown.max_depth : '\u2014' },
              { label: 'First Activity', value: detail.history_breakdown.first_activity ? D.fmt.timeAgo(detail.history_breakdown.first_activity) : '\u2014' },
              { label: 'Last Activity', value: detail.history_breakdown.last_activity ? D.fmt.timeAgo(detail.history_breakdown.last_activity) : '\u2014' },
            ])}
            ${Object.keys(detail.history_breakdown.selection_source || {}).length > 0 ? `
              <div class="d-mt-3">
                ${D.horizontalBars(Object.entries(detail.history_breakdown.selection_source).map((e, i) => {
                  const labels = { explanation: 'Explanation', followup_question: 'Follow-Up Q', followup_answer: 'Follow-Up A' };
                  return { label: labels[e[0]] || e[0], value: e[1], color: ['#e87830','#3b82f6','#10b981'][i % 3] };
                }))}
              </div>
            ` : ''}
          </div>
        ` : ''}

        ${detail.profile_intelligence && detail.profile_intelligence.available ? (() => {
          const pi = detail.profile_intelligence.data || {};
          const sections = [];
          if (pi.technology) sections.push({ label: 'Technology', data: pi.technology });
          if (pi.learning) sections.push({ label: 'Learning', data: pi.learning });
          if (pi.interaction) sections.push({ label: 'Interaction', data: pi.interaction });
          if (pi.coding) sections.push({ label: 'Coding', data: pi.coding });
          if (pi.preference) sections.push({ label: 'Preferences', data: pi.preference });
          if (pi.project) sections.push({ label: 'Project', data: pi.project });
          if (sections.length === 0) return '';
          return '<div class="d-mt-6">' +
            D.sectionHeader('Profile Intelligence', '<span style="font-size:11px;color:var(--d-text-3)">v' + (detail.profile_intelligence.schema_version || '?') + ' \u00b7 ' + (detail.profile_intelligence.synced_at ? D.fmt.timeAgo(detail.profile_intelligence.synced_at) : 'unknown') + '</span>') +
            '<div class="d-chart-card" style="padding:var(--d-sp-5)">' +
            sections.map(s => {
              const items = typeof s.data === 'object' && !Array.isArray(s.data)
                ? Object.entries(s.data).map(([k, v]) => '<div style="margin-bottom:4px"><strong style="font-size:12px">' + D.fmt.escapeHtml(k) + ':</strong> <span style="font-size:12px;color:var(--d-text-2)">' + D.fmt.escapeHtml(typeof v === 'object' ? JSON.stringify(v) : String(v)) + '</span></div>').join('')
                : '<div style="font-size:12px;color:var(--d-text-2)">' + D.fmt.escapeHtml(typeof s.data === 'object' ? JSON.stringify(s.data) : String(s.data)) + '</div>';
              return '<div style="margin-bottom:12px"><div style="font-size:13px;font-weight:600;margin-bottom:4px">' + D.fmt.escapeHtml(s.label) + '</div>' + items + '</div>';
            }).join('') +
            '</div></div>';
        })() : ''}

        ${recentReqs.length ? `
          <div class="d-mt-6">
            ${D.sectionHeader('Recent Requests')}
            ${D.table({
              headers: ['Type', 'Provider', 'Status', { label: 'Latency', align: 'right' }, { label: 'Cost', align: 'right' }, 'Time'],
              rows: recentReqs.slice(0, 15).map(r => ({
                cells: [
                  r.request_type,
                  r.ai_provider ? D.badge(r.ai_provider, r.ai_provider === 'groq' ? 'info' : 'neutral') : '—',
                  r.success ? D.badge('OK', 'success') : D.badge(r.error_type || 'FAIL', 'danger'),
                  D.fmt.latency(r.latency_ms),
                  D.fmt.usd(r.estimated_cost_usd),
                  D.fmt.timeAgo(r.created_at),
                ],
              })),
            })}
          </div>
        ` : ''}

        <div class="d-mt-6" style="display:flex;gap:8px;flex-wrap:wrap">
          <button class="d-btn d-btn-sm" onclick="D.drillDown.exportData(JSON.parse(atob('${btoa(JSON.stringify(detail))}')), 'user-${userId}.json')">Export JSON</button>
          ${u.status === 'active' ? `<button class="d-btn d-btn-sm d-btn-ghost" style="color:var(--d-warning)" onclick="App.pages.users._toggleUser('${userId}', 'disable')">Disable User</button>` : ''}
          ${u.status === 'disabled' ? `<button class="d-btn d-btn-sm d-btn-ghost" style="color:var(--d-success)" onclick="App.pages.users._toggleUser('${userId}', 'enable')">Enable User</button>` : ''}
        </div>
      `);

      requestAnimationFrame(() => {
        if (dailyTrend.length) {
          D.renderAreaChart('user-drill-trend', dailyTrend.map(d => d.requests), {
            labels: dailyTrend.map(d => D.fmt.dateShort(d.date)),
            height: 120,
            color: '#3b82f6',
            yFormat: v => D.fmt.num(Math.round(v)),
          });
        }
      });
    } catch (err) {
      D.drillDown.open('Error', D.error('Failed to load user', err.message));
    }
  },

  _exportUsers() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.users.users, 'users.csv', 'csv');
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
      D.drillDown.close();
      this.render();
    } catch (err) {
      alert(`Failed to ${action} user: ${err.message}`);
    }
  },
};


/* ═══════════════════════════════════════════════════════════
   WORKSPACES — Data-driven from API
   ═══════════════════════════════════════════════════════════ */

App.pages.workspaces = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-workspaces');
    el.innerHTML = `
      ${D.globalFilterBar()}
      ${D.sectionHeader('Overview')}
      ${D.kpiLoading(4, 4)}`;

    try {
      // Workspaces use product data (mode=session → workspace context)
      const [product, exec] = await Promise.all([
        D.api.fetch(D.api.url('/api/v2/analytics/product')),
        D.api.fetch(D.api.url('/api/v2/analytics/executive')),
      ]);
      this._lastData = { product, exec };
      this._renderLive(el, product, exec);
    } catch (err) {
      el.innerHTML = `${D.globalFilterBar()}${D.error('Failed to load workspace data', err.message, "App.pages.workspaces.render()")}`;
    }
  },

  _renderLive(el, product, exec) {
    const modes = product.by_mode || [];
    const sessionMode = modes.find(m => m.mode === 'session') || { count: 0, users: 0 };
    const languages = product.by_language || [];
    const types = product.by_request_type || [];

    // Session mode represents workspace usage
    const enrichments = types.find(t => t.request_type === 'enrichment') || { count: 0 };

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Workspace Activity')}
      ${D.kpiGrid([
        D.kpi({ label: 'Session Requests', value: D.fmt.num(sessionMode.count), sub: 'Workspace-based queries', accent: 'brand' }),
        D.kpi({ label: 'Session Users', value: D.fmt.num(sessionMode.users), sub: 'Active workspace users', accent: 'info' }),
        D.kpi({ label: 'Enrichment Jobs', value: D.fmt.num(enrichments.count), sub: 'Background knowledge gen', accent: 'purple' }),
        D.kpi({ label: 'Languages', value: D.fmt.num(languages.length), sub: 'Distinct languages', accent: 'success' }),
      ], 4)}

      ${languages.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Language Distribution')}
          ${D.chartGrid([
            D.chartCard({ title: 'Top Languages', canvasId: 'ws-donut-lang', height: 260, placeholder: false }),
            D.chartCard({ title: 'Language Volume', canvasId: 'ws-bar-lang', height: 220 }),
          ], 2)}
        </div>
      ` : ''}

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Session Mode Performance')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          ${D.horizontalBars(modes.filter(m => m.count > 0).map(m => ({
            label: m.mode,
            value: m.count,
            color: m.mode === 'session' ? '#3b82f6' : m.mode === 'selection' ? '#e87830' : '#8b5cf6',
          })))}
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Note')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <p style="font-size:13px;color:var(--d-text-2)">
            Workspace-level analytics (file counts, indexing health, per-workspace metrics) require client-side telemetry.
            Current data shows server-side Session Mode and language usage as proxies for workspace activity.
          </p>
        </div>
      </div>

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('product')">&#x2190; Product</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('quality')">Quality &#x2192;</button>
      </div>
    `;

    requestAnimationFrame(() => {
      if (languages.length) {
        const langColors = ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b','#ef4444','#06b6d4','#ec4899','#84cc16','#f97316'];
        const langSegs = languages.slice(0, 8).map((l, i) => ({ label: l.language, value: l.count, color: langColors[i % langColors.length] }));
        const langTotal = langSegs.reduce((s, x) => s + x.value, 0);
        const lCanvas = document.getElementById('ws-donut-lang');
        if (lCanvas) {
          const body = lCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="ws-donut-lang" style="width:180px;height:180px"></canvas>${D.donutLegend(langSegs, langTotal)}</div>`;
          D.renderDonutChart('ws-donut-lang', langSegs, { height: 180, centerLabel: D.fmt.num(langTotal), centerSub: 'files' });
        }
        D.renderBarChart('ws-bar-lang', languages.slice(0, 10).map(l => l.count), {
          labels: languages.slice(0, 10).map(l => l.language),
          colors: langColors,
          height: 220,
          yFormat: v => D.fmt.num(Math.round(v)),
        });
      }
    });
  },
};


/* ═══════════════════════════════════════════════════════════
   QUALITY & ERRORS — Live Data
   ═══════════════════════════════════════════════════════════ */

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

    // Recent failed requests from live
    const failedReqs = (live.requests || []).filter(r => !r.success).slice(0, 10);

    el.innerHTML = `
      ${D.globalFilterBar()}

      ${D.sectionHeader('Reliability')}
      ${D.kpiGrid([
        D.kpi({ label: 'Success Rate', value: D.fmt.pct(rel.success_rate), accent: rel.success_rate >= 95 ? 'success' : rel.success_rate >= 80 ? 'warning' : 'danger' }),
        D.kpi({ label: 'Total Requests', value: D.fmt.num(rel.total_requests), accent: 'brand' }),
        D.kpi({ label: 'Failed Requests', value: D.fmt.num(totalErrors), accent: totalErrors === 0 ? 'success' : 'danger' }),
        D.kpi({ label: 'Avg Latency', value: D.fmt.latency(lat.avg_ms) }),
      ], 4)}

      <div class="d-mt-6">
        ${D.kpiGrid([
          D.kpi({ label: 'p50 Latency', value: D.fmt.latency(lat.p50_ms), sub: 'Median', accent: 'success' }),
          D.kpi({ label: 'p95 Latency', value: D.fmt.latency(lat.p95_ms), sub: '95th percentile', accent: lat.p95_ms > 5000 ? 'danger' : 'warning' }),
          D.kpi({ label: 'p99 Latency', value: D.fmt.latency(lat.p99_ms), sub: '99th percentile', accent: 'danger' }),
          D.kpi({ label: 'Range', value: D.fmt.latency(lat.min_ms) + ' – ' + D.fmt.latency(lat.max_ms), sub: 'Min – Max' }),
        ], 4)}
      </div>

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
            D.chartCard({ title: 'Error Volume', canvasId: 'quality-bar-errors', height: 220 }),
          ], 2)}
        </div>
      ` : ''}

      ${failedReqs.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Recent Failures (Last Hour)')}
          ${D.table({
            headers: [
              'Error', 'Mode', 'Provider',
              { label: 'Latency', align: 'right' }, 'Time',
            ],
            rows: failedReqs.map(r => ({
              cells: [
                `<span class="d-text-danger">${D.fmt.escapeHtml(r.error_type || 'unknown')}</span>`,
                r.origin_mode || '—',
                `<span class="d-text-mono">${D.fmt.escapeHtml(r.ai_provider)}</span>`,
                D.fmt.latency(r.latency_ms),
                D.fmt.timeAgo(r.created_at),
              ],
            })),
          })}
        </div>
      ` : ''}

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('ai')">&#x2190; AI Platform</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('cost')">Cost &#x2192;</button>
      </div>
    `;

    requestAnimationFrame(() => {
      if (dailySuccessRate.length) {
        D.renderAreaChart('quality-line-success', dailySuccessRate, {
          labels: dailyLabels,
          height: 220,
          color: '#10b981',
          min: Math.max(0, Math.min(...dailySuccessRate) - 5),
          yFormat: v => D.fmt.pct(v, 0),
        });
      }
      if (dailyLatency.length) {
        D.renderAreaChart('quality-line-latency', dailyLatency, {
          labels: dailyLabels,
          height: 220,
          color: '#f59e0b',
          yFormat: v => D.fmt.latency(v),
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
        D.renderBarChart('quality-bar-errors', errors.map(e => e.count), {
          labels: errors.map(e => e.error_type.substring(0, 14)),
          colors: '#ef4444',
          height: 220,
          yFormat: v => D.fmt.num(Math.round(v)),
        });
      }
    });
  },

  _exportErrors() {
    if (!this._lastData) return;
    D.drillDown.exportData(this._lastData.quality.errors, 'errors.csv', 'csv');
  },
};


/* ═══════════════════════════════════════════════════════════
   COST INTELLIGENCE — Live Data
   ═══════════════════════════════════════════════════════════ */

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
    const models = cost.by_model || [];
    const byType = cost.by_request_type || [];
    const dailyTrend = cost.daily_trend || [];

    const costPerReq = exec.total_requests > 0 ? totalCost / exec.total_requests : 0;
    const costPerUser = exec.unique_users > 0 ? totalCost / exec.unique_users : 0;
    const todayCost = dailyTrend.length > 0 ? dailyTrend[dailyTrend.length - 1].cost_usd : 0;

    const dailyLabels = dailyTrend.map(d => D.fmt.dateShort(d.date));
    const dailyCostData = dailyTrend.map(d => d.cost_usd);
    // Cost per request trend
    const dailyCPR = dailyTrend.map(d => d.requests > 0 ? d.cost_usd / d.requests : 0);

    const provColors = ['#e87830','#3b82f6','#10b981','#8b5cf6','#f59e0b','#ef4444'];
    const typeColors = { explain: '#e87830', followup: '#3b82f6', improve: '#10b981', vision: '#8b5cf6', enrichment: '#f59e0b', unknown: '#6b7280' };

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
          D.chartCard({ title: 'Cost by Request Type', canvasId: 'cost-donut-type', height: 260, placeholder: false }),
        ], 2)}
      </div>

      ${providers.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Provider Economics', `<button class="d-btn d-btn-sm d-btn-ghost" onclick="App.pages.cost._exportProviders()">Export</button>`)}
          ${D.table({
            headers: [
              'Provider',
              { label: 'Cost', align: 'right' },
              { label: 'Requests', align: 'right' },
              { label: 'Cost/Req', align: 'right' },
              { label: 'Input Tok', align: 'right' },
              { label: 'Output Tok', align: 'right' },
              { label: 'Total Tok', align: 'right' },
              { label: '% of Spend', align: 'right' },
            ],
            rows: providers.map(p => ({
              cells: [
                `<strong>${D.fmt.escapeHtml(p.provider)}</strong>`,
                D.fmt.usd(p.cost_usd),
                D.fmt.num(p.requests),
                D.fmt.usd(p.requests > 0 ? p.cost_usd / p.requests : 0, 4),
                D.fmt.num(p.prompt_tokens),
                D.fmt.num(p.completion_tokens),
                D.fmt.num((p.prompt_tokens || 0) + (p.completion_tokens || 0)),
                D.fmt.pct(totalCost > 0 ? (p.cost_usd / totalCost * 100) : 0),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${models.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Model Economics')}
          ${D.table({
            headers: [
              'Model',
              { label: 'Cost', align: 'right' },
              { label: 'Requests', align: 'right' },
              { label: 'Cost/Req', align: 'right' },
              { label: 'Input Tok', align: 'right' },
              { label: 'Output Tok', align: 'right' },
              { label: 'Total Tok', align: 'right' },
              { label: '% of Spend', align: 'right' },
            ],
            rows: models.map(m => ({
              cells: [
                `<span class="d-text-mono">${D.fmt.escapeHtml(m.model)}</span>`,
                D.fmt.usd(m.cost_usd),
                D.fmt.num(m.requests),
                D.fmt.usd(m.requests > 0 ? m.cost_usd / m.requests : 0, 4),
                D.fmt.num(m.prompt_tokens),
                D.fmt.num(m.completion_tokens),
                D.fmt.num((m.prompt_tokens || 0) + (m.completion_tokens || 0)),
                D.fmt.pct(totalCost > 0 ? (m.cost_usd / totalCost * 100) : 0),
              ],
            })),
          })}
        </div>
      ` : ''}

      ${byType.length > 0 ? `
        <div class="d-section d-mt-6">
          ${D.sectionHeader('Cost by Request Type')}
          <div class="d-chart-card" style="padding:var(--d-sp-5)">
            ${D.horizontalBars(byType.map(t => ({
              label: t.request_type,
              value: t.cost_usd,
              color: typeColors[t.request_type] || '#6b7280',
            })), { valueFormat: v => D.fmt.usd(v) })}
          </div>
        </div>
      ` : ''}

      <div class="d-section d-mt-6" style="text-align:center;padding:var(--d-sp-4)">
        <button class="d-btn d-btn-ghost" onclick="App.navigate('quality')">&#x2190; Quality</button>
        <button class="d-btn d-btn-ghost" onclick="App.navigate('settings')">Settings &#x2192;</button>
      </div>
    `;

    requestAnimationFrame(() => {
      D.renderAreaChart('cost-chart-daily', dailyCostData, {
        labels: dailyLabels,
        height: 220,
        color: '#f59e0b',
        yFormat: v => D.fmt.usdCompact(v),
      });
      D.renderAreaChart('cost-chart-cpr', dailyCPR, {
        labels: dailyLabels,
        height: 220,
        color: '#8b5cf6',
        yFormat: v => D.fmt.usd(v, 4),
      });

      // Provider donut
      if (providers.length) {
        const provSegs = providers.map((p, i) => ({ label: p.provider, value: p.cost_usd, color: provColors[i % provColors.length] }));
        const pCanvas = document.getElementById('cost-donut-provider');
        if (pCanvas) {
          const body = pCanvas.closest('.d-chart-body');
          body.innerHTML = `<div class="d-donut-wrap"><canvas id="cost-donut-provider" style="width:180px;height:180px"></canvas>${D.donutLegend(provSegs, totalCost)}</div>`;
          D.renderDonutChart('cost-donut-provider', provSegs, { height: 180, centerLabel: D.fmt.usdCompact(totalCost), centerSub: 'total' });
        }
      }
      // Type donut
      if (byType.length) {
        const typeTot = byType.reduce((s, t) => s + t.cost_usd, 0);
        const typeSegs = byType.map(t => ({ label: t.request_type, value: t.cost_usd, color: typeColors[t.request_type] || '#6b7280' }));
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


/* ═══════════════════════════════════════════════════════════
   SETTINGS — Live Data
   ═══════════════════════════════════════════════════════════ */

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
        ${D.sectionHeader('Data Health')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
            <div>
              <div style="font-size:12px;font-weight:600;color:var(--d-text-2);margin-bottom:8px">V2 Migration</div>
              ${D.progressBar(data.v2_ai_requests, data.v2_ai_requests + data.legacy_request_logs, {
                color: data.v2_ai_requests > 0 ? 'var(--d-success)' : 'var(--d-warning)',
                label: data.v2_ai_requests > 0 ? D.fmt.pct(data.v2_ai_requests / (data.v2_ai_requests + data.legacy_request_logs) * 100) + ' migrated' : 'No v2 data yet',
              })}
              <div style="font-size:11px;color:var(--d-text-3);margin-top:8px">
                ${D.fmt.num(data.v2_ai_requests)} v2 + ${D.fmt.num(data.legacy_request_logs)} legacy = ${D.fmt.num(data.v2_ai_requests + data.legacy_request_logs)} total
              </div>
            </div>
            <div>
              <div style="font-size:12px;font-weight:600;color:var(--d-text-2);margin-bottom:8px">Aggregation</div>
              <div style="font-size:13px;color:var(--d-text-1)">
                ${D.fmt.num(data.daily_summaries)} daily summaries
              </div>
              <div style="font-size:11px;color:var(--d-text-3);margin-top:4px">
                Latest: ${data.latest_summary_date || 'None'}
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('AI Configuration')}
        <div class="d-chart-card">
          ${D.table({
            headers: ['Setting', 'Value'],
            rows: [
              { cells: ['<strong>Adapter</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.adapter || '—')}</span>`] },
              { cells: ['<strong>Anthropic Model</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.anthropic_model || '—')}</span>`] },
              { cells: ['<strong>Groq Model</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.groq_model || '—')}</span>`] },
              { cells: ['<strong>Vision Provider</strong>', `<span class="d-text-mono">${D.fmt.escapeHtml(aiConfig.vision_provider || '—')}</span>`] },
            ],
          })}
        </div>
      </div>

      <div class="d-section d-mt-6">
        ${D.sectionHeader('Invite Management')}
        <div class="d-chart-card" style="padding:var(--d-sp-5)">
          <div style="display:flex;gap:12px;align-items:center;margin-bottom:16px">
            <button class="d-btn d-btn-sm" onclick="App.pages.settings._generateInvite()">Generate Invite Code</button>
            <span id="settings-invite-result" style="font-size:12px;color:var(--d-text-2)"></span>
          </div>
          <div id="settings-invite-codes"></div>
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
            <a href="/admin" class="d-btn d-btn-sm">v1 Dashboard &#x2197;</a>
            <button class="d-btn d-btn-sm" onclick="App.logout()">Sign Out</button>
            <button class="d-btn d-btn-sm d-btn-ghost" onclick="D.api.clearCache();App.refreshPage()">Clear Cache</button>
          </div>
        </div>
      </div>
    `;

    // Load invite codes after render
    this._loadInviteCodes();
  },

  async _generateInvite() {
    const resultEl = document.getElementById('settings-invite-result');
    resultEl.textContent = 'Generating...';
    try {
      const res = await fetch('/api/admin/invite', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${App.token}`, 'Content-Type': 'application/json' },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      resultEl.innerHTML = `<span class="d-text-mono" style="font-size:14px;font-weight:600;color:var(--d-success)">${D.fmt.escapeHtml(data.invite_code)}</span>`;
      this._loadInviteCodes();
    } catch (err) {
      resultEl.innerHTML = `<span style="color:var(--d-danger)">Failed: ${D.fmt.escapeHtml(err.message)}</span>`;
    }
  },

  async _loadInviteCodes() {
    const container = document.getElementById('settings-invite-codes');
    if (!container) return;
    try {
      const res = await fetch('/api/admin/users', {
        headers: { 'Authorization': `Bearer ${App.token}` },
      });
      if (!res.ok) return;
      const users = await res.json();
      const pending = users.filter(u => u.status === 'pending');
      if (pending.length === 0) {
        container.innerHTML = '<div style="font-size:12px;color:var(--d-text-3)">No pending invites</div>';
        return;
      }
      container.innerHTML = D.table({
        title: 'Pending Invites',
        headers: ['Invite Code', 'Name', 'Created'],
        rows: pending.map(u => ({
          cells: [
            `<span class="d-text-mono">${D.fmt.escapeHtml(u.invite_code || '\u2014')}</span>`,
            D.fmt.escapeHtml(u.name || '\u2014'),
            u.created_at ? D.fmt.timeAgo(u.created_at) : '\u2014',
          ],
        })),
      });
    } catch (err) {
      container.innerHTML = '';
    }
  },
};


/* ═══════════════════════════════════════════════════════════
   FEEDBACK — User Satisfaction Analytics
   ═══════════════════════════════════════════════════════════ */

App.pages.feedback = {
  _lastData: null,

  async render() {
    const el = document.getElementById('page-feedback');

    el.innerHTML = `
      <div class="d-page-loading">
        ${D.kpiGrid([
          D.kpi({ label: 'Loading...', value: '—' }),
          D.kpi({ label: '', value: '' }),
          D.kpi({ label: '', value: '' }),
        ])}
      </div>
    `;

    try {
      const data = await D.api.fetch(D.api.url('/api/v2/analytics/feedback'));
      this._lastData = data;

      const satisfactionColor = data.satisfaction >= 70 ? 'var(--d-success)' :
                                data.satisfaction >= 40 ? 'var(--d-warning)' : 'var(--d-danger)';

      let html = '';

      // KPIs
      html += D.kpiGrid([
        D.kpi({ label: 'Satisfaction', value: D.fmt.pct(data.satisfaction), accent: satisfactionColor }),
        D.kpi({ label: 'Total Feedback', value: D.fmt.num(data.total_feedback) }),
        D.kpi({ label: 'Likes', value: D.fmt.num(data.likes), accent: 'var(--d-success)' }),
        D.kpi({ label: 'Dislikes', value: D.fmt.num(data.dislikes), accent: 'var(--d-danger)' }),
      ]);

      // Feedback by Feature
      if (data.by_feature && data.by_feature.length) {
        html += D.sectionHeader('By Feature');
        html += D.table({
          headers: ['Feature', 'Total', 'Likes', 'Dislikes', 'Satisfaction'],
          rows: data.by_feature.map(r => [
            D.badge(r.feature, r.feature === 'explain' ? 'info' : 'brand'),
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ]),
        });
      }

      // Feedback by Optimisation Goal
      if (data.by_optimisation_goal && data.by_optimisation_goal.length) {
        html += D.sectionHeader('By Optimisation Goal');
        html += D.table({
          headers: ['Goal', 'Total', 'Likes', 'Dislikes', 'Satisfaction'],
          rows: data.by_optimisation_goal.map(r => [
            D.badge(r.goal, 'brand'),
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ]),
        });
      }

      // Feedback by Language
      if (data.by_language && data.by_language.length) {
        html += D.sectionHeader('By Language');
        html += D.table({
          headers: ['Language', 'Total', 'Likes', 'Dislikes', 'Satisfaction'],
          rows: data.by_language.map(r => [
            r.language,
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ]),
        });
      }

      // Feedback by Mode (Provider proxy)
      if (data.by_mode && data.by_mode.length) {
        html += D.sectionHeader('By Mode');
        html += D.table({
          headers: ['Mode', 'Total', 'Likes', 'Dislikes', 'Satisfaction'],
          rows: data.by_mode.map(r => [
            D.badge(r.mode, 'neutral'),
            D.fmt.num(r.total),
            D.fmt.num(r.likes),
            D.fmt.num(r.dislikes),
            D.badge(D.fmt.pct(r.satisfaction), r.satisfaction >= 70 ? 'success' : r.satisfaction >= 40 ? 'warning' : 'danger'),
          ]),
        });
      }

      // Daily Trend Chart
      if (data.daily_trend && data.daily_trend.length > 1) {
        html += D.sectionHeader('Feedback Over Time');
        html += D.chartGrid([
          D.chartCard({ title: 'Daily Feedback', height: 220, canvasId: 'feedback-daily-chart' }),
          D.chartCard({ title: 'Daily Satisfaction', height: 220, canvasId: 'feedback-satisfaction-chart' }),
        ], 2);
      }

      el.innerHTML = html;

      // Render charts after DOM mount.
      if (data.daily_trend && data.daily_trend.length > 1) {
        requestAnimationFrame(() => {
          D.renderBarChart('feedback-daily-chart', {
            labels: data.daily_trend.map(d => D.fmt.dateShort(d.date)),
            values: data.daily_trend.map(d => d.total),
          }, { color: 'var(--d-brand)' });

          const satValues = data.daily_trend.map(d => d.total > 0 ? Math.round(d.likes / d.total * 100) : 0);
          D.renderAreaChart('feedback-satisfaction-chart', {
            labels: data.daily_trend.map(d => D.fmt.dateShort(d.date)),
            values: satValues,
          }, { color: 'var(--d-success)', yMax: 100, ySuffix: '%' });
        });
      }

    } catch (e) {
      el.innerHTML = D.error('Failed to load feedback data', e.message, () => this.render());
    }
  },
};


/* ── Initialize on DOM ready ── */
document.addEventListener('DOMContentLoaded', () => App.init());
