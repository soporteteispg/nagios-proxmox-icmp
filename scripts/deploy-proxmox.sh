#!/bin/bash
# ============================================================
# Script: deploy-proxmox.sh
# Descripción: Clona el repo y despliega Nagios en un LXC
# Ejecutar en: HOST PROXMOX como root
# Uso: bash deploy-proxmox.sh [URL_REPO]
#
# Si el repo es privado, usar:
#   bash deploy-proxmox.sh https://TOKEN@github.com/usuario/nagios-proxmox-icmp.git
# ============================================================

set -e

# ===================== CONFIGURACIÓN =====================
GITHUB_REPO="${1:-}"
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
    if [ -z "$GITHUB_REPO" ]; then
        echo ">> URL del repositorio no proporcionada."
        echo ""
        read -r -p "   Ingresá la URL del repositorio Git: " GITHUB_REPO
        if [ -z "$GITHUB_REPO" ]; then
            echo "   ERROR: URL requerida."
            echo "   Uso: bash deploy-proxmox.sh https://github.com/usuario/Nagios.git"
            exit 1
        fi
    fi
    echo ">> Clonando repositorio..."
    git clone "$GITHUB_REPO" "$CLONE_DIR"
    cd "$CLONE_DIR"
fi

echo "   ✅ Repositorio listo"

# ---- 3. Detectar contenedores existentes y elegir CTID ----
echo ""
echo ">> Contenedores existentes en este nodo:"
echo "   ─────────────────────────────────────"
EXISTING=$(pct list 2>/dev/null | tail -n +2)
if [ -z "$EXISTING" ]; then
    echo "   (ninguno)"
else
    echo "$EXISTING" | while read -r line; do
        echo "   $line"
    done
fi
echo "   ─────────────────────────────────────"
echo ""

# Encontrar el próximo CTID disponible (empezando desde 200)
CTID=200
while pct status $CTID &>/dev/null; do
    CTID=$((CTID + 1))
done

read -r -p ">> CTID sugerido: $CTID — ¿Usar este? (s/n o ingresá otro número): " CTID_INPUT
if [[ "$CTID_INPUT" =~ ^[0-9]+$ ]]; then
    CTID=$CTID_INPUT
elif [[ "$CTID_INPUT" != "s" && "$CTID_INPUT" != "S" && "$CTID_INPUT" != "" ]]; then
    echo "   Cancelado."
    exit 0
fi

# Verificar que el CTID elegido no esté en uso
if pct status "$CTID" &>/dev/null; then
    echo ""
    echo ">> El contenedor $CTID ya existe."
    pct status "$CTID"
    echo ""
    read -r -p "   ¿Continuar con el despliegue de archivos al contenedor existente? (s/n): " CONTINUAR
    if [[ "$CONTINUAR" != "s" && "$CONTINUAR" != "S" ]]; then
        echo "   Cancelado."
        exit 0
    fi
else
    echo ""
    echo ">> Storages disponibles en este nodo para contenedores:"
    echo "   ─────────────────────────────────────"
    STORAGES=$(pvesm status -content rootdir 2>/dev/null | tail -n +2 | awk '{print $1}')
    if [ -z "$STORAGES" ]; then
        echo "   (no se detectaron storages, se usará 'local-lvm' como fallback)"
        DEFAULT_STORAGE="local-lvm"
    else
        echo "$STORAGES" | while read -r s; do echo "   - $s"; done
        if echo "$STORAGES" | grep -q "^local-lvm$"; then
            DEFAULT_STORAGE="local-lvm"
        elif echo "$STORAGES" | grep -q "^local-zfs$"; then
            DEFAULT_STORAGE="local-zfs"
        else
            DEFAULT_STORAGE=$(echo "$STORAGES" | head -n 1)
        fi
    fi
    echo "   ─────────────────────────────────────"
    echo ""

    read -r -p ">> Storage sugerido: $DEFAULT_STORAGE — ¿Usar este? (s/n o ingresá el nombre de otro storage): " STORAGE_INPUT
    if [[ "$STORAGE_INPUT" == "s" || "$STORAGE_INPUT" == "S" || "$STORAGE_INPUT" == "" ]]; then
        STORAGE=$DEFAULT_STORAGE
    else
        STORAGE=$STORAGE_INPUT
    fi

    echo ""
    echo ">> Creando contenedor LXC con CTID=$CTID en storage '$STORAGE'..."
    export CTID
    export STORAGE
    CTID=$CTID STORAGE=$STORAGE bash "$CLONE_DIR/scripts/01-create-lxc.sh"
fi

# Verificar que el contenedor está corriendo
if ! pct status "$CTID" | grep -q "running"; then
    echo ">> Iniciando contenedor $CTID..."
    pct start "$CTID"
    sleep 5
fi

# ---- 4. Copiar archivos al contenedor ----
echo ""
echo ">> Copiando archivos al contenedor $CTID..."

# Scripts
echo "   📂 Scripts..."
pct push "$CTID" "$CLONE_DIR/scripts/02-install-nagios.sh" /root/02-install-nagios.sh
pct push "$CTID" "$CLONE_DIR/scripts/03-add-host.sh" /root/03-add-host.sh
pct push "$CTID" "$CLONE_DIR/scripts/04-install-webpanel.sh" /root/04-install-webpanel.sh

# Configuraciones
echo "   📂 Configuraciones..."
pct exec "$CTID" -- mkdir -p /root/config/hosts
pct push "$CTID" "$CLONE_DIR/config/templates.cfg" /root/config/templates.cfg
pct push "$CTID" "$CLONE_DIR/config/commands.cfg" /root/config/commands.cfg
pct push "$CTID" "$CLONE_DIR/config/contacts.cfg" /root/config/contacts.cfg
pct push "$CTID" "$CLONE_DIR/config/hosts/internal-hosts.cfg" /root/config/hosts/internal-hosts.cfg
pct push "$CTID" "$CLONE_DIR/config/hosts/external-hosts.cfg" /root/config/hosts/external-hosts.cfg

# Panel Web
echo "   📂 Panel web..."
pct exec "$CTID" -- mkdir -p /root/webpanel
pct push "$CTID" "$CLONE_DIR/webpanel/index.html" /root/webpanel/index.html
pct push "$CTID" "$CLONE_DIR/webpanel/style.css" /root/webpanel/style.css
pct push "$CTID" "$CLONE_DIR/webpanel/app.js" /root/webpanel/app.js
pct push "$CTID" "$CLONE_DIR/webpanel/api.php" /root/webpanel/api.php

echo "   ✅ Todos los archivos copiados"

# ---- 5. Obtener IP y Esperar Nateo ----
echo ""
echo "============================================"
echo "  📌 CONFIGURACIÓN DE RED (NATEO)"
echo "============================================"
CONTAINER_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo "  El contenedor $CTID ya está corriendo con la IP:"
echo "  → $CONTAINER_IP"
echo ""
echo "  ⚠️ IMPORTANTE:"
echo "  Si necesitas acceder desde afuera (Internet) y vas a mapear"
echo "  un puerto en tu router hacia esta IP local ($CONTAINER_IP),"
echo "  este es el momento ideal para hacerlo ANTES de instalar Nagios."
echo ""
read -r -p "  ¿Ya configuraste el router/NAT o querés continuar con la instalación? (s/n): " CONTINUAR_INSTALL
if [[ "$CONTINUAR_INSTALL" != "s" && "$CONTINUAR_INSTALL" != "S" ]]; then
    echo "  Instalación de paquetes pausada. Podés resuming ejecutando manualmente:"
    echo "  pct exec $CTID -- bash /root/02-install-nagios.sh"
    echo "  pct exec $CTID -- bash /root/04-install-webpanel.sh"
    exit 0
fi

# ---- 6. Instalar Nagios y Webpanel ----
echo ""
echo "============================================"
echo "  📦 Instalando Nagios Core..."
echo "  (esto tarda ~5-10 minutos)"
echo "============================================"
echo ""
pct exec "$CTID" -- bash /root/02-install-nagios.sh

echo ""
echo ">> Instalando Panel Web..."
pct exec "$CTID" -- bash /root/04-install-webpanel.sh

# ---- 7. Finalización ----

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
