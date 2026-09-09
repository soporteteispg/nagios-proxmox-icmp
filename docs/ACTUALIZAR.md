# Actualizar un contenedor existente

Guía para llevar un CT ya instalado a la última versión del repo **sin reinstalar**.
Probado en producción (CT 200, `v1.0.0` → `v1.1.0`). Todo se ejecuta en el **nodo Proxmox** como `root`.
Reemplazá `<CTID>` por tu contenedor (empezá por el menos crítico).

> Si tu CT es anterior a `v1.0.0`, esta guía aplica igual: los cambios son compatibles
> hacia atrás (los passwords existentes no se tocan).

## Etapa 0 — Red de seguridad (siempre)

```bash
pct snapshot <CTID> pre-update
pct push <CTID> /root/Nagios/scripts/06-backup.sh /root/06-backup.sh
pct exec <CTID> -- bash /root/06-backup.sh
```

Si `/root/Nagios` no existe o está desactualizado en el nodo:

```bash
cd /root/Nagios && git pull   # o: git clone https://github.com/soporteteispg/nagios-proxmox-icmp.git /root/Nagios
```

Rollback si algo sale mal: `pct rollback <CTID> pre-update`.

## Etapa 1 — Panel web (sin downtime)

Actualiza `api.php` (fixes de seguridad) y el `.htaccess` (bloquea `auth.php`/`audit.log`).
No reinicia Nagios, solo recarga Apache.

```bash
pct push <CTID> /root/Nagios/webpanel/api.php /root/api.php.new
pct exec <CTID> -- cp /var/www/html/monitor/api.php /var/www/html/monitor/api.php.bak-pre
pct exec <CTID> -- cp /root/api.php.new /var/www/html/monitor/api.php
pct exec <CTID> -- php -l /var/www/html/monitor/api.php
```

`.htaccess`: bajalo, agregá al final los bloques `<Files>` (con finales de línea **LF**), subilo:

```bash
pct pull <CTID> /var/www/html/monitor/.htaccess ./htaccess.ct<CTID>
```

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

Verificación (con la IP del CT: `pct exec <CTID> -- hostname -I`):

```bash
curl -s -o /dev/null -w "audit.log -> %{http_code}\n" http://<IP>/monitor/audit.log
curl -s -o /dev/null -w "api sin token -> %{http_code}\n" "http://<IP>/monitor/api.php?action=status"
```

Esperado: `403` y `401`. Después en el navegador: login, agregar y borrar un host de prueba.

Rollback de esta etapa: `pct exec <CTID> -- cp /var/www/html/monitor/api.php.bak-pre /var/www/html/monitor/api.php && systemctl reload apache2`.

## Etapa 2 — RRD (solo si usás gráficos)

Si existe `/usr/local/nagios/var/rrd` con datos, re-ejecutá el `05` para el fix de logging.
Al final hace `systemctl restart nagios` (corte de segundos).

```bash
pct push <CTID> /root/Nagios/scripts/05-install-rrd.sh /root/05-install-rrd.sh
pct exec <CTID> -- bash /root/05-install-rrd.sh
pct exec <CTID> -- grep -n "logger" /usr/local/nagios/libexec/process_perfdata.sh
```

## Etapa 3 — Núcleo Nagios (ventana de mantenimiento)

Re-ejecutar el `02` recompila Nagios (5-15 min con el `apt upgrade`), reinicia el servicio y
**resetea el password de `nagiosadmin`** a uno aleatorio. El usuario del panel (`admin`) no se toca.

```bash
pct push <CTID> /root/Nagios/scripts/02-install-nagios.sh /root/02-install-nagios.sh
pct exec <CTID> -- bash -c 'bash /root/02-install-nagios.sh 2>&1 | tee /root/02-output.log'
```

Guardá el password nuevo del bloque final (no lo compartas). Si se pierde:
`pct exec <CTID> -- grep -A2 "Password" /root/02-output.log`.

Verificación:

```bash
pct exec <CTID> -- /usr/local/nagios/bin/nagios --version
pct exec <CTID> -- systemctl is-active nagios apache2
pct exec <CTID> -- /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg 2>&1 | tail -3
```

Y en el panel: los hosts salen de PENDING a UP/DOWN en unos minutos (hueco de RRD durante la compilación es normal).

## Etapa 4 — Dejar el cron (una sola vez)

```bash
pct exec <CTID> -- sh -c '(crontab -l 2>/dev/null; echo "0 3 * * * root /root/06-backup.sh >> /var/log/nagios-backup.log 2>&1") | crontab -'
pct exec <CTID> -- crontab -l
```
