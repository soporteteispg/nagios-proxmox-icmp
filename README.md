# Monitoreo ICMP con Nagios y Proxmox LXC

Proyecto de monitoreo ICMP con Nagios Core y panel web personalizado. Está optimizado para ser desplegado automáticamente en contenedores LXC de **Proxmox Virtual Environment** usando scripts de bash.

**Índice:**
- [Características](#-características) · [Requisitos](#️-requisitos)
- [Instalación en un CT nuevo](#-instalación-en-un-ct-nuevo-paso-a-paso) (Pasos 1-5)
- [Actualizar un CT existente](#-actualizar-un-ct-existente-sin-reinstalar) (Etapas 0-4)
- [Referencia de scripts](#-referencia-de-scripts) · [Archivos](#-archivos-y-estructura) · [Troubleshooting](#-solución-de-problemas-troubleshooting)

## 🚀 Características
- **Nagios Core 4.5.14** compilado y configurado
- Configuración separada por hosts internos y externos
- Checkeos rápidos (cada 3-5 minutos)
- **Panel Web Moderno** (Dashboard interactivo con modo oscuro) para agregar, borrar y visualizar el estado de los hosts
- **Gestión de Usuarios y Roles (RBAC)** — Autenticación stateless (por Token HMAC) con separación entre usuarios Root (acceso total a configuración/usuarios) y Regulares (sólo gestión de hosts).
- **Log de Auditoría Web** — Registro de acciones y eventos realizados por los usuarios del panel en un log integrado a la interfaz.
- **Historial de Estado con RRD** — Gráficos de latencia (RTA) y pérdida de paquetes a lo largo del tiempo usando datos RRD + línea de tiempo de eventos
- Autodespliegue en Proxmox automatizado

## 🛠️ Requisitos
1. Un servidor con **Proxmox VE 8.0+**
2. Conexión a internet desde el nodo Proxmox para clonar el repositorio y descargar el template de Debian 12.
3. Acceso a la terminal como `root`.

## 📦 Instalación en un CT nuevo (paso a paso)

Todo se hace en el **nodo Proxmox** como `root`. El deploy crea el LXC (Debian 12), compila
Nagios + plugins (~5-15 min) e instala el panel. Detecta el próximo CTID libre desde `200` y te
deja elegir storage.

**Paso 1 — Descargar y ejecutar el deploy:**
```bash
wget https://raw.githubusercontent.com/soporteteispg/nagios-proxmox-icmp/main/scripts/deploy-proxmox.sh
bash deploy-proxmox.sh https://github.com/soporteteispg/nagios-proxmox-icmp.git
```
Si el repositorio es privado, usá un token (PAT): `bash deploy-proxmox.sh https://TOKEN@github.com/soporteteispg/nagios-proxmox-icmp.git`.
*(Si no pasás la URL, el script la pide de forma interactiva).*

**Paso 2 — Primer ingreso (guardá estas credenciales):**
- Panel: `http://<IP-CT>/monitor` → usuario `admin` + password **aleatorio mostrado al final** del deploy. Cambialo en Administración ni bien entres.
- Nagios clásico: `http://<IP-CT>/nagios` → `nagiosadmin` + password **aleatorio mostrado al final** del deploy.

**Paso 3 — Historial de rendimiento (RRD, opcional pero recomendado):**
```bash
pct push <CTID> /root/Nagios/scripts/05-install-rrd.sh /root/05-install-rrd.sh
pct exec <CTID> -- bash /root/05-install-rrd.sh
```
Los gráficos aparecen haciendo clic en cualquier host del panel (los datos arrancan con los primeros checks).

**Paso 4 — Backup diario:**
```bash
pct exec <CTID> -- sh -c '(crontab -l 2>/dev/null; echo "0 3 * * * root /root/06-backup.sh >> /var/log/nagios-backup.log 2>&1") | crontab -'
```

**Paso 5 — Agregá tus hosts:** desde el panel (botón `+ Agregar Host`) o editando `config/hosts/*.cfg` en el repo. Los ejemplos (`192.168.1.x`, `8.8.8.8`) son para probar: reemplazalos por tu red.

✅ **Instalación completa.** Checklist: panel y `/nagios` responden, hosts en UP/DOWN (no PENDING), gráficos al hacer clic en un host, backup diario en cron.

> **Nota para contenedores Unprivileged (LXC)**: el CT corre sin privilegios por defecto. Para que Nagios pueda hacer ping, los scripts le asignan los permisos adecuados y configuran `net.ipv4.ping_group_range`.

---

## 🔄 Actualizar un CT existente (sin reinstalar)

Guía probada en producción para llevar un CT a la última versión del repo por etapas.
Todo se ejecuta en el **nodo Proxmox** como `root`. Reemplazá `<CTID>` (empezá por el menos crítico).

### Etapa 0 — Red de seguridad (siempre)
```bash
pct snapshot <CTID> pre-update
pct push <CTID> /root/Nagios/scripts/06-backup.sh /root/06-backup.sh
pct exec <CTID> -- bash /root/06-backup.sh
```
Si `/root/Nagios` no existe o está desactualizado: `cd /root/Nagios && git pull` (o clonalo).
Rollback si algo sale mal: `pct rollback <CTID> pre-update`.

### Etapa 1 — Panel web (sin downtime)
No reinicia Nagios, solo recarga Apache.
```bash
pct push <CTID> /root/Nagios/webpanel/api.php /root/api.php.new
pct exec <CTID> -- cp /var/www/html/monitor/api.php /var/www/html/monitor/api.php.bak-pre
pct exec <CTID> -- cp /root/api.php.new /var/www/html/monitor/api.php
pct exec <CTID> -- php -l /var/www/html/monitor/api.php
pct pull <CTID> /var/www/html/monitor/.htaccess ./htaccess.ct<CTID>
```
Agregá al final del archivo (con finales de línea **LF**):
```apache
<Files "auth.php">
    Require all denied
</Files>
<Files "audit.log">
    Require all denied
</Files>
```
```bash
pct push <CTID> ./htaccess.ct<CTID> /var/www/html/monitor/.htaccess
pct exec <CTID> -- apachectl configtest   # debe decir "Syntax OK"
pct exec <CTID> -- systemctl reload apache2
```
Verificación (IP del CT: `pct exec <CTID> -- hostname -I`):
```bash
curl -s -o /dev/null -w "audit.log -> %{http_code}\n" http://<IP>/monitor/audit.log
curl -s -o /dev/null -w "api sin token -> %{http_code}\n" "http://<IP>/monitor/api.php?action=status"
```
Esperado: `403` y `401`. Después en el navegador: login, agregar y borrar un host de prueba.
Rollback: `pct exec <CTID> -- cp /var/www/html/monitor/api.php.bak-pre /var/www/html/monitor/api.php && systemctl reload apache2`.

### Etapa 2 — RRD (solo si usás gráficos)
Si existe `/usr/local/nagios/var/rrd` con datos. Al final hace `systemctl restart nagios` (corte de segundos).
```bash
pct push <CTID> /root/Nagios/scripts/05-install-rrd.sh /root/05-install-rrd.sh
pct exec <CTID> -- bash /root/05-install-rrd.sh
pct exec <CTID> -- grep -n "logger" /usr/local/nagios/libexec/process_perfdata.sh
```

### Etapa 3 — Núcleo Nagios (ventana de mantenimiento)
Recompila (5-15 min), reinicia el servicio y **resetea el password de `nagiosadmin`** (el del panel no se toca).
```bash
pct push <CTID> /root/Nagios/scripts/02-install-nagios.sh /root/02-install-nagios.sh
pct exec <CTID> -- bash -c 'bash /root/02-install-nagios.sh 2>&1 | tee /root/02-output.log'
```
Guardá el password nuevo del bloque final (si se pierde: `pct exec <CTID> -- grep -A2 "Password" /root/02-output.log`).
```bash
pct exec <CTID> -- /usr/local/nagios/bin/nagios --version
pct exec <CTID> -- systemctl is-active nagios apache2
pct exec <CTID> -- /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg 2>&1 | tail -3
```
Los hosts salen de PENDING en minutos (hueco de RRD durante la compilación es normal).

### Etapa 4 — Cron (una sola vez)
```bash
pct exec <CTID> -- sh -c '(crontab -l 2>/dev/null; echo "0 3 * * * root /root/06-backup.sh >> /var/log/nagios-backup.log 2>&1") | crontab -'
```

✅ **Actualización completa.** Checklist: `nagios --version` nueva, `nagios -v` limpio, panel con login + alta/baja OK, gráficos retomando datos, cron instalado.

---

## 📜 Referencia de scripts
- **Script 01**: Descarga Debian 12 si no existe, crea un LXC y le asigna configuración de red por DHCP.
- **Script 02**: Instala las dependencias y compila Nagios 4.5.14 y los nagios-plugins.
- **Script 03**: Utilitario interactivo para añadir hosts a la monitorización.
- **Script 04**: Instala el Panel Web (API PHP y frontend HTML) y configura Apache2. Configura los permisos para editar los hosts desde el panel.
- **Script 05** *(opcional)*: Instala `rrdtool` y configura Nagios para almacenar datos de rendimiento (latencia y pérdida de paquetes) en archivos RRD. Habilita los gráficos de historial en el panel web.
- **Script 06**: Backup de hosts, configs, usuarios del panel y RRD en un `.tgz` con retención. Pensado para cron diario (ver Paso 4 de instalación).

## 📂 Archivos y Estructura
- `/scripts/` — Scripts de bash automatizados y wrapper de Proxmox.
  - `01-create-lxc.sh` — Crear contenedor LXC
  - `02-install-nagios.sh` — Instalar Nagios Core + Plugins
  - `03-add-host.sh` — Añadir hosts interactivamente
  - `04-install-webpanel.sh` — Instalar panel web
  - `05-install-rrd.sh` — Instalar rrdtool y habilitar historial RRD
  - `06-backup.sh` — Backup de configs, panel y RRD (con retención)
  - `deploy-proxmox.sh` — Despliegue automatizado completo
- `/config/` — Archivos `.cfg` de Nagios base y templates.
- `/webpanel/` — Dashboard responsivo con HTML/JS, gráficos Chart.js y API en PHP.

## 🚑 Solución de Problemas (Troubleshooting)

### 1. Hosts externos aparecen como DOWN pero hay internet
En contenedores LXC, el comando `ping` requiere permisos especiales (SUID) para que el usuario `nagios` pueda enviar paquetes ICMP. Si los hosts externos (como 8.8.8.8) figuran inactivos:
```bash
# Otorgar permisos SUID al binario ping
chmod u+s /bin/ping
systemctl restart nagios
```
*(Nota: El script `02-install-nagios.sh` ya aplica este fix automáticamente).*

### 2. No se pueden eliminar o editar hosts/usuarios desde el panel web
Para que el panel web (Apache/PHP) pueda modificar los archivos de configuración y la base de usuarios, el usuario `www-data` debe tener permisos de escritura. Si el panel falla o no guarda los cambios:
```bash
# Arreglar permisos completos del directorio web y de hosts
chown -R www-data:www-data /var/www/html/monitor
chmod -R 0755 /var/www/html/monitor
chown -R nagios:www-data /usr/local/nagios/etc/objects/hosts /usr/local/nagios/var/rw
chmod -R 775 /usr/local/nagios/etc/objects/hosts /usr/local/nagios/var/rw
```

### 3. Recuperar acceso de Administrador (Root)
Si tu usuario principal perdió el acceso root o la UI de Administración ya no se muestra, puedes regenerar el archivo de usuarios con un hash bcrypt válido directamente desde el shell del contenedor LXC:
```bash
pct exec 200 -- php -r "\$arr = ['users' => ['admin' => ['hash' => password_hash('admin', PASSWORD_DEFAULT), 'role' => 'root']]]; file_put_contents('/var/www/html/monitor/auth.php', '<?php return ' . var_export(\$arr, true) . ';'); chmod('/var/www/html/monitor/auth.php', 0660); chown('/var/www/html/monitor/auth.php', 'www-data');"
```
*(Esto restablecerá el usuario a `admin` y la contraseña a `admin` con permisos root).*

### 4. Los gráficos de historial no muestran datos
Si al hacer clic en un host el modal dice "No hay datos de rendimiento disponibles", verificá que el script 05 se ejecutó correctamente:
```bash
# Verificar que rrdtool está instalado
rrdtool --version

# Verificar que existen archivos RRD
ls /usr/local/nagios/var/rrd/

# Verificar que Nagios procesa perfdata
grep "process_performance_data" /usr/local/nagios/etc/nagios.cfg
```
Los archivos `.rrd` se crean automáticamente con el primer check de cada host.

### 5. Rotar credenciales que quedaron con valores por defecto
Versiones viejas instalaban passwords fijos públicos (`nagios2026`, `admin123`, `nagios2024`).
Si tu CT viene de esas versiones, rotalos (las instalaciones nuevas ya generan aleatorios):
```bash
pct exec <CTID> -- passwd                                   # root del CT
pct exec <CTID> -- htpasswd -b /usr/local/nagios/etc/htpasswd.users nagiosadmin NUEVA_CLAVE
# Panel: entrar como admin → Administración → editar usuario
```

## 📝 Licencia
Este proyecto es de código abierto y se distribuye bajo la licencia [GPLv3](./LICENSE).

