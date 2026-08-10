const money = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'USD' });
const els = Object.fromEntries([
  'connectionBadge', 'botStatus', 'campaignNumber', 'statusMessage', 'saveState',
  'profitTarget', 'maxLoss', 'runPl', 'lossMarker', 'profitMarker', 'runProgress',
  'campaignPl', 'campaignProgress', 'balance', 'equity', 'openCount', 'pendingCount',
  'levelsBody', 'offButton', 'eventList', 'lastUpdate', 'toast'
].map(id => [id, document.getElementById(id)]));

let saveTimer = null;
let latestState = null;
let toastTimer = null;
let limitsDirty = false;
let restoreAttempted = false;

const limitStorageKeys = {
  profit: 'xauusd5x5.profitTarget',
  loss: 'xauusd5x5.maxLoss'
};

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function formatMoney(value) {
  return money.format(number(value));
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  }[char]));
}

function showToast(message, error = false) {
  els.toast.textContent = message;
  els.toast.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { els.toast.className = 'toast'; }, 2600);
}

function rememberLimits(profitTarget, maxLoss) {
  try {
    localStorage.setItem(limitStorageKeys.profit, String(profitTarget));
    localStorage.setItem(limitStorageKeys.loss, String(maxLoss));
  } catch (_) {
    // The server still keeps the current values when browser storage is unavailable.
  }
}

function storedLimits() {
  try {
    const profitTarget = number(localStorage.getItem(limitStorageKeys.profit));
    const maxLoss = number(localStorage.getItem(limitStorageKeys.loss));
    return profitTarget > 0 && maxLoss > 0 ? { profitTarget, maxLoss } : null;
  } catch (_) {
    return null;
  }
}

function statusCopy(status) {
  const labels = {
    WAITING_FOR_LIMITS: ['WAITING', 'Enter both overall money limits.'],
    READY: ['READY', 'Limits saved. Attach the EA to XAU/USD in MT5.'],
    STARTING: ['STARTING', 'MT5 connected. Preparing the first 5×5 campaign.'],
    RUNNING: ['RUNNING', 'The current campaign is live.'],
    CAMPAIGN_COMPLETE: ['RUNNING', 'Campaign target reached. Starting a fresh campaign.'],
    CAMPAIGN_BREAKEVEN: ['RUNNING', 'Campaign protected at breakeven. Starting again.'],
    OFF_REQUESTED: ['STOPPING', 'OFF received. MT5 is closing trades and deleting orders.'],
    MANUAL_OFF: ['OFF', 'Stopped from the Railway dashboard.'],
    PROFIT_TARGET_REACHED: ['TARGET HIT', 'Overall profit target reached. Bot stopped.'],
    MAX_LOSS_REACHED: ['LOSS LIMIT', 'Maximum loss reached. Bot stopped.'],
    ERROR: ['ERROR', 'Check the recent activity and the MT5 Experts log.']
  };
  return labels[status] || [status || 'WAITING', 'Waiting for the next MT5 update.'];
}

function renderLevels(levels) {
  const byKey = new Map((Array.isArray(levels) ? levels : []).map(item => [
    `${String(item.side || '').toUpperCase()}-${number(item.level)}`, item
  ]));
  const rows = [];
  for (const side of ['BUY', 'SELL']) {
    for (let level = 1; level <= 5; level += 1) {
      const item = byKey.get(`${side}-${level}`) || {};
      const state = String(item.state || 'WAITING').toUpperCase();
      const pillClass = state.includes('BREAKEVEN') ? 'be' : state === 'OPEN' ? 'open' : '';
      const value = key => item[key] == null || item[key] === 0 ? '—' : number(item[key]).toFixed(2);
      rows.push(`<tr>
        <td><span class="order-name ${side.toLowerCase()}">${side} ${level}</span></td>
        <td><span class="pill ${pillClass}">${escapeHtml(state)}</span></td>
        <td>${value('entry')}</td><td>${value('sl')}</td><td>${value('tp')}</td>
        <td class="${number(item.pl) > 0 ? 'positive' : number(item.pl) < 0 ? 'negative' : ''}">${item.pl == null ? '—' : formatMoney(item.pl)}</td>
      </tr>`);
    }
  }
  els.levelsBody.innerHTML = rows.join('');
}

function render(state) {
  latestState = state;
  const control = state.control || {};
  const t = state.telemetry || {};
  const status = t.status || control.status;
  const [statusLabel, message] = statusCopy(status);
  els.botStatus.textContent = statusLabel;
  els.botStatus.className = control.enabled ? 'running' : (String(status).includes('OFF') || String(status).includes('LOSS') || String(status).includes('TARGET')) ? 'off' : '';
  els.statusMessage.textContent = t.message || message;
  els.campaignNumber.textContent = t.campaign_number ? `Campaign ${t.campaign_number}` : 'Campaign —';

  if (!limitsDirty) {
    if (document.activeElement !== els.profitTarget) els.profitTarget.value = control.profit_target || '';
    if (document.activeElement !== els.maxLoss) els.maxLoss.value = control.max_loss || '';
    els.saveState.textContent = control.limits_configured ? 'Saved' : 'Not set';
    els.saveState.className = `save-state${control.limits_configured ? ' saved' : ''}`;
  }
  if (control.limits_configured) {
    rememberLimits(control.profit_target, control.max_loss);
  }

  const runPl = number(t.run_pl);
  const campaignPl = number(t.campaign_pl);
  els.runPl.textContent = formatMoney(runPl);
  els.runPl.className = runPl > 0 ? 'positive' : runPl < 0 ? 'negative' : '';
  els.campaignPl.textContent = formatMoney(campaignPl);
  els.campaignPl.className = campaignPl > 0 ? 'positive' : campaignPl < 0 ? 'negative' : '';
  els.lossMarker.textContent = `−${formatMoney(control.max_loss || 0)}`;
  els.profitMarker.textContent = `+${formatMoney(control.profit_target || 0)}`;
  const fullRange = number(control.max_loss) + number(control.profit_target);
  const overallPercent = fullRange ? ((runPl + number(control.max_loss)) / fullRange) * 100 : 50;
  els.runProgress.style.width = `${Math.max(0, Math.min(100, overallPercent))}%`;
  els.campaignProgress.style.width = `${Math.max(0, Math.min(100, (campaignPl / 5) * 100))}%`;

  els.balance.textContent = t.balance == null ? '—' : formatMoney(t.balance);
  els.equity.textContent = t.equity == null ? '—' : formatMoney(t.equity);
  els.openCount.textContent = number(t.open_positions);
  els.pendingCount.textContent = number(t.pending_orders);
  renderLevels(t.levels);

  const last = new Date(state.telemetry_updated_at || 0);
  const live = t.status && (Date.now() - last.getTime()) < 12000;
  els.connectionBadge.className = `connection${live ? ' live' : ''}`;
  els.connectionBadge.querySelector('span').textContent = live ? 'MT5 connected' : 'Waiting for MT5';
  els.lastUpdate.textContent = t.status ? `Last MT5 update ${last.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', second: '2-digit'})}` : 'No MT5 update yet';
  els.offButton.disabled = !control.enabled;

  const events = Array.isArray(state.events) ? state.events : [];
  els.eventList.innerHTML = events.length ? events.map(event => `<li><span>${escapeHtml(event.message)}</span><time>${new Date(event.created_at).toLocaleString()}</time></li>`).join('') : '<li><span>Waiting for activity</span></li>';
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options
  });
  if (response.status === 401) {
    window.location.href = '/login';
    throw new Error('Login required');
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || 'Request failed');
  return data;
}

async function refresh() {
  try {
    let state = await api('/api/status');
    const control = state.control || {};
    const saved = storedLimits();
    if (!control.limits_configured && saved && !restoreAttempted && !limitsDirty) {
      restoreAttempted = true;
      limitsDirty = true;
      els.profitTarget.value = saved.profitTarget;
      els.maxLoss.value = saved.maxLoss;
      await api('/api/settings', {
        method: 'POST',
        body: JSON.stringify({
          profit_target: saved.profitTarget,
          max_loss: saved.maxLoss
        })
      });
      limitsDirty = false;
      state = await api('/api/status');
    }
    render(state);
  } catch (error) {
    els.connectionBadge.className = 'connection';
    els.connectionBadge.querySelector('span').textContent = 'Dashboard offline';
  }
}

function scheduleSave() {
  clearTimeout(saveTimer);
  limitsDirty = true;
  els.saveState.textContent = 'Typing…';
  els.saveState.className = 'save-state';
  saveTimer = setTimeout(saveLimits, 650);
}

async function saveLimits() {
  const profitTarget = number(els.profitTarget.value);
  const maxLoss = number(els.maxLoss.value);
  if (profitTarget <= 0 || maxLoss <= 0) {
    els.saveState.textContent = 'Enter both';
    els.saveState.className = 'save-state error';
    return;
  }
  try {
    await api('/api/settings', {
      method: 'POST',
      body: JSON.stringify({ profit_target: profitTarget, max_loss: maxLoss })
    });
    rememberLimits(profitTarget, maxLoss);
    limitsDirty = false;
    els.saveState.textContent = 'Saved';
    els.saveState.className = 'save-state saved';
    showToast(`Limits set: +${formatMoney(profitTarget)} / −${formatMoney(maxLoss)}`);
    await refresh();
  } catch (error) {
    els.saveState.textContent = 'Not saved';
    els.saveState.className = 'save-state error';
    showToast(error.message, true);
  }
}

els.profitTarget.addEventListener('input', scheduleSave);
els.maxLoss.addEventListener('input', scheduleSave);
for (const input of [els.profitTarget, els.maxLoss]) {
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter') { clearTimeout(saveTimer); input.blur(); saveLimits(); }
  });
}

els.offButton.addEventListener('click', async () => {
  const confirmed = window.confirm('Turn the bot OFF now? Every open trade will close and every pending order will be deleted.');
  if (!confirmed) return;
  els.offButton.disabled = true;
  try {
    await api('/api/off', { method: 'POST', body: '{}' });
    showToast('OFF sent to MT5');
    await refresh();
  } catch (error) {
    showToast(error.message, true);
    els.offButton.disabled = false;
  }
});

refresh();
setInterval(refresh, 1500);
