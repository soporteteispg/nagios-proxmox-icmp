#!/bin/bash
# ============================================================
# Script: 02-install-nagios.sh
# Descripción: Instala Nagios Core + Plugins en Debian 12 LXC
# Ejecutar en: DENTRO DEL CONTENEDOR LXC
# Uso: bash 02-install-nagios.sh
# ============================================================

set -e

# ===================== CONFIGURACIÓN =====================
NAGIOS_VERSION="4.5.7"
PLUGINS_VERSION="2.4.12"
NAGIOS_ADMIN_PASS="admin123"          # Contraseña para la web (CAMBIAR)
ADMIN_EMAIL="admin@tudominio.com"     # Email de notificaciones (CAMBIAR)
# =========================================================

NAGIOS_URL="https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${NAGIOS_VERSION}/nagios-${NAGIOS_VERSION}.tar.gz"
PLUGINS_URL="https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${PLUGINS_VERSION}/nagios-plugins-${PLUGINS_VERSION}.tar.gz"

echo "============================================"
echo "  Instalando Nagios Core $NAGIOS_VERSION"
echo "  + Plugins $PLUGINS_VERSION"
echo "============================================"
echo ""

# ---- 1. Actualizar sistema e instalar dependencias ----
echo ">> [1/8] Instalando dependencias..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    autoconf \
    gcc \
    libc6 \
    make \
    wget \
    unzip \
    apache2 \
    apache2-utils \
    php \
    libapache2-mod-php \
    libgd-dev \
    libssl-dev \
    libmcrypt-dev \
    bc \
    gawk \
    dc \
    build-essential \
    snmp \
    libnet-snmp-perl \
    gettext \
    fping \
    iputils-ping \
    curl

echo "   ✅ Dependencias instaladas"

# ---- 2. Crear usuario y grupo Nagios ----
echo ">> [2/8] Creando usuario nagios..."
if ! id nagios &>/dev/null; then
    useradd -m -s /bin/bash nagios
fi
if ! getent group nagcmd &>/dev/null; then
    groupadd nagcmd
fi
usermod -a -G nagcmd nagios
usermod -a -G nagcmd www-data
echo "   ✅ Usuario y grupos creados"

# ---- 3. Descargar Nagios Core ----
echo ">> [3/8] Descargando Nagios Core ${NAGIOS_VERSION}..."
cd /tmp
if [ ! -f "nagios-${NAGIOS_VERSION}.tar.gz" ]; then
    wget -q "$NAGIOS_URL" -O "nagios-${NAGIOS_VERSION}.tar.gz"
fi
tar -xzf "nagios-${NAGIOS_VERSION}.tar.gz"
echo "   ✅ Descargado"

# ---- 4. Compilar e instalar Nagios Core ----
echo ">> [4/8] Compilando Nagios Core (puede tomar unos minutos)..."
cd "/tmp/nagios-${NAGIOS_VERSION}"
./configure --with-httpd-conf=/etc/apache2/sites-enabled \
            --with-command-group=nagcmd \
            > /dev/null 2>&1
make all > /dev/null 2>&1
make install > /dev/null 2>&1
make install-daemoninit > /dev/null 2>&1
make install-commandmode > /dev/null 2>&1
make install-config > /dev/null 2>&1
make install-webconf > /dev/null 2>&1
echo "   ✅ Nagios Core instalado"

# ---- 5. Descargar e instalar Plugins ----
echo ">> [5/8] Descargando e instalando Plugins ${PLUGINS_VERSION}..."
cd /tmp
if [ ! -f "nagios-plugins-${PLUGINS_VERSION}.tar.gz" ]; then
    wget -q "$PLUGINS_URL" -O "nagios-plugins-${PLUGINS_VERSION}.tar.gz"
fi
tar -xzf "nagios-plugins-${PLUGINS_VERSION}.tar.gz"
cd "/tmp/nagios-plugins-${PLUGINS_VERSION}"
./configure --with-nagios-user=nagios --with-nagios-group=nagios > /dev/null 2>&1
make > /dev/null 2>&1
make install > /dev/null 2>&1
echo "   ✅ Plugins instalados"

# ---- 6. Configurar Apache ----
echo ">> [6/8] Configurando Apache..."
a2enmod rewrite > /dev/null 2>&1
a2enmod cgi > /dev/null 2>&1

# Crear usuario nagiosadmin para la web
htpasswd -b -c /usr/local/nagios/etc/htpasswd.users nagiosadmin "$NAGIOS_ADMIN_PASS"
echo "   ✅ Apache configurado (usuario: nagiosadmin)"

# ---- 7. Configurar Nagios ----
echo ">> [7/8] Aplicando configuración de monitoreo..."

# Crear directorio para hosts personalizados
mkdir -p /usr/local/nagios/etc/objects/hosts

# Agregar la línea cfg_dir para cargar configs de hosts
if ! grep -q "cfg_dir=/usr/local/nagios/etc/objects/hosts" /usr/local/nagios/etc/nagios.cfg; then
    echo "" >> /usr/local/nagios/etc/nagios.cfg
    echo "# Directorio de hosts personalizados" >> /usr/local/nagios/etc/nagios.cfg
    echo "cfg_dir=/usr/local/nagios/etc/objects/hosts" >> /usr/local/nagios/etc/nagios.cfg
fi

# Copiar archivos de configuración si existen en /root/config/
if [ -d "/root/config" ]; then
    echo "   Copiando archivos de configuración personalizados..."

    # Templates y comandos
    [ -f "/root/config/templates.cfg" ] && \
        cp /root/config/templates.cfg /usr/local/nagios/etc/objects/templates_custom.cfg
    [ -f "/root/config/commands.cfg" ] && \
        cp /root/config/commands.cfg /usr/local/nagios/etc/objects/commands_custom.cfg
    [ -f "/root/config/contacts.cfg" ] && \
        cp /root/config/contacts.cfg /usr/local/nagios/etc/objects/contacts.cfg

    # Agregar las configs personalizadas al nagios.cfg
    for cfg in templates_custom.cfg commands_custom.cfg; do
        cfg_path="/usr/local/nagios/etc/objects/$cfg"
        if [ -f "$cfg_path" ] && ! grep -q "$cfg_path" /usr/local/nagios/etc/nagios.cfg; then
            echo "cfg_file=$cfg_path" >> /usr/local/nagios/etc/nagios.cfg
        fi
    done

    # Copiar hosts
    if [ -d "/root/config/hosts" ]; then
        cp /root/config/hosts/*.cfg /usr/local/nagios/etc/objects/hosts/ 2>/dev/null || true
    fi

    echo "   ✅ Configuración personalizada aplicada"
else
    echo "   ⚠️  No se encontró /root/config/ — usando configuración por defecto"
    echo "   Puedes copiar los archivos después y reiniciar nagios"
fi

# Ajustar permisos
chown -R nagios:nagios /usr/local/nagios/etc/
chmod -R 664 /usr/local/nagios/etc/objects/*.cfg 2>/dev/null || true
chmod -R 664 /usr/local/nagios/etc/objects/hosts/*.cfg 2>/dev/null || true
chown -R nagios:nagios /usr/local/nagios/etc/objects/

# ---- 8. Iniciar servicios ----
echo ">> [8/8] Iniciando servicios..."

# Validar configuración
echo "   Validando configuración..."
if /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg | tail -1 | grep -q "Things look okay"; then
    echo "   ✅ Configuración válida"
else
    echo "   ⚠️  Hay errores en la configuración. Revisalos con:"
    echo "   /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg"
fi

systemctl restart apache2
systemctl enable nagios
systemctl start nagios

echo ""
echo "============================================"
echo "  ✅ INSTALACIÓN COMPLETADA"
echo "============================================"
echo ""
echo "  Interfaz Web:"
echo "  URL:      http://$(hostname -I | awk '{print $1}')/nagios"
echo "  Usuario:  nagiosadmin"
echo "  Password: $NAGIOS_ADMIN_PASS"
echo ""
echo "  Comandos útiles:"
echo "  - Ver estado:    systemctl status nagios"
echo "  - Reiniciar:     systemctl restart nagios"
echo "  - Validar cfg:   /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg"
echo ""
echo "  Para agregar hosts:"
echo "  - Editar archivos en /usr/local/nagios/etc/objects/hosts/"
echo "  - O usar el script 03-add-host.sh"
echo ""

# Limpiar archivos temporales
rm -rf /tmp/nagios-${NAGIOS_VERSION} /tmp/nagios-plugins-${PLUGINS_VERSION}
rm -f /tmp/nagios-${NAGIOS_VERSION}.tar.gz /tmp/nagios-plugins-${PLUGINS_VERSION}.tar.gz
