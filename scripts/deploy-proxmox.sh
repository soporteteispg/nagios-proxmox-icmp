#!/bin/bash
# ============================================================
# Script: deploy-proxmox.sh
# Descripción: Clona el repo privado y despliega todo en un LXC
# Ejecutar en: HOST PROXMOX como root
# Uso: bash deploy-proxmox.sh
# ============================================================

set -e

# ===================== CONFIGURACIÓN =====================
CTID=200
GITHUB_REPO="https://github.com/soporteteispg/Nagios.git"
CLONE_DIR="/root/Nagios"
# =========================================================

echo "============================================"
echo "  🚀 Deploy Nagios ICMP — Proxmox"
echo "============================================"
echo ""

# ---- 1. Instalar git si no está ----
if ! command -v git &> /dev/null; then
    echo ">> Instalando git..."
    apt-get update -qq && apt-get install -y -qq git
fi

# ---- 2. Clonar el repositorio ----
if [ -d "$CLONE_DIR" ]; then
    echo ">> Directorio $CLONE_DIR ya existe. Actualizando..."
    cd "$CLONE_DIR"
    git pull
else
    echo ">> Clonando repositorio privado..."
    echo "   Ingresá tu Personal Access Token (PAT) de GitHub cuando pida la contraseña."
    echo ""
    git clone "$GITHUB_REPO" "$CLONE_DIR"
    cd "$CLONE_DIR"
fi

echo "   ✅ Repositorio listo"

# ---- 3. Crear contenedor LXC si no existe ----
if pct status $CTID &>/dev/null; then
    echo ""
    echo ">> El contenedor $CTID ya existe."
    pct status $CTID
    echo ""
    read -p "   ¿Continuar con el despliegue de archivos? (s/n): " CONTINUAR
    if [[ "$CONTINUAR" != "s" && "$CONTINUAR" != "S" ]]; then
        echo "   Cancelado."
        exit 0
    fi
else
    echo ""
    echo ">> Creando contenedor LXC..."
    bash "$CLONE_DIR/scripts/01-create-lxc.sh"
fi

# Verificar que el contenedor está corriendo
if ! pct status $CTID | grep -q "running"; then
    echo ">> Iniciando contenedor $CTID..."
    pct start $CTID
    sleep 5
fi

# ---- 4. Copiar archivos al contenedor ----
echo ""
echo ">> Copiando archivos al contenedor $CTID..."

# Scripts
echo "   📂 Scripts..."
pct push $CTID "$CLONE_DIR/scripts/02-install-nagios.sh" /root/02-install-nagios.sh
pct push $CTID "$CLONE_DIR/scripts/03-add-host.sh" /root/03-add-host.sh
pct push $CTID "$CLONE_DIR/scripts/04-install-webpanel.sh" /root/04-install-webpanel.sh

# Configuraciones
echo "   📂 Configuraciones..."
pct exec $CTID -- mkdir -p /root/config/hosts
pct push $CTID "$CLONE_DIR/config/templates.cfg" /root/config/templates.cfg
pct push $CTID "$CLONE_DIR/config/commands.cfg" /root/config/commands.cfg
pct push $CTID "$CLONE_DIR/config/contacts.cfg" /root/config/contacts.cfg
pct push $CTID "$CLONE_DIR/config/hosts/internal-hosts.cfg" /root/config/hosts/internal-hosts.cfg
pct push $CTID "$CLONE_DIR/config/hosts/external-hosts.cfg" /root/config/hosts/external-hosts.cfg

# Panel Web
echo "   📂 Panel web..."
pct exec $CTID -- mkdir -p /root/webpanel
pct push $CTID "$CLONE_DIR/webpanel/index.html" /root/webpanel/index.html
pct push $CTID "$CLONE_DIR/webpanel/style.css" /root/webpanel/style.css
pct push $CTID "$CLONE_DIR/webpanel/app.js" /root/webpanel/app.js
pct push $CTID "$CLONE_DIR/webpanel/api.php" /root/webpanel/api.php

echo "   ✅ Todos los archivos copiados"

# ---- 5. Instalar Nagios ----
echo ""
echo "============================================"
echo "  📦 Instalando Nagios Core..."
echo "  (esto tarda ~5-10 minutos)"
echo "============================================"
echo ""
pct exec $CTID -- bash /root/02-install-nagios.sh

# ---- 6. Instalar Panel Web ----
echo ""
echo ">> Instalando Panel Web..."
pct exec $CTID -- bash /root/04-install-webpanel.sh

# ---- 7. Obtener IP del contenedor ----
CONTAINER_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo ""
echo "============================================"
echo "  ✅ DESPLIEGUE COMPLETADO"
echo "============================================"
echo ""
echo "  Panel de Monitoreo:"
echo "  → http://${CONTAINER_IP}/monitor"
echo ""
echo "  Nagios Web (interfaz original):"
echo "  → http://${CONTAINER_IP}/nagios"
echo "  → Usuario: nagiosadmin"
echo "  → Password: admin123"
echo ""
echo "  Comandos útiles:"
echo "  pct enter $CTID              # Entrar al contenedor"
echo "  pct exec $CTID -- systemctl status nagios"
echo ""
