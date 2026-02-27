#!/bin/bash
# ============================================================
# Script: 03-add-host.sh
# Descripción: Agrega un host al monitoreo ICMP de Nagios
# Ejecutar en: DENTRO DEL CONTENEDOR LXC (donde corre Nagios)
# Uso: bash 03-add-host.sh
# ============================================================

HOSTS_DIR="/usr/local/nagios/etc/objects/hosts"
NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"

echo "============================================"
echo "  Agregar Host al Monitoreo ICMP"
echo "============================================"
echo ""

# Solicitar datos
read -r -p "Nombre del host (sin espacios, ej: servidor-web): " HOST_NAME
read -r -p "Descripción (alias, ej: Servidor Web Principal): " HOST_ALIAS
read -r -p "Dirección IP o dominio: " HOST_ADDRESS

echo ""
echo "Tipo de host:"
echo "  1) Interno (red local)"
echo "  2) Externo (internet)"
read -r -p "Seleccionar [1/2]: " HOST_TYPE

echo ""
echo "Nivel de monitoreo:"
echo "  1) Normal      - 10 paquetes, warning 100ms/20%, critical 500ms/60%"
echo "  2) Detallado   - 20 paquetes, warning 80ms/10%, critical 300ms/40%"
echo "  3) Estricto    - 10 paquetes, warning 50ms/5%, critical 200ms/20%"
read -r -p "Seleccionar [1/2/3]: " CHECK_LEVEL

# Determinar template y comando
if [ "$HOST_TYPE" == "1" ]; then
    TEMPLATE="icmp-host-internal"
else
    TEMPLATE="icmp-host-external"
fi

case $CHECK_LEVEL in
    1) CHECK_CMD="check_host_ping!100.0,20%!500.0,60%!10" ;;
    2) CHECK_CMD="check_ping_detailed" ;;
    3) CHECK_CMD="check_ping_strict" ;;
    *) CHECK_CMD="check_host_ping!100.0,20%!500.0,60%!10" ;;
esac

# Host padre (opcional, para internos)
PARENT_LINE=""
if [ "$HOST_TYPE" == "1" ]; then
    read -r -p "Host padre (ej: gateway, o dejar vacío): " PARENT
    if [ -n "$PARENT" ]; then
        PARENT_LINE="    parents                 $PARENT"
    fi
fi

# Generar archivo de configuración
CFG_FILE="${HOSTS_DIR}/${HOST_NAME}.cfg"

if [ -f "$CFG_FILE" ]; then
    echo ""
    echo "ERROR: El host '$HOST_NAME' ya existe en $CFG_FILE"
    exit 1
fi

cat > "$CFG_FILE" << EOF
# Host agregado el $(date '+%Y-%m-%d %H:%M')
define host {
    use                     $TEMPLATE
    host_name               $HOST_NAME
    alias                   $HOST_ALIAS
    address                 $HOST_ADDRESS
$PARENT_LINE
}

define service {
    use                     icmp-ping-service
    host_name               $HOST_NAME
    service_description     PING - Latencia y Pérdida de Paquetes
    check_command           $CHECK_CMD
}
EOF

# Ajustar permisos
chown nagios:nagios "$CFG_FILE"
chmod 664 "$CFG_FILE"

# Validar configuración
echo ""
echo ">> Validando configuración..."
if $NAGIOS_BIN -v $NAGIOS_CFG 2>&1 | tail -1 | grep -q "Things look okay"; then
    echo "   ✅ Configuración válida"
    echo ""
    read -r -p "¿Reiniciar Nagios ahora para aplicar cambios? [s/n]: " RESTART
    if [ "$RESTART" == "s" ] || [ "$RESTART" == "S" ]; then
        systemctl reload nagios
        echo "   ✅ Nagios reiniciado. El host aparecerá en la interfaz web."
    else
        echo "   Reiniciar más tarde con: systemctl reload nagios"
    fi
else
    echo "   ❌ Error en la configuración. Revisando..."
    $NAGIOS_BIN -v $NAGIOS_CFG 2>&1 | grep -i "error"
    echo ""
    echo "   Eliminando archivo generado..."
    rm -f "$CFG_FILE"
    echo "   Corregir el error e intentar de nuevo."
fi

echo ""
echo "============================================"
echo "  Host: $HOST_NAME ($HOST_ADDRESS)"
echo "  Archivo: $CFG_FILE"
echo "============================================"
