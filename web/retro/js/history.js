const $ = selector => document.querySelector(selector);
const state = { history: [], book: [], fresh: false, local: '', busy: false, loaded: false };

const normalizeAddress = address => Array.isArray(address)
  ? address.map(Number).filter(Number.isInteger) : [];
const key = address => normalizeAddress(address).join('-');
const direction = event => event.activity === 'Inbound' ? 'incoming' : 'outgoing';
const timestamp = event => {
  const value = Date.parse(event.start_time || '');
  return Number.isFinite(value) ? value : 0;
};
const eventAddress = event => {
  if (Array.isArray(event.gate_address) && event.gate_address.length) return normalizeAddress(event.gate_address);
  const remote = direction(event) === 'incoming' ? event.dialer_address : event.receiver_address;
  return Array.isArray(remote) && remote.length ? normalizeAddress(remote) : null;
};

function compatibleAddress(left, right) {
  const a = normalizeAddress(left);
  const b = normalizeAddress(right);
  if (a.length < 6 || b.length < 6) return false;
  const shorter = a.length <= b.length ? a : b;
  const longer = a.length <= b.length ? b : a;
  return shorter.every((symbol, index) => longer[index] === symbol);
}

function gatesForAddress(address) {
  const wanted = normalizeAddress(address);
  if (!wanted.length) return [];
  const exact = state.book.filter(gate => key(gate.gate_address) === key(wanted));
  if (exact.length) return exact;
  return state.book.filter(gate => compatibleAddress(gate.gate_address, wanted));
}

function findGate(event) {
  const address = eventAddress(event);
  if (address) {
    const matches = gatesForAddress(address);
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) return null;
  }
  const source = String(event.source_ip || '');
  if (!source) return null;
  const matches = state.book.filter(gate => String(gate.ip_address || '') === source);
  return matches.length === 1 ? matches[0] : null;
}

function remoteDialable(gate) {
  if (!gate || !Array.isArray(gate.gate_address) || !gate.gate_address.length) return false;
  if (key(gate.gate_address) === state.local || gate.is_black_hole) return false;
  if (gate.type === 'fan' || gate.type === 'lan') return state.fresh && String(gate.is_gate_online) === '1';
  return gate.type === 'standard';
}
function canDial(gate) { return !state.busy && remoteDialable(gate); }

function statusFor(gate) {
  if (!gate) return { label: 'Unknown', cls: 'unknown' };
  if (gate.type === 'standard') return { label: 'Standard', cls: 'unknown' };
  if (!state.fresh) return { label: 'Status unknown', cls: 'unknown' };
  const online = String(gate.is_gate_online) === '1';
  return { label: online ? 'Online' : 'Offline', cls: online ? 'online' : 'offline' };
}

function formatTime(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function displayName(event, gate) {
  const named = String(event.gate_name || '').trim();
  if (named && !['Unknown', 'Unknown Address'].includes(named)) return named;
  return gate?.name || String(event.source_ip || event.gate_address || 'Unknown');
}

function candidates() {
  const called = new Set(state.history.filter(event => direction(event) === 'outgoing')
    .map(findGate).filter(Boolean).map(gate => key(gate.gate_address)));
  return state.fresh ? state.book.filter(gate => gate.type === 'fan'
    && String(gate.is_gate_online) === '1'
    && key(gate.gate_address) !== state.local
    && !called.has(key(gate.gate_address))) : [];
}

function retryableFailures() {
  const latestAttempts = new Map();
  for (const event of state.history) {
    if (direction(event) !== 'outgoing') continue;
    const gate = findGate(event);
    if (!gate || gate.type !== 'fan' || !remoteDialable(gate)) continue;
    const id = key(gate.gate_address);
    const prior = latestAttempts.get(id);
    if (!prior || timestamp(event) > timestamp(prior)) latestAttempts.set(id, event);
  }
  return [...latestAttempts.values()].filter(event => event.activity === 'Failed' || event.status === 'Failed');
}

function updateSummary() {
  $('#summary-total').textContent = `${state.history.length} recorded events`;
  $('#summary-outgoing').textContent = `${state.history.filter(e => direction(e) === 'outgoing').length} outgoing attempts`;
  $('#summary-incoming').textContent = `${state.history.filter(e => direction(e) === 'incoming').length} incoming calls`;
  $('#summary-uncalled').textContent = state.fresh ? `${candidates().length} online, not dialed` : '— online, not dialed';
  $('#summary-failed').textContent = state.fresh
    ? `${retryableFailures().length} latest attempts failed, available`
    : '— latest attempts failed, available';
}

function createCell(row, value, className = '') {
  const cell = document.createElement('td');
  cell.textContent = String(value ?? '');
  if (className) cell.className = className;
  row.append(cell);
  return cell;
}

function createBadge(row, label, cls) {
  const cell = row.insertCell();
  const badge = document.createElement('span');
  badge.className = `badge ${cls}`;
  badge.textContent = label;
  cell.append(badge);
}

function appendDial(row, gate, visible) {
  const cell = row.insertCell();
  cell.hidden = !visible;
  if (!visible) return;
  if (!canDial(gate)) {
    cell.textContent = '—';
    return;
  }
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'dial-button';
  button.textContent = 'DIAL';
  button.addEventListener('click', () => dial(gate));
  cell.append(button);
}

function render() {
  if (!state.loaded) return;
  const view = $('#view').value;
  const order = $('#order').value;
  const query = $('#search').value.toLocaleLowerCase().trim();
  const showActions = view === 'uncalled' || view === 'failed';
  $('#direction').disabled = view !== 'history';
  $('#order').disabled = view === 'uncalled';
  $('#action-heading').hidden = !showActions;
  const body = $('#rows');
  body.replaceChildren();
  let items;
  if (view === 'uncalled') items = candidates().map(gate => ({ gate, event: null }));
  else if (view === 'failed') items = retryableFailures().map(event => ({ gate: findGate(event), event }));
  else items = state.history.filter(event => $('#direction').value === 'all'
    || direction(event) === $('#direction').value).map(event => ({ gate: findGate(event), event }));
  items = items.filter(({ gate, event }) => {
    const text = [gate?.name, event?.gate_name, key(gate?.gate_address),
      key(eventAddress(event || {})), event?.source_ip, event?.gate_address].join(' ').toLocaleLowerCase();
    return !query || text.includes(query);
  });
  items.sort((a, b) => {
    if (view === 'uncalled') return a.gate.name.localeCompare(b.gate.name);
    return order === 'asc' ? timestamp(a.event) - timestamp(b.event) : timestamp(b.event) - timestamp(a.event);
  });
  const fragment = document.createDocumentFragment();
  for (const { gate, event } of items) {
    const row = document.createElement('tr');
    createCell(row, event ? formatTime(event.start_time) : '—');
    createCell(row, event ? (direction(event) === 'incoming' ? 'CALLED ME' : 'I CALLED') : 'NOT DIALED');
    createCell(row, event ? displayName(event, gate) : gate.name, 'gate-name');
    createCell(row, gate ? key(gate.gate_address) : (key(eventAddress(event || {})) || String(event?.source_ip || event?.gate_address || '—')), 'muted');
    if (!event) createBadge(row, 'Not dialed', 'unknown');
    else createBadge(row, event.status === 'Established' ? 'Connected' : 'Failed', event.status === 'Established' ? 'success' : 'failed');
    const status = statusFor(gate);
    createBadge(row, status.label, status.cls);
    appendDial(row, gate, showActions);
    fragment.append(row);
  }
  if (!items.length) {
    const row = document.createElement('tr');
    const cell = createCell(row, !state.fresh && view !== 'history'
      ? 'Live FAN status is unavailable. Refresh after the status source recovers.'
      : 'No matching records.', 'empty');
    cell.colSpan = showActions ? 7 : 6;
    fragment.append(row);
  }
  body.append(fragment);
}

async function fetchJson(path) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch(path, { cache: 'no-store', credentials: 'same-origin', signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally { window.clearTimeout(timeout); }
}

async function load() {
  $('#refresh').disabled = true;
  $('#status-line').textContent = 'Loading call history…';
  $('#status-line').className = 'status-line';
  try {
    const [historyData, bookData, dialData] = await Promise.all([
      fetchJson('/stargate/get/dialing_history'),
      fetchJson('/stargate/get/address_book?type=all'),
      fetchJson('/stargate/get/dialing_status')
    ]);
    state.history = Array.isArray(historyData.history) ? historyData.history : [];
    state.book = Object.values(bookData.address_book || {});
    state.fresh = bookData.status_freshness?.stale === false;
    state.local = key(dialData.local_address);
    state.busy = Boolean(dialData.wormhole_active)
      || Boolean(dialData.address_buffer_outgoing?.length)
      || Boolean(dialData.address_buffer_incoming?.length);
    state.loaded = true;
    $('#status-line').textContent = state.fresh
      ? (state.busy ? 'Gate is busy. Dial actions are paused.' : 'Live gate statuses available.')
      : 'FAN status is stale; online filters and FAN dial actions are paused.';
    $('#status-line').className = state.fresh && !state.busy ? 'status-line' : 'status-line warning';
    updateSummary();
    render();
  } catch (error) {
    $('#status-line').textContent = `Unable to load gate data: ${error.message}`;
    $('#status-line').className = 'status-line error';
  } finally { $('#refresh').disabled = false; }
}

async function dial(gate) {
  if (!canDial(gate)) return;
  if (!window.confirm(`Dial ${gate.name}? This starts the physical Stargate.`)) return;
  try {
    const current = await fetchJson('/stargate/get/dialing_status');
    if (current.wormhole_active || current.address_buffer_outgoing?.length || current.address_buffer_incoming?.length) {
      window.alert('The gate is busy. Wait until it returns to idle.');
      await load();
      return;
    }
    const page = gate.gate_address.length > 6 ? 'dial9.html' : 'dial.html';
    window.location.assign(`${page}?address=${encodeURIComponent(key(gate.gate_address))}`);
  } catch (error) {
    window.alert(`Could not verify gate status: ${error.message}`);
  }
}

for (const id of ['view', 'direction', 'order', 'search']) {
  $(`#${id}`).addEventListener(id === 'search' ? 'input' : 'change', render);
}
$('#refresh').addEventListener('click', load);
load();
window.setInterval(load, 30000);
