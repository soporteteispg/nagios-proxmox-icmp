#!/bin/bash
# ============================================================
# Script: 06-backup.sh
# Descripción: Backup de Nagios ICMP (hosts, configs, panel, RRD).
# Ejecutar en: DENTRO DEL CONTENEDOR LXC (donde corre Nagios)
# Uso: bash 06-backup.sh [destino]
#      Destino por defecto: /root/backups/nagios (retención 14 días)
#      Variables opcionales:
#        NAGIOS_DIR=/usr/local/nagios PANEL_DIR=/var/www/html/monitor
#        BACKUP_RETENTION=30 bash 06-backup.sh /mnt/pve/backups
# Cron sugerido (diario 3 AM):
#   0 3 * * * root /root/06-backup.sh >> /var/log/nagios-backup.log 2>&1
# Restore: ver README (sección Backup) o el mensaje al final.
# ============================================================

set -e

NAGIOS_DIR="${NAGIOS_DIR:-/usr/local/nagios}"
PANEL_DIR="${PANEL_DIR:-/var/www/html/monitor}"
BACKUP_BASE="${1:-/root/backups/nagios}"
RETENTION_DAYS="${BACKUP_RETENTION:-14}"

TS=$(date +%Y%m%d-%H%M%S)
WORK="$BACKUP_BASE/.tmp-$TS"
mkdir -p "$WORK" "$BACKUP_BASE"

echo "============================================"
echo "  Backup Nagios ICMP - $TS"
echo "============================================"

# ---- 1. nagios.cfg principal ----
if [ -f "$NAGIOS_DIR/etc/nagios.cfg" ]; then
    cp "$NAGIOS_DIR/etc/nagios.cfg" "$WORK/"
    echo "   ✅ nagios.cfg"
else
    echo "   ⚠️  No existe $NAGIOS_DIR/etc/nagios.cfg (¿NAGIOS_DIR correcto?). Sigo igual."
fi

# ---- 2. Objetos: hosts + customs + auth web de Nagios ----
mkdir -p "$WORK/objects"
if [ -d "$NAGIOS_DIR/etc/objects/hosts" ]; then
    cp -r "$NAGIOS_DIR/etc/objects/hosts" "$WORK/objects/"
    HOST_COUNT=$(find "$NAGIOS_DIR/etc/objects/hosts" -maxdepth 1 -name '*.cfg' 2>/dev/null | wc -l)
    echo "   ✅ hosts ($HOST_COUNT archivos)"
fi
for f in templates_custom.cfg commands_custom.cfg contacts_custom.cfg commands_perfdata.cfg; do
    if [ -f "$NAGIOS_DIR/etc/objects/$f" ]; then
        cp "$NAGIOS_DIR/etc/objects/$f" "$WORK/objects/"
    fi
done
for f in htpasswd.users cgi.cfg resource.cfg; do
    if [ -f "$NAGIOS_DIR/etc/$f" ]; then
        cp "$NAGIOS_DIR/etc/$f" "$WORK/"
    fi
done

# ---- 3. Panel web: usuarios + auditoría + .htaccess ----
mkdir -p "$WORK/panel"
for f in auth.php audit.log .htaccess; do
    if [ -f "$PANEL_DIR/$f" ]; then
        cp "$PANEL_DIR/$f" "$WORK/panel/"
    fi
done
if [ -f "$WORK/panel/auth.php" ]; then
    echo "   ✅ panel (auth.php + audit.log)"
else
    echo "   ⚠️  No se encontró $PANEL_DIR/auth.php (¿PANEL_DIR correcto?)."
fi

# ---- 4. RRD (opcional, puede pesar) ----
if [ -d "$NAGIOS_DIR/var/rrd" ] && [ -n "$(ls -A "$NAGIOS_DIR/var/rrd" 2>/dev/null)" ]; then
    mkdir -p "$WORK/var"
    cp -r "$NAGIOS_DIR/var/rrd" "$WORK/var/"
    echo "   ✅ RRD incluido ($(du -sh "$NAGIOS_DIR/var/rrd" | cut -f1))"
else
    echo "   ⏭️  Sin RRD (omitido)"
fi

# ---- 5. Empaquetar + verificar integridad ----
TGZ="$BACKUP_BASE/nagios-$TS.tgz"
tar -czf "$TGZ" -C "$WORK" .
tar -tzf "$TGZ" > /dev/null
rm -rf "$WORK"

# ---- 6. Retención ----
find "$BACKUP_BASE" -maxdepth 1 -name 'nagios-*.tgz' -mtime +"$RETENTION_DAYS" -delete
COUNT=$(find "$BACKUP_BASE" -maxdepth 1 -name 'nagios-*.tgz' 2>/dev/null | wc -l)

echo ""
echo "============================================"
echo "  ✅ BACKUP OK"
echo "============================================"
echo "  Archivo:   $TGZ ($(du -h "$TGZ" | cut -f1))"
echo "  Retención: $RETENTION_DAYS días ($COUNT backups guardados)"
echo ""
echo "  Restore rápido:"
echo "    tar -xzf $TGZ -C /tmp/restore"
echo "    cp -r /tmp/restore/objects/hosts/* $NAGIOS_DIR/etc/objects/hosts/"
echo "    cp /tmp/restore/panel/auth.php $PANEL_DIR/   # si hace falta"
echo "    $NAGIOS_DIR/bin/nagios -v $NAGIOS_DIR/etc/nagios.cfg && systemctl reload nagios"
echo ""
echo "  Cron sugerido:"
echo "    0 3 * * * root /root/06-backup.sh >> /var/log/nagios-backup.log 2>&1"
echo ""
