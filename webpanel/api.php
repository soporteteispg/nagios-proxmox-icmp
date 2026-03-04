<?php
/**
 * Nagios ICMP Monitor — Panel de Administración Web
 * Archivo: api.php
 * 
 * API REST para gestionar hosts y leer el estado de Nagios.
 * Endpoints:
 *   GET    /api.php?action=hosts         → Listar todos los hosts
 *   GET    /api.php?action=status        → Estado actual de todos los hosts
 *   POST   /api.php?action=add           → Agregar un host
 *   POST   /api.php?action=edit          → Editar un host
 *   POST   /api.php?action=delete        → Eliminar un host
 *   POST   /api.php?action=reload        → Recargar configuración de Nagios
 *   GET    /api.php?action=validate      → Validar configuración
 *   GET    /api.php?action=history&host=X&range=24h → Historial RRD de un host
 */

session_write_close(); // no usamos sessions, las cerramos de inmediato

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// ===================== CONFIGURACIÓN =====================
define('NAGIOS_CFG', '/usr/local/nagios/etc/nagios.cfg');
define('HOSTS_DIR', '/usr/local/nagios/etc/objects/hosts');
define('STATUS_FILE', '/usr/local/nagios/var/status.dat');
define('NAGIOS_BIN', '/usr/local/nagios/bin/nagios');
define('NAGIOS_CMD_FILE', '/usr/local/nagios/var/rw/nagios.cmd');
define('NAGIOS_RRD_DIR', '/usr/local/nagios/var/rrd');
define('NAGIOS_LOG', '/usr/local/nagios/var/nagios.log');
define('NAGIOS_ARCHIVE_DIR', '/usr/local/nagios/var/archives');
// =========================================================

// --- Clave secreta para firmar tokens HMAC ---
// Cambiar este valor invalida todos los tokens activos
define('AUTH_SECRET', 'nagios-icmp-key-2024');

// --- Generar token firmado (válido por 24h) ---
function generateToken(string $username): string
{
    $day = floor(time() / 86400);
    $sig = hash_hmac('sha256', $username . '|' . $day, AUTH_SECRET);
    return base64_encode($username . '|' . $sig);
}

// --- Validar token ---
function validateToken(string $token): ?string
{
    $decoded = base64_decode($token, true);
    if (!$decoded)
        return null;
    $pos = strpos($decoded, '|');
    if ($pos === false)
        return null;
    $username = substr($decoded, 0, $pos);
    $sig = substr($decoded, $pos + 1);
    $expected = generateToken($username);
    $expDecoded = base64_decode($expected, true);
    $expSig = substr($expDecoded, strpos($expDecoded, '|') + 1);
    if (!hash_equals($expSig, $sig))
        return null;
    return $username;
}

// --- Archivo de credenciales ---
$authFile = __DIR__ . '/auth.php';
$credentials = file_exists($authFile) ? include($authFile) : ['users' => []];

$action = $_GET['action'] ?? '';

// --- Middleware de Autenticación por Token HMAC ---
$publicActions = ['login'];

if (!in_array($action, $publicActions)) {
    $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = '';
    if (preg_match('/Bearer\s+(.+)/i', $authHeader, $m)) {
        $token = trim($m[1]);
    }
    $tokenUser = $token ? validateToken($token) : null;
    if (!$tokenUser) {
        http_response_code(401);
        echo json_encode(['error' => 'No autorizado', 'code' => 401]);
        exit;
    }
}

try {
    switch ($action) {
        case 'login':
            $data = json_decode(file_get_contents('php://input'), true) ?: [];
            $username = $data['username'] ?? '';
            $password = $data['password'] ?? '';

            if (isset($credentials['users'][$username]) && password_verify($password, $credentials['users'][$username])) {
                $token = generateToken($username);
                echo json_encode(['success' => true, 'token' => $token, 'username' => $username]);
            }
            else {
                http_response_code(401);
                echo json_encode(['error' => 'Usuario o contraseña incorrectos']);
            }
            break;

        case 'logout':
            // El logout es del lado cliente (borra el token del localStorage)
            echo json_encode(['success' => true]);
            break;

        case 'check_auth':
            // Si llegó acá es porque el middleware validó el token
            echo json_encode(['success' => true, 'username' => $tokenUser ?? '']);
            break;
        case 'hosts':
            echo json_encode(getHosts());
            break;
        case 'status':
            echo json_encode(getStatus());
            break;
        case 'add':
            $data = json_decode(file_get_contents('php://input'), true);
            echo json_encode(addHost($data));
            break;
        case 'edit':
            $data = json_decode(file_get_contents('php://input'), true);
            echo json_encode(editHost($data));
            break;
        case 'delete':
            $data = json_decode(file_get_contents('php://input'), true);
            echo json_encode(deleteHost($data));
            break;
        case 'reload':
            echo json_encode(reloadNagios());
            break;
        case 'validate':
            echo json_encode(validateConfig());
            break;
        case 'history':
            $hostName = sanitizeName($_GET['host'] ?? '');
            $range = $_GET['range'] ?? '24h';
            echo json_encode(getHostHistory($hostName, $range));
            break;
        default:
            echo json_encode(['error' => 'Acción no válida']);
    }
}
catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => $e->getMessage()]);
}

// ===================== FUNCIONES =====================

/**
 * Listar todos los hosts configurados
 */
function getHosts()
{
    $hosts = [];
    $files = glob(HOSTS_DIR . '/*.cfg');

    foreach ($files as $file) {
        $content = file_get_contents($file);
        $filename = basename($file);

        // Parsear definiciones de host
        preg_match_all('/define\s+host\s*\{([^}]+)\}/s', $content, $matches);

        foreach ($matches[1] as $hostBlock) {
            $host = parseBlock($hostBlock);
            $host['_file'] = $filename;
            $host['_type'] = detectType($host);
            $hosts[] = $host;
        }
    }

    return ['hosts' => $hosts];
}

/**
 * Obtener estado actual de todos los hosts desde status.dat
 */
function getStatus()
{
    if (!file_exists(STATUS_FILE)) {
        return ['error' => 'status.dat no encontrado', 'statuses' => []];
    }

    $content = file_get_contents(STATUS_FILE);
    $statuses = [];
    $summary = ['up' => 0, 'down' => 0, 'unreachable' => 0, 'pending' => 0];

    // Parsear hoststatus blocks
    preg_match_all('/hoststatus\s*\{([^}]+)\}/s', $content, $matches);

    foreach ($matches[1] as $block) {
        $data = parseStatusBlock($block);

        $hostName = $data['host_name'] ?? 'unknown';
        $currentState = intval($data['current_state'] ?? -1);
        $stateNames = [0 => 'UP', 1 => 'DOWN', 2 => 'UNREACHABLE'];
        $stateName = $stateNames[$currentState] ?? 'PENDING';

        // Extraer métricas de ping del plugin_output
        $pluginOutput = $data['plugin_output'] ?? '';
        $perfData = $data['performance_data'] ?? '';
        $pingInfo = parsePingOutput($pluginOutput, $perfData);

        $statusEntry = [
            'host_name' => $hostName,
            'state' => $stateName,
            'state_code' => $currentState,
            'plugin_output' => $pluginOutput,
            'last_check' => intval($data['last_check'] ?? 0),
            'last_state_change' => intval($data['last_state_change'] ?? 0),
            'check_interval' => floatval($data['normal_check_interval'] ?? $data['check_interval'] ?? 5),
            'rta' => $pingInfo['rta'],
            'packet_loss' => $pingInfo['packet_loss'],
        ];

        $statuses[$hostName] = $statusEntry;

        // Contabilizar resumen
        $summaryKey = strtolower($stateName);
        if (isset($summary[$summaryKey])) {
            $summary[$summaryKey]++;
        }
    }

    // También parsear servicestatus para obtener detalles de PING
    preg_match_all('/servicestatus\s*\{([^}]+)\}/s', $content, $svcMatches);

    foreach ($svcMatches[1] as $block) {
        $data = parseStatusBlock($block);
        $hostName = $data['host_name'] ?? '';
        $svcDesc = $data['service_description'] ?? '';

        if (stripos($svcDesc, 'PING') !== false && isset($statuses[$hostName])) {
            $pluginOutput = $data['plugin_output'] ?? '';
            $perfData = $data['performance_data'] ?? '';
            $pingInfo = parsePingOutput($pluginOutput, $perfData);

            if ($pingInfo['rta'] !== null) {
                $statuses[$hostName]['rta'] = $pingInfo['rta'];
                $statuses[$hostName]['packet_loss'] = $pingInfo['packet_loss'];
                $statuses[$hostName]['service_output'] = $pluginOutput;

                // Estado del servicio de ping
                $svcState = intval($data['current_state'] ?? 0);
                $svcStateNames = [0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN'];
                $statuses[$hostName]['ping_state'] = $svcStateNames[$svcState] ?? 'UNKNOWN';
            }
        }
    }

    return [
        'statuses' => $statuses,
        'summary' => $summary,
        'total' => array_sum($summary),
        'timestamp' => time()
    ];
}

/**
 * Agregar un nuevo host
 */
function addHost($data)
{
    $name = sanitizeName($data['host_name'] ?? '');
    $alias = $data['alias'] ?? $name;
    $address = $data['address'] ?? '';
    $type = $data['type'] ?? 'internal';
    $parent = sanitizeName($data['parent'] ?? '');
    $checkLevel = $data['check_level'] ?? 'detailed';

    if (empty($name) || empty($address)) {
        return ['error' => 'Nombre y dirección son obligatorios'];
    }

    // Verificar que no exista
    if (hostExists($name)) {
        return ['error' => "El host '$name' ya existe"];
    }

    $template = ($type === 'external') ? 'icmp-host-external' : 'icmp-host-internal';
    $checkCmd = getCheckCommand($checkLevel);
    $parentLine = !empty($parent) ? "    parents                 $parent\n" : '';

    $config = "# Host agregado desde Panel Web - " . date('Y-m-d H:i') . "\n";
    $config .= "define host {\n";
    $config .= "    use                     $template\n";
    $config .= "    host_name               $name\n";
    $config .= "    alias                   $alias\n";
    $config .= "    address                 $address\n";
    $config .= $parentLine;
    $config .= "}\n\n";
    $config .= "define service {\n";
    $config .= "    use                     icmp-ping-service\n";
    $config .= "    host_name               $name\n";
    $config .= "    service_description     PING - Latencia y Pérdida de Paquetes\n";
    $config .= "    check_command           $checkCmd\n";
    $config .= "}\n";

    $file = HOSTS_DIR . "/$name.cfg";
    if (file_put_contents($file, $config) === false) {
        return ['error' => 'No se pudo escribir el archivo de configuración'];
    }

    // Ajustar permisos
    chown($file, 'nagios');
    chgrp($file, 'nagios');
    chmod($file, 0664);

    // Validar
    $validation = validateConfig();
    if ($validation['valid']) {
        return ['success' => true, 'message' => "Host '$name' agregado correctamente", 'file' => $file];
    }
    else {
        // Si la config es inválida, eliminar el archivo
        unlink($file);
        return ['error' => 'Configuración inválida: ' . $validation['output']];
    }
}

/**
 * Editar un host existente
 */
function editHost($data)
{
    $originalName = sanitizeName($data['original_name'] ?? '');
    $name = sanitizeName($data['host_name'] ?? '');
    $alias = $data['alias'] ?? $name;
    $address = $data['address'] ?? '';
    $type = $data['type'] ?? 'internal';
    $parent = sanitizeName($data['parent'] ?? '');
    $checkLevel = $data['check_level'] ?? 'detailed';

    if (empty($originalName) || empty($name) || empty($address)) {
        return ['error' => 'Datos incompletos'];
    }

    // Eliminar el viejo
    $oldFile = findHostFile($originalName);
    if ($oldFile && file_exists($oldFile)) {
        // Leer contenido y eliminar solo este host si el archivo tiene múltiples hosts
        removeHostFromFile($oldFile, $originalName);
    }

    // Crear el nuevo
    $template = ($type === 'external') ? 'icmp-host-external' : 'icmp-host-internal';
    $checkCmd = getCheckCommand($checkLevel);
    $parentLine = !empty($parent) ? "    parents                 $parent\n" : '';

    $config = "# Host editado desde Panel Web - " . date('Y-m-d H:i') . "\n";
    $config .= "define host {\n";
    $config .= "    use                     $template\n";
    $config .= "    host_name               $name\n";
    $config .= "    alias                   $alias\n";
    $config .= "    address                 $address\n";
    $config .= $parentLine;
    $config .= "}\n\n";
    $config .= "define service {\n";
    $config .= "    use                     icmp-ping-service\n";
    $config .= "    host_name               $name\n";
    $config .= "    service_description     PING - Latencia y Pérdida de Paquetes\n";
    $config .= "    check_command           $checkCmd\n";
    $config .= "}\n";

    $file = HOSTS_DIR . "/$name.cfg";
    file_put_contents($file, $config);
    chown($file, 'nagios');
    chgrp($file, 'nagios');
    chmod($file, 0664);

    $validation = validateConfig();
    if ($validation['valid']) {
        return ['success' => true, 'message' => "Host '$name' actualizado"];
    }
    else {
        return ['error' => 'Error en configuración: ' . $validation['output']];
    }
}

/**
 * Eliminar un host
 */
function deleteHost($data)
{
    $name = sanitizeName($data['host_name'] ?? '');

    if (empty($name)) {
        return ['error' => 'Nombre de host requerido'];
    }

    $file = findHostFile($name);
    if (!$file) {
        return ['error' => "Host '$name' no encontrado"];
    }

    $err = removeHostFromFile($file, $name);
    if ($err) {
        return ['error' => $err];
    }

    $validation = validateConfig();
    return ['success' => true, 'message' => "Host '$name' eliminado", 'valid' => $validation['valid']];
}

/**
 * Recargar configuración de Nagios
 */
function reloadNagios()
{
    $validation = validateConfig();
    if (!$validation['valid']) {
        return ['error' => 'Configuración inválida. No se puede recargar.', 'output' => $validation['output']];
    }

    exec('sudo systemctl reload nagios 2>&1', $output, $exitCode);

    if ($exitCode === 0) {
        return ['success' => true, 'message' => 'Nagios recargado exitosamente'];
    }
    else {
        return ['error' => 'Error al recargar: ' . implode("\n", $output)];
    }
}

/**
 * Validar configuración de Nagios
 */
function validateConfig()
{
    exec('sudo ' . NAGIOS_BIN . ' -v ' . NAGIOS_CFG . ' 2>&1', $output, $exitCode);
    $outputStr = implode("\n", $output);
    $valid = (strpos($outputStr, 'Things look okay') !== false);

    return ['valid' => $valid, 'output' => $outputStr];
}

// ===================== HELPERS =====================

function parseBlock($block)
{
    $result = [];
    $lines = explode("\n", $block);
    foreach ($lines as $line) {
        $line = trim($line);
        if (empty($line) || $line[0] === '#' || $line[0] === ';')
            continue;
        if (preg_match('/^(\S+)\s+(.+)$/', $line, $m)) {
            $result[$m[1]] = trim($m[2]);
        }
    }
    return $result;
}

function parseStatusBlock($block)
{
    $result = [];
    $lines = explode("\n", $block);
    foreach ($lines as $line) {
        $line = trim($line);
        if (empty($line))
            continue;
        $parts = explode('=', $line, 2);
        if (count($parts) === 2) {
            $result[trim($parts[0])] = trim($parts[1]);
        }
    }
    return $result;
}

function parsePingOutput($pluginOutput, $perfData)
{
    $rta = null;
    $packetLoss = null;

    // Intentar parsear desde plugin_output: "PING OK - Packet loss = 0%, RTA = 1.23 ms"
    if (preg_match('/Packet loss\s*=\s*([\d.]+)%/', $pluginOutput, $m)) {
        $packetLoss = floatval($m[1]);
    }
    if (preg_match('/RTA\s*=\s*([\d.]+)\s*ms/', $pluginOutput, $m)) {
        $rta = floatval($m[1]);
    }

    // Intentar desde performance_data: "rta=1.234ms;100.000;500.000;0; pl=0%;20;60;;"
    if ($rta === null && preg_match('/rta=([\d.]+)ms/', $perfData, $m)) {
        $rta = floatval($m[1]);
    }
    if ($packetLoss === null && preg_match('/pl=([\d.]+)%/', $perfData, $m)) {
        $packetLoss = floatval($m[1]);
    }

    return ['rta' => $rta, 'packet_loss' => $packetLoss];
}

function sanitizeName($name)
{
    return preg_replace('/[^a-zA-Z0-9_-]/', '', $name);
}

function detectType($host)
{
    $use = $host['use'] ?? '';
    if (strpos($use, 'external') !== false)
        return 'external';
    return 'internal';
}

function getCheckCommand($level)
{
    switch ($level) {
        case 'quick':
            return 'check_ping_quick';
        case 'strict':
            return 'check_ping_strict';
        case 'custom':
            return 'check_host_ping!100.0,20%!500.0,60%!10';
        case 'detailed':
        default:
            return 'check_ping_detailed';
    }
}

function hostExists($name)
{
    $files = glob(HOSTS_DIR . '/*.cfg');
    foreach ($files as $file) {
        $content = file_get_contents($file);
        if (preg_match('/^\s*host_name\s+' . preg_quote($name, '/') . '(\s|;|$)/m', $content)) {
            return true;
        }
    }
    return false;
}

function findHostFile($name)
{
    // Primero buscar archivo dedicado
    $dedicated = HOSTS_DIR . "/$name.cfg";
    if (file_exists($dedicated))
        return $dedicated;

    // Buscar en todos los archivos (permite comentarios inline con ;)
    $files = glob(HOSTS_DIR . '/*.cfg');
    foreach ($files as $file) {
        $content = file_get_contents($file);
        if (preg_match('/^\s*host_name\s+' . preg_quote($name, '/') . '(\s|;|$)/m', $content)) {
            return $file;
        }
    }
    return null;
}

function removeHostFromFile($file, $name)
{
    // Verificar permisos antes de intentar
    if (!is_writable($file)) {
        // Intentar arreglar permisos
        @chgrp($file, 'nagcmd');
        @chmod($file, 0664);
        if (!is_writable($file)) {
            return "No se puede escribir en $file — permisos insuficientes";
        }
    }

    $lines = file($file);
    if ($lines === false) {
        return "No se pudo leer el archivo $file";
    }

    $total = count($lines);
    $result = [];
    $commentBuffer = [];
    $i = 0;
    $removed = false;

    while ($i < $total) {
        $trimmed = trim($lines[$i]);

        // Detectar inicio de bloque define host/service
        if (preg_match('/^define\s+(host|service)\s*\{/', $trimmed)) {
            // Recopilar todo el bloque desde aquí hasta }
            $blockStart = $i;
            $fullBlock = '';
            $blockEnd = $i;
            for ($j = $i; $j < $total; $j++) {
                $fullBlock .= $lines[$j];
                if (strpos(trim($lines[$j]), '}') !== false && $j > $i) {
                    $blockEnd = $j;
                    break;
                }
                if ($j === $i && strpos($trimmed, '}') !== false) {
                    $blockEnd = $j;
                    break;
                }
            }

            // Verificar si el bloque contiene el host_name buscado
            if (preg_match('/^\s*host_name\s+' . preg_quote($name, '/') . '(\s|;|$)/m', $fullBlock)) {
                $commentBuffer = [];
                $i = $blockEnd + 1;
                $removed = true;
                continue;
            }

            // Bloque que NO se elimina
            foreach ($commentBuffer as $cLine) {
                $result[] = $cLine;
            }
            $commentBuffer = [];
            for ($j = $blockStart; $j <= $blockEnd; $j++) {
                $result[] = $lines[$j];
            }
            $i = $blockEnd + 1;
            continue;
        }

        // Bufferear líneas de comentario y vacías
        if ($trimmed === '' || (!empty($trimmed) && $trimmed[0] === '#')) {
            $commentBuffer[] = $lines[$i];
            $i++;
            continue;
        }

        // Línea normal
        foreach ($commentBuffer as $cLine) {
            $result[] = $cLine;
        }
        $commentBuffer = [];
        $result[] = $lines[$i];
        $i++;
    }

    if (!$removed) {
        return "No se encontró el host '$name' en el archivo";
    }

    // Agregar comentarios finales
    foreach ($commentBuffer as $cLine) {
        $result[] = $cLine;
    }

    $content = trim(implode('', $result));

    if (empty($content) || preg_match('/^\s*(#[^\n]*\s*)*$/s', $content)) {
        if (!@unlink($file)) {
            return "No se pudo eliminar el archivo $file";
        }
    }
    else {
        $written = @file_put_contents($file, $content . "\n");
        if ($written === false) {
            return "No se pudo escribir en $file";
        }
        @chown($file, 'nagios');
        @chgrp($file, 'nagcmd');
        @chmod($file, 0664);
    }

    return null; // éxito
}

// ===================== HISTORIAL RRD =====================

/**
 * Obtener historial de un host: datos RRD + eventos de log
 */
function getHostHistory($hostName, $range)
{
    if (empty($hostName)) {
        return ['error' => 'Nombre de host requerido'];
    }

    // Calcular rango de tiempo
    $rangeMap = [
        '1h' => 3600,
        '6h' => 21600,
        '24h' => 86400,
        '7d' => 604800,
        '30d' => 2592000,
    ];
    $seconds = $rangeMap[$range] ?? 86400;
    $startTime = time() - $seconds;

    return [
        'host' => $hostName,
        'range' => $range,
        'perfdata' => getRrdData($hostName, $startTime),
        'events' => getLogEvents($hostName, $startTime),
    ];
}

/**
 * Leer datos de performance desde archivos RRD
 */
function getRrdData($hostName, $startTime)
{
    $safeHost = preg_replace('/[^a-zA-Z0-9_-]/', '_', $hostName);
    $rrdFile = NAGIOS_RRD_DIR . "/{$safeHost}.rrd";

    if (!file_exists($rrdFile)) {
        return [];
    }

    // Usar rrdtool fetch para obtener datos
    $cmd = sprintf(
        'rrdtool fetch %s AVERAGE --start %d --end %d 2>&1',
        escapeshellarg($rrdFile),
        $startTime,
        time()
    );
    exec($cmd, $output, $exitCode);

    if ($exitCode !== 0) {
        return [];
    }

    $data = [];
    foreach ($output as $line) {
        $line = trim($line);
        // Saltar headers y líneas vacías
        if (empty($line) || strpos($line, 'rta') !== false || strpos($line, 'DS') !== false) {
            continue;
        }

        // Formato: timestamp: valor1 valor2
        if (preg_match('/^(\d+):\s+([\d.e+-]+|nan)\s+([\d.e+-]+|nan)/', $line, $m)) {
            $ts = intval($m[1]);
            $rta = strtolower($m[2]) === 'nan' ? null : floatval($m[2]);
            $pl = strtolower($m[3]) === 'nan' ? null : floatval($m[3]);

            // Saltar entradas sin datos
            if ($rta === null && $pl === null)
                continue;

            $data[] = [
                'timestamp' => $ts,
                'rta' => $rta !== null ? round($rta, 2) : null,
                'packet_loss' => $pl !== null ? round($pl, 2) : null,
            ];
        }
    }

    return $data;
}

/**
 * Leer eventos de cambio de estado desde los logs de Nagios
 */
function getLogEvents($hostName, $startTime)
{
    $events = [];
    $logFiles = [];

    // Log actual
    if (file_exists(NAGIOS_LOG)) {
        $logFiles[] = NAGIOS_LOG;
    }

    // Archivos archivados
    if (is_dir(NAGIOS_ARCHIVE_DIR)) {
        $archives = glob(NAGIOS_ARCHIVE_DIR . '/nagios-*.log');
        if ($archives) {
            sort($archives);
            $logFiles = array_merge($logFiles, $archives);
        }
    }

    $escapedName = preg_quote($hostName, '/');

    foreach ($logFiles as $logFile) {
        if (!is_readable($logFile))
            continue;

        $handle = fopen($logFile, 'r');
        if (!$handle)
            continue;

        while (($line = fgets($handle)) !== false) {
            // Formato: [timestamp] HOST ALERT: hostname;STATE;HARD/SOFT;attempt;message
            if (preg_match('/^\[(\d+)\]\s+HOST ALERT:\s+' . $escapedName . ';(UP|DOWN|UNREACHABLE);(HARD|SOFT);(\d+);(.*)$/i', trim($line), $m)) {
                $ts = intval($m[1]);
                if ($ts < $startTime)
                    continue;

                $events[] = [
                    'timestamp' => $ts,
                    'type' => 'alert',
                    'state' => $m[2],
                    'state_type' => $m[3],
                    'attempt' => intval($m[4]),
                    'message' => trim($m[5]),
                ];
            }
            // HOST NOTIFICATION
            elseif (preg_match('/^\[(\d+)\]\s+HOST NOTIFICATION:\s+[^;]+;' . $escapedName . ';(UP|DOWN|UNREACHABLE);/', trim($line), $m)) {
                $ts = intval($m[1]);
                if ($ts < $startTime)
                    continue;

                $events[] = [
                    'timestamp' => $ts,
                    'type' => 'notification',
                    'state' => $m[2],
                    'state_type' => 'HARD',
                    'attempt' => 0,
                    'message' => 'Notificación enviada',
                ];
            }
        }
        fclose($handle);
    }

    // Ordenar por timestamp descendente y limitar
    usort($events, function ($a, $b) {
        return $b['timestamp'] - $a['timestamp'];
    });
    return array_slice($events, 0, 100);
}
