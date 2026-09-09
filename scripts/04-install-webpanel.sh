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
    
    # Crear auth.php con credenciales por defecto si no existe
    if [ ! -f "$PANEL_DIR/auth.php" ] && [ -f "/root/webpanel/auth.php" ]; then
        cp /root/webpanel/auth.php "$PANEL_DIR/"
    elif [ ! -f "$PANEL_DIR/auth.php" ]; then
        # SEGURIDAD: contraseña inicial ALEATORIA (no fija). Se muestra al final
        # de la instalación por única vez; cambiarla en el panel (Administración).
        # Se puede prefijar con: PANEL_ADMIN_PASS=... bash 04-install-webpanel.sh
        PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)}"
        # Generar hash real en el servidor usando PHP CLI
        DEFAULT_HASH=$(php -r "echo password_hash('$PANEL_ADMIN_PASS', PASSWORD_DEFAULT);")
        cat << EOF > "$PANEL_DIR/auth.php"
<?php
// Archivo de credenciales de Nagios Web Panel
// Este archivo NO debe ser accesible públicamente (ver .htaccess).
return [
    'users' => [
        'admin' => [
            'hash' => '$DEFAULT_HASH',
            'role' => 'root'
        ]
    ]
];
EOF
    fi

    # Crear .htaccess para asegurar que el header Authorization llegue a PHP (Token Auth)
    cat << EOF > "$PANEL_DIR/.htaccess"
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteCond %{HTTP:Authorization} ^(.*)
RewriteRule .* - [e=HTTP_AUTHORIZATION:%1]
</IfModule>
SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1
CGIPassAuth On

# SEGURIDAD: la API los lee por filesystem, nadie debe descargarlos por HTTP
<Files "auth.php">
    Require all denied
</Files>
<Files "audit.log">
    Require all denied
</Files>
EOF

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

chgrp -R www-data "$PANEL_DIR"
find "$PANEL_DIR" -type f -exec chmod 644 {} \;
find "$PANEL_DIR" -type d -exec chmod 755 {} \;
if [ -f "$PANEL_DIR/auth.php" ]; then
    chmod 640 "$PANEL_DIR/auth.php"
fi
chmod 644 "$PANEL_DIR/.htaccess"

# Archivos de Nagios a los que el grupo www-data debe tener acceso
chmod -R g+r "$NAGIOS_HOSTS_DIR"
chown nagios:nagcmd "$NAGIOS_HOSTS_DIR"
chmod 775 "$NAGIOS_HOSTS_DIR"
usermod -a -G nagcmd www-data

# Permisos para status.dat
chmod 644 /usr/local/nagios/var/status.dat 2>/dev/null || true

# ---- 3. Configurar sudoers para www-data ----
echo ">> [3/4] Configurando permisos de administración..."

# Instalar sudo si no está
if ! command -v sudo &> /dev/null; then
    apt-get install -y -qq sudo
fi
mkdir -p /etc/sudoers.d

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
if [ -n "${PANEL_ADMIN_PASS:-}" ]; then
    echo "  Credenciales iniciales (solo se muestran esta vez):"
    echo "  Usuario:  admin"
    echo "  Password: $PANEL_ADMIN_PASS"
    echo "  Cambiala en el panel (Administración) ni bien entres."
    echo ""
fi
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
