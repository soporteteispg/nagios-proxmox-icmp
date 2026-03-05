/**
 * Nagios ICMP Monitor — Panel de Control
 * Lógica del frontend: carga de datos, CRUD de hosts, auto-refresh
 */

console.log("Nagios Web Panel - vStateless Auth Loaded v6");

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
const $historyOverlay = document.getElementById('historyOverlay');
const $historyTitle = document.getElementById('historyTitle');
const $historyEvents = document.getElementById('historyEvents');
const $historyHostSummary = document.getElementById('historyHostSummary');
const $loading = document.getElementById('loading'); // Added for loading indicator

let rtaChart = null;
let plChart = null;
let currentHistoryHost = '';

// ---- Auth ----
const $loginScreen = document.getElementById('loginScreen');
const $appContainer = document.getElementById('appContainer');
const $loginForm = document.getElementById('loginForm');
const $loginError = document.getElementById('loginError');
const $loggedUsername = document.getElementById('loggedUsername');

const AUTH_KEY = 'nagios_token';
const AUTH_USER = 'nagios_user';
const AUTH_ROLE = 'nagios_role';

// Helper que agrega el token a todos los fetch automáticamente
function apiFetch(url, options = {}) {
    const token = localStorage.getItem(AUTH_KEY);
    options.headers = options.headers || {};

    let finalUrl = url;
    if (token) {
        options.headers['Authorization'] = 'Bearer ' + token;
        options.headers['X-Nagios-Auth'] = token;

        // FOOLPROOF FALLBACK: Append token to URL to bypass Apache stripping completely
        const separator = finalUrl.includes('?') ? '&' : '?';
        finalUrl = finalUrl + separator + 'token=' + encodeURIComponent(token);
    }
    return fetch(finalUrl, options);
}

// ---- Init ----
document.addEventListener('DOMContentLoaded', () => {
    setupEventListeners();
    checkAuth();
});

// ===================== AUTH =====================

async function checkAuth() {
    const token = localStorage.getItem(AUTH_KEY);
    if (!token) {
        showLogin();
        return;
    }
    try {
        const res = await apiFetch(`${API}?action=check_auth`);
        const data = await res.json();
        if (res.ok && data.success) {
            showApp(data.username || localStorage.getItem(AUTH_USER) || 'admin', data.role || localStorage.getItem(AUTH_ROLE) || 'regular');
        } else if (res.status === 401) {
            // Solo borrar el token explícitamente cuando el servidor dice que es inválido
            localStorage.removeItem(AUTH_KEY);
            localStorage.removeItem(AUTH_USER);
            localStorage.removeItem(AUTH_ROLE);
            showLogin();
        } else {
            // Es un 500 Server Error o error de red, NO borramos el token
            // Mostramos la app igual y los próximos fetch confirmarán si sigue roto
            console.warn("Fallo no fatal validando auth:", res.status);
            showApp(localStorage.getItem(AUTH_USER) || 'admin', localStorage.getItem(AUTH_ROLE) || 'regular');
        }
    } catch (err) {
        // Fallo de red severo. No borrarmos el token.
        console.warn("API de Auth inalcanzable, manteniéndose logueado...", err);
        showApp(localStorage.getItem(AUTH_USER) || 'admin', localStorage.getItem(AUTH_ROLE) || 'regular');
    }
}

function showLogin() {
    $appContainer.style.display = 'none';
    $loginScreen.style.display = 'flex';
    if (refreshTimer) clearInterval(refreshTimer);
}

function showApp(username, role = 'regular') {
    if (username) $loggedUsername.textContent = username;
    $loginScreen.style.display = 'none';
    $appContainer.style.display = 'block';

    // Apply Permissions
    const btnAddHost = document.getElementById('btnAddHost');
    const tabAdmin = document.getElementById('tabAdmin'); // Lo crearemos en el HTML en breve

    if (role === 'root') {
        if (btnAddHost) btnAddHost.style.display = 'inline-flex';
        if (tabAdmin) tabAdmin.style.display = 'inline-block';
        document.body.classList.add('role-root');
        document.body.classList.remove('role-regular');
    } else {
        if (btnAddHost) btnAddHost.style.display = 'none';
        if (tabAdmin) tabAdmin.style.display = 'none';
        document.body.classList.remove('role-root');
        document.body.classList.add('role-regular');
    }

    // Iniciar app
    loadHosts();
    if ($autoRefresh.checked) {
        startAutoRefresh();
    }
}

$loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    $loginError.style.display = 'none';

    const username = document.getElementById('loginUser').value;
    const password = document.getElementById('loginPass').value;
    const btn = $loginForm.querySelector('button');
    const originalText = btn.textContent;
    btn.textContent = 'Iniciando...';
    btn.disabled = true;

    try {
        const res = await fetch(`${API}?action=login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username, password })
        });

        const data = await res.json();

        if (res.ok && data.success) {
            localStorage.setItem(AUTH_KEY, data.token);
            localStorage.setItem(AUTH_USER, data.username);
            localStorage.setItem(AUTH_ROLE, data.role || 'regular');
            showApp(data.username, data.role || 'regular');
        } else {
            $loginError.textContent = data.error || 'Credenciales inválidas';
            $loginError.style.display = 'block';
        }
    } catch (err) {
        $loginError.textContent = 'Error de red. Intente nuevamente.';
        $loginError.style.display = 'block';
    } finally {
        btn.textContent = originalText;
        btn.disabled = false;
    }
});

async function logout() {
    try {
        await apiFetch(`${API}?action=logout`);
    } catch (e) { }
    localStorage.removeItem(AUTH_KEY);
    localStorage.removeItem(AUTH_USER);
    localStorage.removeItem(AUTH_ROLE);
    showLogin();
    document.getElementById('loginPass').value = '';
}

// ===================== APP LOGIC =====================

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

    // ======================= ADMIN MANAGEMENT =======================

    async function loadUsers() {
        try {
            const res = await apiFetch(`${API}?action=user_list`);
            const data = await res.json();
            const tbody = document.getElementById('usersBody');
            if (!tbody) return;

            if (!data.users || data.users.length === 0) {
                tbody.innerHTML = `<tr><td colspan="3" class="text-center" style="padding: 20px;">No hay usuarios.</td></tr>`;
                return;
            }

            tbody.innerHTML = data.users.map(u => `
            <tr>
                <td><strong>${u.username}</strong></td>
                <td><span class="badge ${u.role === 'root' ? 'badge-purple' : 'badge-blue'}">${u.role}</span></td>
                <td class="actions-cell">
                    <button class="btn-icon" title="Editar" onclick="openEditUserModal('${u.username}', '${u.role}')">
                        <svg width="16" height="16" fill="none" class="icon-edit" stroke="currentColor" stroke-width="2">
                            <path d="M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7" />
                            <path d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z" />
                        </svg>
                    </button>
                    <button class="btn-icon text-danger" title="Eliminar" onclick="confirmDeleteUser('${u.username}')">
                        <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2">
                            <path d="M3 6h18M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2M10 11v6M14 11v6" />
                        </svg>
                    </button>
                </td>
            </tr>
        `).join('');
        } catch (e) {
            showToast("Error cargando usuarios", "error");
        }
    }

    async function loadAuditLogs() {
        try {
            const res = await apiFetch(`${API}?action=audit_logs`);
            const data = await res.json();
            const tbody = document.getElementById('auditBody');
            if (!tbody) return;

            if (!data.logs || data.logs.length === 0) {
                tbody.innerHTML = `<tr><td colspan="4" class="text-center" style="padding: 20px;">No hay registros de auditoría aún.</td></tr>`;
                return;
            }

            tbody.innerHTML = data.logs.map(log => `
            <tr>
                <td class="monospaced" style="font-size: 0.85rem">${log.date}</td>
                <td><strong>${log.user}</strong></td>
                <td><span class="badge badge-gray">${log.action}</span></td>
                <td style="color: var(--text-muted); font-size: 0.9rem">${log.details}</td>
            </tr>
        `).join('');
        } catch (e) {
            showToast("Error cargando logs", "error");
        }
    }

    // User Modal Triggers
    function openAddUserModal() {
        document.getElementById('formUserAction').value = 'add';
        document.getElementById('formUsername').value = '';
        document.getElementById('formUsername').readOnly = false;
        document.getElementById('formUserPass').value = '';
        document.getElementById('formUserPass').placeholder = 'Contraseña Mínimo 4 chars';
        document.getElementById('formUserPass').required = true;
        document.getElementById('userModalTitle').textContent = 'Crear Nuevo Usuario';
        document.getElementById('userOverlay').style.display = 'flex';
    }

    function openEditUserModal(username, role) {
        document.getElementById('formUserAction').value = 'edit';
        document.getElementById('formUsername').value = username;
        document.getElementById('formUsername').readOnly = true;
        document.getElementById('formUserRole').value = role;
        document.getElementById('formUserPass').value = '';
        document.getElementById('formUserPass').placeholder = '(Dejar en blanco para no cambiar)';
        document.getElementById('formUserPass').required = false;
        document.getElementById('userModalTitle').textContent = 'Editar Usuario ' + username;
        document.getElementById('userOverlay').style.display = 'flex';
    }

    function handleUserModalClose() {
        document.getElementById('userOverlay').style.display = 'none';
    }

    window.openAddUserModal = openAddUserModal;
    window.openEditUserModal = openEditUserModal;

    // Initialize Admin Events on Load
    document.addEventListener('DOMContentLoaded', () => {

        // User Form Submit
        const userForm = document.getElementById('userForm');
        if (userForm) {
            userForm.addEventListener('submit', async (e) => {
                e.preventDefault();
                const action = document.getElementById('formUserAction').value;
                const payload = {
                    username: document.getElementById('formUsername').value,
                    role: document.getElementById('formUserRole').value
                };
                const pass = document.getElementById('formUserPass').value;
                if (pass) payload.password = pass;

                try {
                    const res = await apiFetch(`${API}?action=${action === 'add' ? 'user_add' : 'user_edit'}`, {
                        method: 'POST',
                        body: JSON.stringify(payload)
                    });
                    const data = await res.json();

                    if (data.success) {
                        showToast(data.message, 'success');
                        handleUserModalClose();
                        loadUsers();
                        loadAuditLogs();
                    } else {
                        showToast(data.error || 'Error guardando usuario', 'error');
                    }
                } catch (err) {
                    showToast('Error de red al guardar usuario', 'error');
                }
            });
        }

        const btnCloseUser = document.getElementById('userClose');
        if (btnCloseUser) btnCloseUser.addEventListener('click', handleUserModalClose);
        const btnCancelUser = document.getElementById('btnCancelUser');
        if (btnCancelUser) btnCancelUser.addEventListener('click', handleUserModalClose);
    });

    window.confirmDeleteUser = function (username) {
        if (confirm(`¿Estás seguro de que deseas ELIMINAR permanentemente al usuario '${username}'?`)) {
            apiFetch(`${API}?action=user_delete`, {
                method: 'POST',
                body: JSON.stringify({ username })
            }).then(res => res.json()).then(data => {
                if (data.success) {
                    showToast(data.message, 'success');
                    loadUsers();
                    loadAuditLogs();
                } else {
                    showToast(data.error, 'error');
                }
            });
        }
    };
    $searchInput.addEventListener('input', renderTable);

    // Tabs
    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            const tabId = tab.dataset.tab;

            if (tabId === 'admin') {
                document.getElementById('hostsTable').style.display = 'none';
                document.getElementById('summary').style.display = 'none';
                document.getElementById('adminSection').style.display = 'block';
                loadUsers();
                loadAuditLogs();
            } else {
                document.getElementById('adminSection').style.display = 'none';
                document.getElementById('summary').style.display = 'grid';
                document.getElementById('hostsTable').style.display = 'table';
                currentFilter = tabId;
                renderTable();
            }
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
    $autoRefresh.addEventListener('change', startAutoRefresh);
    $refreshInterval.addEventListener('change', startAutoRefresh);

    // Keyboard shortcuts
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape') {
            closeModal();
            closeDeleteModal();
            closeHistoryModal();
        }
    });

    // History modal
    const btnHistoryClose = document.getElementById('historyClose');
    if (btnHistoryClose) btnHistoryClose.addEventListener('click', closeHistoryModal);
    if ($historyOverlay) $historyOverlay.addEventListener('click', e => { if (e.target === $historyOverlay) closeHistoryModal(); });

    // Range pills
    document.querySelectorAll('.range-pill').forEach(pill => {
        pill.addEventListener('click', () => {
            document.querySelectorAll('.range-pill').forEach(p => p.classList.remove('active'));
            pill.classList.add('active');
            if (currentHistoryHost) {
                loadHistory(currentHistoryHost, pill.dataset.range);
            }
        });
    });

    // Logout button
    const btnLogout = document.getElementById('btnLogout');
    if (btnLogout) btnLogout.addEventListener('click', logout);
}

// ---- Data Loading ----
async function loadHosts() {
    if ($loading) $loading.style.display = 'flex';
    $hostsBody.innerHTML = ''; // Assuming $tableBody is $hostsBody

    try {
        const [hostsRes, statusRes] = await Promise.all([
            apiFetch(`${API}?action=hosts`),
            apiFetch(`${API}?action=status`)
        ]);

        if (hostsRes.status === 401 || statusRes.status === 401) {
            showLogin();
            return;
        }

        const hostsData = await hostsRes.json();
        const statusData = await statusRes.json();

        allHosts = (hostsData.hosts || []).filter(h => h.host_name);
        allStatuses = statusData.statuses || {};

        updateSummary(statusData.summary || {});
        renderTable();
        $lastUpdate.textContent = `Actualizado: ${formatTime(new Date())}`;
    } catch (err) {
        // En un error de carga, verificamos si deberíamos patear al usuario
        console.error('Error cargando datos:', err);
        showToast('Error de conexión o timeout cargando hosts', 'error');
        $hostsBody.innerHTML = `
            <tr><td colspan="8" class="empty-state">
                <div class="empty-state-icon">⚠️</div>
                <div class="empty-state-text">No se pudo cargar la info de los hosts. Esperando próximo intento...</div>
            </td></tr>`;
    } finally {
        if ($loading) $loading.style.display = 'none';
    }
}

// ---- Auto Refresh ----
function startAutoRefresh() {
    if (refreshTimer) clearInterval(refreshTimer);
    if ($autoRefresh.checked) {
        const interval = parseInt($refreshInterval.value) * 1000;
        refreshTimer = setInterval(loadHosts, interval);
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

        return `<tr class="host-row" onclick="openHistoryModal('${escapeAttr(host.host_name)}')"
                    title="Ver historial de ${escapeAttr(host.host_name)}">
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
                    <button class="btn-icon" title="Editar" onclick="event.stopPropagation(); openEditModal('${escapeAttr(host.host_name)}')">✏️</button>
                    <button class="btn-icon danger" title="Eliminar" onclick="event.stopPropagation(); openDeleteModal('${escapeAttr(host.host_name)}')">🗑️</button>
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
        const res = await apiFetch(`${API}?action=delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ host_name: hostName })
        });
        const data = await res.json();

        if (data.success) {
            showToast(`Host "${hostName}" eliminado`, 'success');
            await reloadNagios();
            await loadHosts();
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
        const res = await apiFetch(`${API}?action=${action}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        const data = await res.json();

        if (data.success) {
            closeModal();
            showToast(data.message || `Host ${isEdit ? 'actualizado' : 'agregado'}`, 'success');
            await reloadNagios();
            await loadHosts();
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
        const res = await apiFetch(`${API}?action=reload`, { method: 'POST' });
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
    if (!str) return '';
    return String(str).replace(/'/g, "\\'").replace(/"/g, '\\"');
}

// ===================== HISTORIAL =====================

function openHistoryModal(hostName) {
    currentHistoryHost = hostName;
    $historyTitle.textContent = `Historial — ${hostName}`;

    // Show host current status summary
    const host = allHosts.find(h => h.host_name === hostName);
    const status = allStatuses[hostName] || {};
    $historyHostSummary.innerHTML = renderHostSummaryCard(host, status);

    // Reset range pills to 24h
    document.querySelectorAll('.range-pill').forEach(p => {
        p.classList.toggle('active', p.dataset.range === '24h');
    });

    // Show loading
    $historyEvents.innerHTML = `<div class="history-loading"><div class="spinner"></div>Cargando historial...</div>`;

    $historyOverlay.classList.add('active');
    loadHistory(hostName, '24h');
}

function closeHistoryModal() {
    $historyOverlay.classList.remove('active');
    currentHistoryHost = '';
    if (rtaChart) { rtaChart.destroy(); rtaChart = null; }
    if (plChart) { plChart.destroy(); plChart = null; }
}

function renderHostSummaryCard(host, status) {
    if (!host) return '';
    const state = status.state || 'PENDING';
    const rta = status.rta;
    const loss = status.packet_loss;
    const type = host._type || 'internal';

    return `<div class="history-summary-grid">
        <div class="history-summary-item">
            <span class="history-summary-label">Estado</span>
            ${renderStatusBadge(state)}
        </div>
        <div class="history-summary-item">
            <span class="history-summary-label">IP</span>
            <span class="history-summary-value" style="font-family:monospace">${escapeHtml(host.address || '—')}</span>
        </div>
        <div class="history-summary-item">
            <span class="history-summary-label">Tipo</span>
            ${renderTypeBadge(type)}
        </div>
        <div class="history-summary-item">
            <span class="history-summary-label">Latencia</span>
            <span class="history-summary-value">${rta !== null && rta !== undefined ? rta.toFixed(1) + ' ms' : '—'}</span>
        </div>
        <div class="history-summary-item">
            <span class="history-summary-label">Pérdida</span>
            <span class="history-summary-value">${loss !== null && loss !== undefined ? loss.toFixed(0) + '%' : '—'}</span>
        </div>
    </div>`;
}

async function loadHistory(hostName, range) {
    try {
        const res = await apiFetch(`${API}?action=history&host=${encodeURIComponent(hostName)}&range=${range}`);

        if (res.status === 401) {
            showLogin();
            return;
        }

        const data = await res.json();

        if (data.error) {
            $historyEvents.innerHTML = `<div class="history-empty">⚠️ ${escapeHtml(data.error)}</div>`;
            return;
        }

        renderCharts(data.perfdata || []);
        renderEvents(data.events || []);
    } catch (err) {
        console.error('Error loading history:', err);
        $historyEvents.innerHTML = `<div class="history-empty">⚠️ Error al cargar historial</div>`;
    }
}

function renderCharts(perfdata) {
    // Destroy old charts
    if (rtaChart) { rtaChart.destroy(); rtaChart = null; }
    if (plChart) { plChart.destroy(); plChart = null; }

    if (perfdata.length === 0) {
        document.querySelector('.history-charts').innerHTML = `
            <div class="history-empty">📊 No hay datos de rendimiento disponibles aún.<br>
            <small>Los datos se generan automáticamente con cada check de Nagios.</small></div>`;
        return;
    }

    // Make sure chart containers exist
    const chartsContainer = document.querySelector('.history-charts');
    chartsContainer.innerHTML = `
        <div class="chart-container">
            <h3 class="chart-title">📈 Latencia (RTA)</h3>
            <div class="chart-wrapper"><canvas id="chartRTA"></canvas></div>
        </div>
        <div class="chart-container">
            <h3 class="chart-title">📉 Pérdida de Paquetes</h3>
            <div class="chart-wrapper"><canvas id="chartPL"></canvas></div>
        </div>`;

    const labels = perfdata.map(d => new Date(d.timestamp * 1000));
    const rtaData = perfdata.map(d => d.rta);
    const plData = perfdata.map(d => d.packet_loss);

    const chartDefaults = {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
            legend: { display: false },
            tooltip: {
                backgroundColor: 'rgba(26, 32, 53, 0.95)',
                borderColor: 'rgba(99, 102, 241, 0.3)',
                borderWidth: 1,
                titleColor: '#e2e8f0',
                bodyColor: '#94a3b8',
                padding: 12,
                cornerRadius: 8,
            },
        },
        scales: {
            x: {
                type: 'time',
                time: { tooltipFormat: 'dd/MM HH:mm' },
                grid: { color: 'rgba(42, 51, 80, 0.4)' },
                ticks: { color: '#64748b', maxTicksLimit: 8, font: { size: 11 } },
            },
            y: {
                beginAtZero: true,
                grid: { color: 'rgba(42, 51, 80, 0.4)' },
                ticks: { color: '#64748b', font: { size: 11 } },
            }
        }
    };

    // RTA Chart
    const ctxRTA = document.getElementById('chartRTA').getContext('2d');
    const rtaGrad = ctxRTA.createLinearGradient(0, 0, 0, 200);
    rtaGrad.addColorStop(0, 'rgba(99, 102, 241, 0.3)');
    rtaGrad.addColorStop(1, 'rgba(99, 102, 241, 0.02)');

    rtaChart = new Chart(ctxRTA, {
        type: 'line',
        data: {
            labels,
            datasets: [{
                label: 'RTA (ms)',
                data: rtaData,
                borderColor: '#6366f1',
                backgroundColor: rtaGrad,
                fill: true,
                tension: 0.3,
                pointRadius: perfdata.length > 100 ? 0 : 2,
                pointHoverRadius: 5,
                borderWidth: 2,
            }]
        },
        options: {
            ...chartDefaults,
            scales: {
                ...chartDefaults.scales,
                y: { ...chartDefaults.scales.y, title: { display: true, text: 'ms', color: '#64748b' } }
            }
        }
    });

    // Packet Loss Chart
    const ctxPL = document.getElementById('chartPL').getContext('2d');
    const plGrad = ctxPL.createLinearGradient(0, 0, 0, 200);
    plGrad.addColorStop(0, 'rgba(239, 68, 68, 0.3)');
    plGrad.addColorStop(1, 'rgba(239, 68, 68, 0.02)');

    plChart = new Chart(ctxPL, {
        type: 'line',
        data: {
            labels,
            datasets: [{
                label: 'Pérdida (%)',
                data: plData,
                borderColor: '#ef4444',
                backgroundColor: plGrad,
                fill: true,
                tension: 0.3,
                pointRadius: perfdata.length > 100 ? 0 : 2,
                pointHoverRadius: 5,
                borderWidth: 2,
            }]
        },
        options: {
            ...chartDefaults,
            scales: {
                ...chartDefaults.scales,
                y: { ...chartDefaults.scales.y, max: 100, title: { display: true, text: '%', color: '#64748b' } }
            }
        }
    });
}

function renderEvents(events) {
    if (events.length === 0) {
        $historyEvents.innerHTML = `<div class="history-empty">✅ Sin eventos de cambio de estado en este período</div>`;
        return;
    }

    $historyEvents.innerHTML = `<div class="timeline">${events.map(ev => {
        const date = new Date(ev.timestamp * 1000);
        const dateStr = date.toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit' });
        const timeStr = date.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        const stateCls = ev.state.toLowerCase();
        const typeIcon = ev.type === 'notification' ? '🔔' : '⚡';
        const stateTypeLabel = ev.state_type === 'HARD' ? '' : '<span class="soft-label">SOFT</span>';

        return `<div class="timeline-event">
            <div class="timeline-dot dot-${stateCls}"></div>
            <div class="timeline-content">
                <div class="timeline-header">
                    <span class="timeline-time">${dateStr} ${timeStr}</span>
                    ${stateTypeLabel}
                </div>
                <div class="timeline-body">
                    ${typeIcon} <span class="status-badge status-${stateCls}"><span class="pulse"></span>${ev.state}</span>
                    <span class="timeline-msg">${escapeHtml(ev.message)}</span>
                </div>
            </div>
        </div>`;
    }).join('')}</div>`;
}
