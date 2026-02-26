/**
 * Nagios ICMP Monitor — Panel de Control
 * Lógica del frontend: carga de datos, CRUD de hosts, auto-refresh
 */

const API = 'api.php';
let allHosts = [];
let allStatuses = {};
let currentFilter = 'all';
let refreshTimer = null;

// ---- DOM Elements ----
const $hostsBody = document.getElementById('hostsBody');
const $totalHosts = document.getElementById('totalHosts');
const $hostsUp = document.getElementById('hostsUp');
const $hostsDown = document.getElementById('hostsDown');
const $hostsUnreachable = document.getElementById('hostsUnreachable');
const $hostsPending = document.getElementById('hostsPending');
const $lastUpdate = document.getElementById('lastUpdate');
const $searchInput = document.getElementById('searchInput');
const $autoRefresh = document.getElementById('autoRefresh');
const $refreshInterval = document.getElementById('refreshInterval');
const $modalOverlay = document.getElementById('modalOverlay');
const $deleteOverlay = document.getElementById('deleteOverlay');
const $hostForm = document.getElementById('hostForm');
const $modalTitle = document.getElementById('modalTitle');
const $btnSubmit = document.getElementById('btnSubmit');
const $formCheckLevel = document.getElementById('formCheckLevel');
const $toasts = document.getElementById('toasts');

// ---- Init ----
document.addEventListener('DOMContentLoaded', () => {
    loadData();
    setupEventListeners();
    setupAutoRefresh();
});

function setupEventListeners() {
    // Add host button
    document.getElementById('btnAddHost').addEventListener('click', () => openAddModal());

    // Modal close
    document.getElementById('modalClose').addEventListener('click', closeModal);
    document.getElementById('btnCancel').addEventListener('click', closeModal);
    $modalOverlay.addEventListener('click', e => { if (e.target === $modalOverlay) closeModal(); });

    // Delete modal
    document.getElementById('deleteClose').addEventListener('click', closeDeleteModal);
    document.getElementById('deleteCancelBtn').addEventListener('click', closeDeleteModal);
    $deleteOverlay.addEventListener('click', e => { if (e.target === $deleteOverlay) closeDeleteModal(); });

    // Form submit
    $hostForm.addEventListener('submit', handleFormSubmit);

    // Search
    $searchInput.addEventListener('input', renderTable);

    // Tabs
    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            currentFilter = tab.dataset.tab;
            renderTable();
        });
    });

    // Check level info cards
    $formCheckLevel.addEventListener('change', () => {
        const level = $formCheckLevel.value;
        document.querySelectorAll('.info-card').forEach(card => {
            card.classList.toggle('active', card.dataset.level === level);
        });
    });

    // Auto-refresh toggle
    $autoRefresh.addEventListener('change', setupAutoRefresh);
    $refreshInterval.addEventListener('change', setupAutoRefresh);

    // Keyboard shortcuts
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape') {
            closeModal();
            closeDeleteModal();
        }
    });
}

// ---- Data Loading ----
async function loadData() {
    try {
        const [hostsRes, statusRes] = await Promise.all([
            fetch(`${API}?action=hosts`).then(r => r.json()),
            fetch(`${API}?action=status`).then(r => r.json())
        ]);

        allHosts = hostsRes.hosts || [];
        allStatuses = statusRes.statuses || {};

        updateSummary(statusRes.summary || {});
        renderTable();
        $lastUpdate.textContent = `Actualizado: ${formatTime(new Date())}`;
    } catch (err) {
        console.error('Error cargando datos:', err);
        showToast('Error al cargar datos del servidor', 'error');
        $hostsBody.innerHTML = `
            <tr><td colspan="8" class="empty-state">
                <div class="empty-state-icon">⚠️</div>
                <div class="empty-state-text">No se pudo conectar con la API</div>
            </td></tr>`;
    }
}

// ---- Auto Refresh ----
function setupAutoRefresh() {
    if (refreshTimer) clearInterval(refreshTimer);
    if ($autoRefresh.checked) {
        const interval = parseInt($refreshInterval.value) * 1000;
        refreshTimer = setInterval(loadData, interval);
    }
}

// ---- Summary ----
function updateSummary(summary) {
    const total = (summary.up || 0) + (summary.down || 0) + (summary.unreachable || 0) + (summary.pending || 0);
    animateNumber($totalHosts, total);
    animateNumber($hostsUp, summary.up || 0);
    animateNumber($hostsDown, summary.down || 0);
    animateNumber($hostsUnreachable, summary.unreachable || 0);
    animateNumber($hostsPending, summary.pending || 0);
}

function animateNumber(el, target) {
    const current = parseInt(el.textContent) || 0;
    if (current === target) return;
    el.textContent = target;
    el.style.transform = 'scale(1.15)';
    setTimeout(() => el.style.transition = 'transform 0.3s ease', 0);
    setTimeout(() => el.style.transform = 'scale(1)', 50);
}

// ---- Render Table ----
function renderTable() {
    const search = $searchInput.value.toLowerCase().trim();

    let filtered = allHosts.filter(host => {
        const name = (host.host_name || '').toLowerCase();
        const alias = (host.alias || '').toLowerCase();
        const address = (host.address || '').toLowerCase();
        const type = host._type || 'internal';
        const status = allStatuses[host.host_name];
        const state = status ? status.state : 'PENDING';

        // Filter by tab
        if (currentFilter === 'internal' && type !== 'internal') return false;
        if (currentFilter === 'external' && type !== 'external') return false;
        if (currentFilter === 'down' && state !== 'DOWN' && state !== 'UNREACHABLE') return false;

        // Filter by search
        if (search && !name.includes(search) && !alias.includes(search) && !address.includes(search)) {
            return false;
        }

        return true;
    });

    // Sort: DOWN first, then UNREACHABLE, then UP, then PENDING
    const stateOrder = { 'DOWN': 0, 'UNREACHABLE': 1, 'UP': 2, 'PENDING': 3 };
    filtered.sort((a, b) => {
        const stateA = allStatuses[a.host_name]?.state || 'PENDING';
        const stateB = allStatuses[b.host_name]?.state || 'PENDING';
        return (stateOrder[stateA] ?? 4) - (stateOrder[stateB] ?? 4);
    });

    if (filtered.length === 0) {
        $hostsBody.innerHTML = `
            <tr><td colspan="8" class="empty-state">
                <div class="empty-state-icon">📡</div>
                <div class="empty-state-text">No hay hosts ${currentFilter !== 'all' ? 'en esta categoría' : 'configurados'}</div>
                <button class="btn btn-primary" onclick="openAddModal()">➕ Agregar Host</button>
            </td></tr>`;
        return;
    }

    $hostsBody.innerHTML = filtered.map(host => {
        const status = allStatuses[host.host_name] || {};
        const state = status.state || 'PENDING';
        const rta = status.rta;
        const loss = status.packet_loss;
        const lastCheck = status.last_check;
        const type = host._type || 'internal';

        return `<tr>
            <td>${renderStatusBadge(state)}</td>
            <td>
                <span class="host-name">${escapeHtml(host.host_name)}</span>
                ${host.alias && host.alias !== host.host_name ? `<span class="host-alias">${escapeHtml(host.alias)}</span>` : ''}
            </td>
            <td style="font-family: monospace; color: var(--text-secondary);">${escapeHtml(host.address || '—')}</td>
            <td class="td-type">${renderTypeBadge(type)}</td>
            <td>${renderRTA(rta)}</td>
            <td>${renderLoss(loss)}</td>
            <td><span class="time-ago">${lastCheck ? timeAgo(lastCheck) : '—'}</span></td>
            <td>
                <div class="actions-cell">
                    <button class="btn-icon" title="Editar" onclick="openEditModal('${escapeAttr(host.host_name)}')">✏️</button>
                    <button class="btn-icon danger" title="Eliminar" onclick="openDeleteModal('${escapeAttr(host.host_name)}')">🗑️</button>
                </div>
            </td>
        </tr>`;
    }).join('');
}

function renderStatusBadge(state) {
    const cls = state.toLowerCase();
    return `<span class="status-badge status-${cls}"><span class="pulse"></span>${state}</span>`;
}

function renderTypeBadge(type) {
    if (type === 'external') {
        return '<span class="type-badge type-external">🌐 Externo</span>';
    }
    return '<span class="type-badge type-internal">🏠 Interno</span>';
}

function renderRTA(rta) {
    if (rta === null || rta === undefined) return '<span class="metric-rta" style="color:var(--text-muted)">—</span>';
    let cls = 'rta-ok';
    if (rta > 300) cls = 'rta-critical';
    else if (rta > 100) cls = 'rta-warning';
    return `<span class="metric-rta ${cls}">${rta.toFixed(1)} ms</span>`;
}

function renderLoss(loss) {
    if (loss === null || loss === undefined) return '<span class="metric-loss" style="color:var(--text-muted)">—</span>';
    let cls = 'ok';
    if (loss >= 40) cls = 'critical';
    else if (loss >= 10) cls = 'warning';
    // Cap bar at 100%
    const barWidth = Math.min(loss, 100);
    return `<div class="loss-bar-wrap">
        <span class="metric-loss loss-${cls}">${loss.toFixed(0)}%</span>
        <div class="loss-bar"><div class="loss-bar-fill ${cls}" style="width:${barWidth}%"></div></div>
    </div>`;
}

// ---- Modal: Add ----
function openAddModal() {
    $modalTitle.textContent = 'Agregar Host';
    $btnSubmit.textContent = 'Agregar Host';
    $hostForm.reset();
    document.getElementById('formOriginalName').value = '';
    // Reset info cards
    document.querySelectorAll('.info-card').forEach(card => {
        card.classList.toggle('active', card.dataset.level === 'detailed');
    });
    $modalOverlay.classList.add('active');
    document.getElementById('formHostName').focus();
}

// ---- Modal: Edit ----
function openEditModal(hostName) {
    const host = allHosts.find(h => h.host_name === hostName);
    if (!host) return;

    $modalTitle.textContent = 'Editar Host';
    $btnSubmit.textContent = 'Guardar Cambios';

    document.getElementById('formOriginalName').value = host.host_name;
    document.getElementById('formHostName').value = host.host_name;
    document.getElementById('formAddress').value = host.address || '';
    document.getElementById('formAlias').value = host.alias || '';
    document.getElementById('formParent').value = host.parents || '';
    document.getElementById('formType').value = host._type || 'internal';

    // Detect check level from check_command
    const checkCmd = host.check_command || '';
    let level = 'detailed';
    if (checkCmd.includes('quick')) level = 'quick';
    else if (checkCmd.includes('strict')) level = 'strict';
    $formCheckLevel.value = level;
    document.querySelectorAll('.info-card').forEach(card => {
        card.classList.toggle('active', card.dataset.level === level);
    });

    $modalOverlay.classList.add('active');
}

function closeModal() {
    $modalOverlay.classList.remove('active');
}

// ---- Modal: Delete ----
let pendingDeleteHost = '';

function openDeleteModal(hostName) {
    pendingDeleteHost = hostName;
    document.getElementById('deleteHostName').textContent = hostName;
    $deleteOverlay.classList.add('active');
}

function closeDeleteModal() {
    $deleteOverlay.classList.remove('active');
    pendingDeleteHost = '';
}

document.getElementById('deleteConfirmBtn').addEventListener('click', async () => {
    if (!pendingDeleteHost) return;

    const hostName = pendingDeleteHost;
    closeDeleteModal();

    try {
        const res = await fetch(`${API}?action=delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ host_name: hostName })
        });
        const data = await res.json();

        if (data.success) {
            showToast(`Host "${hostName}" eliminado`, 'success');
            await reloadNagios();
            await loadData();
        } else {
            showToast(data.error || 'Error al eliminar', 'error');
        }
    } catch (err) {
        showToast('Error de conexión', 'error');
    }
});

// ---- Form Submit ----
async function handleFormSubmit(e) {
    e.preventDefault();

    const originalName = document.getElementById('formOriginalName').value;
    const isEdit = !!originalName;

    const payload = {
        host_name: document.getElementById('formHostName').value.trim(),
        address: document.getElementById('formAddress').value.trim(),
        alias: document.getElementById('formAlias').value.trim(),
        parent: document.getElementById('formParent').value.trim(),
        type: document.getElementById('formType').value,
        check_level: $formCheckLevel.value,
    };

    if (isEdit) {
        payload.original_name = originalName;
    }

    const action = isEdit ? 'edit' : 'add';
    $btnSubmit.disabled = true;
    $btnSubmit.textContent = 'Guardando...';

    try {
        const res = await fetch(`${API}?action=${action}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        const data = await res.json();

        if (data.success) {
            closeModal();
            showToast(data.message || `Host ${isEdit ? 'actualizado' : 'agregado'}`, 'success');
            await reloadNagios();
            await loadData();
        } else {
            showToast(data.error || 'Error al guardar', 'error');
        }
    } catch (err) {
        showToast('Error de conexión', 'error');
    } finally {
        $btnSubmit.disabled = false;
        $btnSubmit.textContent = isEdit ? 'Guardar Cambios' : 'Agregar Host';
    }
}

// ---- Reload Nagios ----
async function reloadNagios() {
    try {
        const res = await fetch(`${API}?action=reload`, { method: 'POST' });
        const data = await res.json();
        if (!data.success) {
            showToast('Advertencia: Nagios no se pudo recargar', 'error');
        }
    } catch (err) {
        // Silent fail on reload
    }
}

// ---- Toast ----
function showToast(message, type = 'info') {
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    const icons = { success: '✅', error: '❌', info: 'ℹ️' };
    toast.innerHTML = `<span>${icons[type] || ''}</span><span>${escapeHtml(message)}</span>`;
    $toasts.appendChild(toast);

    setTimeout(() => {
        toast.classList.add('toast-remove');
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

// ---- Utilities ----
function formatTime(date) {
    return date.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function timeAgo(timestamp) {
    const now = Math.floor(Date.now() / 1000);
    const diff = now - timestamp;
    if (diff < 0) return 'ahora';
    if (diff < 60) return `hace ${diff}s`;
    if (diff < 3600) return `hace ${Math.floor(diff / 60)}m`;
    if (diff < 86400) return `hace ${Math.floor(diff / 3600)}h`;
    return `hace ${Math.floor(diff / 86400)}d`;
}

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

function escapeAttr(str) {
    return str.replace(/'/g, "\\'").replace(/"/g, '\\"');
}
