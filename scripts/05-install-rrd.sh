#!/bin/bash
# ============================================================
# Script: 05-install-rrd.sh
# Descripción: Instala rrdtool y configura procesamiento de
#              performance data de Nagios en archivos RRD.
# Ejecutar en: DENTRO DEL CONTENEDOR LXC (después de instalar Nagios)
# Uso: bash 05-install-rrd.sh
# ============================================================

set -e

RRD_DIR="/usr/local/nagios/var/rrd"
PERFDATA_SCRIPT="/usr/local/nagios/libexec/process_perfdata.sh"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"

echo "============================================"
echo "  Instalando RRDTool + Performance Data"
echo "============================================"
echo ""

# ---- 1. Instalar dependencias ----
echo ">> [1/4] Instalando rrdtool..."
apt-get update -qq
apt-get install -y -qq rrdtool librrd-dev php-xml
echo "   ✅ rrdtool instalado"

# ---- 2. Crear directorio RRD ----
echo ">> [2/4] Creando directorio de datos RRD..."
mkdir -p "$RRD_DIR"
chown nagios:nagcmd "$RRD_DIR"
chmod 775 "$RRD_DIR"
echo "   ✅ Directorio $RRD_DIR creado"

# ---- 3. Crear script de procesamiento de perfdata ----
echo ">> [3/4] Creando script de procesamiento..."

cat > "$PERFDATA_SCRIPT" << 'SCRIPT'
#!/bin/bash
# ============================================================
# process_perfdata.sh
# Procesa performance data de Nagios y la almacena en RRD
# Usado tanto para host como para service perfdata
# ============================================================

RRD_DIR="/usr/local/nagios/var/rrd"

# Argumentos pasados por Nagios via macros
HOSTNAME="$1"
SERVICEDESC="$2"
PERFDATA="$3"
TIMESTAMP="$4"

# Limpiar hostname para usar como nombre de archivo
SAFE_HOST=$(echo "$HOSTNAME" | sed 's/[^a-zA-Z0-9_-]/_/g')

# Si no hay perfdata, salir
[ -z "$PERFDATA" ] && exit 0

# Extraer RTA y packet loss de la perfdata
# Formato típico: rta=1.234ms;100.000;500.000;0; pl=0%;20;60;;
RTA=""
PL=""

if echo "$PERFDATA" | grep -qoP 'rta=[\d.]+'; then
    RTA=$(echo "$PERFDATA" | grep -oP 'rta=\K[\d.]+')
fi

if echo "$PERFDATA" | grep -qoP 'pl=[\d.]+'; then
    PL=$(echo "$PERFDATA" | grep -oP 'pl=\K[\d.]+')
fi

# Si no se encontraron métricas de ping, intentar formato alternativo
if [ -z "$RTA" ] && echo "$PERFDATA" | grep -qoP 'time=[\d.]+'; then
    RTA=$(echo "$PERFDATA" | grep -oP 'time=\K[\d.]+')
fi

# Si no hay datos útiles, salir
[ -z "$RTA" ] && [ -z "$PL" ] && exit 0

# Valores por defecto
RTA=${RTA:-"U"}
PL=${PL:-"U"}

RRD_FILE="$RRD_DIR/${SAFE_HOST}.rrd"

# Crear archivo RRD si no existe
if [ ! -f "$RRD_FILE" ]; then
    rrdtool create "$RRD_FILE" \
        --step 300 \
        DS:rta:GAUGE:600:0:10000 \
        DS:pl:GAUGE:600:0:100 \
        RRA:AVERAGE:0.5:1:576 \
        RRA:AVERAGE:0.5:6:672 \
        RRA:AVERAGE:0.5:24:732 \
        RRA:AVERAGE:0.5:288:1460 \
        RRA:MAX:0.5:1:576 \
        RRA:MAX:0.5:6:672 \
        RRA:MAX:0.5:24:732 \
        RRA:MAX:0.5:288:1460 \
        RRA:MIN:0.5:1:576 \
        RRA:MIN:0.5:6:672 \
        RRA:MIN:0.5:24:732 \
        RRA:MIN:0.5:288:1460

    chown nagios:nagcmd "$RRD_FILE"
    chmod 664 "$RRD_FILE"
fi

# Actualizar RRD
# Usar timestamp actual o N para "ahora"
TS="${TIMESTAMP:-N}"
rrdtool update "$RRD_FILE" "${TS}:${RTA}:${PL}" 2>/dev/null || true
SCRIPT

chmod 755 "$PERFDATA_SCRIPT"
chown nagios:nagcmd "$PERFDATA_SCRIPT"
echo "   ✅ Script de procesamiento creado"

# ---- 4. Configurar Nagios para procesar perfdata ----
echo ">> [4/4] Configurando Nagios..."

# Habilitar procesamiento de performance data
if grep -q "^process_performance_data=0" "$NAGIOS_CFG"; then
    sed -i 's/^process_performance_data=0/process_performance_data=1/' "$NAGIOS_CFG"
elif ! grep -q "^process_performance_data=1" "$NAGIOS_CFG"; then
    echo "process_performance_data=1" >> "$NAGIOS_CFG"
fi

# Configurar comando de procesamiento para hosts
if ! grep -q "^host_perfdata_command=" "$NAGIOS_CFG"; then
    echo "host_perfdata_command=process-host-perfdata-rrd" >> "$NAGIOS_CFG"
fi

# Configurar comando de procesamiento para servicios
if ! grep -q "^service_perfdata_command=" "$NAGIOS_CFG"; then
    echo "service_perfdata_command=process-service-perfdata-rrd" >> "$NAGIOS_CFG"
fi

# Crear definiciones de comandos para perfdata processing
COMMANDS_FILE="/usr/local/nagios/etc/objects/commands_perfdata.cfg"
cat > "$COMMANDS_FILE" << 'EOF'
# Comandos para procesamiento de performance data en RRD

define command {
    command_name    process-host-perfdata-rrd
    command_line    /usr/local/nagios/libexec/process_perfdata.sh "$HOSTNAME$" "HOST" "$HOSTPERFDATA$" "$TIMET$"
}

define command {
    command_name    process-service-perfdata-rrd
    command_line    /usr/local/nagios/libexec/process_perfdata.sh "$HOSTNAME$" "$SERVICEDESC$" "$SERVICEPERFDATA$" "$TIMET$"
}
EOF

chown nagios:nagcmd "$COMMANDS_FILE"
chmod 664 "$COMMANDS_FILE"

# Agregar archivo de comandos al nagios.cfg si no está
if ! grep -q "$COMMANDS_FILE" "$NAGIOS_CFG"; then
    echo "cfg_file=$COMMANDS_FILE" >> "$NAGIOS_CFG"
fi

# Permisos para que www-data pueda leer RRD
usermod -a -G nagcmd www-data 2>/dev/null || true

# Agregar permiso de rrdtool al sudoers del webpanel
SUDOERS_FILE="/etc/sudoers.d/nagios-webpanel"
if [ -f "$SUDOERS_FILE" ] && ! grep -q "rrdtool" "$SUDOERS_FILE"; then
    echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/rrdtool" >> "$SUDOERS_FILE"
fi

echo "   ✅ Nagios configurado para procesar perfdata"

# Validar y reiniciar
echo ""
echo ">> Validando configuración..."
if /usr/local/nagios/bin/nagios -v "$NAGIOS_CFG" 2>&1 | tail -1 | grep -q "Things look okay"; then
    echo "   ✅ Configuración válida"
    systemctl restart nagios
    echo "   ✅ Nagios reiniciado"
else
    echo "   ⚠️  Hay errores en la configuración. Revisa con:"
    echo "   /usr/local/nagios/bin/nagios -v $NAGIOS_CFG"
fi

echo ""
echo "============================================"
echo "  ✅ RRDTool configurado correctamente"
echo "============================================"
echo ""
echo "  Los datos RRD se almacenan en: $RRD_DIR"
echo "  Un archivo .rrd por host se creará automáticamente"
echo "  cuando Nagios procese el primer check de cada host."
echo ""
echo "  Estructura de datos RRD:"
echo "  - step: 300s (5 min, igual al check_interval)"
echo "  - 576 puntos a 5 min = 48 horas detalladas"
echo "  - 672 puntos a 30 min = 14 días"
echo "  - 732 puntos a 2 horas = 2 meses"
echo "  - 1460 puntos a 1 día = 4 años"
echo ""
