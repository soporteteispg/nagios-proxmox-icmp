#!/bin/bash
# ============================================================
# Script: 01-create-lxc.sh
# Descripción: Crea un contenedor LXC en Proxmox para Nagios
# Ejecutar en: HOST PROXMOX (no dentro de un contenedor)
# Uso: bash 01-create-lxc.sh
# ============================================================

set -e

# ===================== CONFIGURACIÓN =====================
# Modificar estos valores según tu entorno

CTID=200                              # ID del contenedor
HOSTNAME="nagios"                     # Nombre del contenedor
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"  # Template Debian 12
STORAGE="local-lvm"                   # Storage para el disco
DISK_SIZE=8                           # Tamaño del disco en GB
RAM=1024                              # RAM en MB
SWAP=512                              # SWAP en MB
CORES=2                               # Núcleos CPU
BRIDGE="vmbr0"                        # Bridge de red
IP="192.168.1.50/24"                  # IP del contenedor (CAMBIAR)
GATEWAY="192.168.1.1"                 # Gateway (CAMBIAR)
DNS="8.8.8.8"                         # DNS
PASSWORD="nagios2026"                 # Contraseña root del contenedor (CAMBIAR)
# =========================================================

echo "============================================"
echo "  Creando contenedor LXC para Nagios Core"
echo "============================================"
echo ""
echo "  CTID:     $CTID"
echo "  Hostname: $HOSTNAME"
echo "  IP:       $IP"
echo "  Gateway:  $GATEWAY"
echo "  RAM:      ${RAM}MB | Disco: ${DISK_SIZE}GB"
echo ""

# Verificar que el CTID no esté en uso
if pct status $CTID &>/dev/null; then
    echo "ERROR: El contenedor $CTID ya existe."
    echo "Usa otro CTID o elimina el existente con: pct destroy $CTID"
    exit 1
fi

# Verificar que el template existe
if ! pveam list local | grep -q "debian-12"; then
    echo "Template Debian 12 no encontrado. Descargando..."
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
fi

# Crear el contenedor
echo ">> Creando contenedor..."
pct create $CTID $TEMPLATE \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs ${STORAGE}:${DISK_SIZE} \
    --memory $RAM \
    --swap $SWAP \
    --cores $CORES \
    --net0 name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY} \
    --nameserver $DNS \
    --password $PASSWORD \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo ">> Contenedor creado exitosamente."

# Iniciar el contenedor
echo ">> Iniciando contenedor..."
pct start $CTID

# Esperar a que arranque
echo ">> Esperando que el contenedor inicie..."
sleep 5

# Verificar que está corriendo
if pct status $CTID | grep -q "running"; then
    echo ""
    echo "============================================"
    echo "  ✅ Contenedor $CTID creado y corriendo"
    echo "============================================"
    echo ""
    echo "  Siguiente paso:"
    echo "  1. Copiar los archivos al contenedor:"
    echo "     pct push $CTID 02-install-nagios.sh /root/02-install-nagios.sh"
    echo ""
    echo "  2. Entrar al contenedor:"
    echo "     pct enter $CTID"
    echo ""
    echo "  3. Ejecutar la instalación:"
    echo "     bash /root/02-install-nagios.sh"
    echo ""
else
    echo "ERROR: El contenedor no pudo iniciar. Verificar con: pct status $CTID"
    exit 1
fi
