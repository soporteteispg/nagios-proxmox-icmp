#!/bin/bash
# ============================================================
# Script: 04-install-webpanel.sh
# Descripción: Instala el panel web personalizado de Nagios
# Ejecutar en: DENTRO DEL CONTENEDOR LXC (después de instalar Nagios)
# Uso: bash 04-install-webpanel.sh
# ============================================================

set -e

PANEL_DIR="/var/www/html/monitor"
NAGIOS_HOSTS_DIR="/usr/local/nagios/etc/objects/hosts"

echo "============================================"
echo "  Instalando Panel Web de Monitoreo ICMP"
echo "============================================"
echo ""

# ---- 1. Crear directorio del panel ----
echo ">> [1/4] Creando directorio del panel..."
mkdir -p "$PANEL_DIR"

# Copiar archivos del panel
if [ -d "/root/webpanel" ]; then
    cp /root/webpanel/index.html "$PANEL_DIR/"
    cp /root/webpanel/style.css  "$PANEL_DIR/"
    cp /root/webpanel/app.js     "$PANEL_DIR/"
    cp /root/webpanel/api.php    "$PANEL_DIR/"
    echo "   ✅ Archivos del panel copiados"
else
    echo "   ❌ No se encontró /root/webpanel/"
    echo "   Copiar los archivos primero con:"
    echo "   pct push <CTID> webpanel/ /root/webpanel/"
    exit 1
fi

# ---- 2. Configurar permisos ----
echo ">> [2/4] Configurando permisos..."

# El panel web necesita que www-data pueda:
# - Leer archivos de configuración de Nagios
# - Escribir archivos .cfg en el directorio de hosts
# - Leer status.dat
# - Ejecutar nagios -v para validar config
# - Recargar nagios via systemctl

chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR"

# Asegurar que www-data pueda escribir en el directorio de hosts de Nagios
chown nagios:nagcmd "$NAGIOS_HOSTS_DIR"
chmod 775 "$NAGIOS_HOSTS_DIR"
usermod -a -G nagcmd www-data

# Permisos para status.dat
chmod 644 /usr/local/nagios/var/status.dat 2>/dev/null || true

# ---- 3. Configurar sudoers para www-data ----
echo ">> [3/4] Configurando permisos de administración..."

cat > /etc/sudoers.d/nagios-webpanel << 'EOF'
# Permitir que www-data recargue Nagios y valide configuración
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nagios
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nagios
www-data ALL=(ALL) NOPASSWD: /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
EOF

chmod 440 /etc/sudoers.d/nagios-webpanel
echo "   ✅ Permisos configurados"

# ---- 4. Configurar Apache para el panel ----
echo ">> [4/4] Configurando Apache..."

# Crear alias de Apache para /monitor
cat > /etc/apache2/conf-available/nagios-monitor.conf << 'EOF'
# Panel de Monitoreo ICMP
Alias /monitor /var/www/html/monitor

<Directory /var/www/html/monitor>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    # PHP settings
    <IfModule mod_php.c>
        php_value upload_max_filesize 2M
        php_value post_max_size 2M
    </IfModule>
</Directory>
EOF

a2enconf nagios-monitor > /dev/null 2>&1
systemctl reload apache2

echo ""
echo "============================================"
echo "  ✅ Panel Web instalado correctamente"
echo "============================================"
echo ""
echo "  Acceder al panel:"
echo "  http://$(hostname -I | awk '{print $1}')/monitor"
echo ""
echo "  Panel Nagios original:"
echo "  http://$(hostname -I | awk '{print $1}')/nagios"
echo ""
echo "  El panel permite:"
echo "  - Ver estado de todos los hosts en tiempo real"
echo "  - Agregar hosts desde la web (botón '+ Agregar Host')"
echo "  - Editar y eliminar hosts"
echo "  - Filtrar por internos/externos/con problemas"
echo "  - Auto-refresh configurable"
echo ""
