<?php
// Script temporal para arreglar la contraseña. Se auto-eliminará al ejecutarse.
$authFile = __DIR__ . '/auth.php';
$credentials = ['users' => ['admin' => password_hash('nagios2024', PASSWORD_DEFAULT)]];
$content = "<?php\n// Archivo generado automáticamente\nreturn " . var_export($credentials, true) . ";\n";
file_put_contents($authFile, $content);
chmod($authFile, 0640);
@unlink(__FILE__);
echo json_encode(['success' => true, 'message' => 'Contraseña reseteada a admin / nagios2024. Este archivo ha sido eliminado por seguridad.']);
