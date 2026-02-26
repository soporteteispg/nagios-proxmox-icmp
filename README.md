# 🖥️ Nagios Core — Monitoreo ICMP en Proxmox

Monitoreo de **pérdida de paquetes y latencia (ICMP/ping)** para IPs internas y externas, corriendo en un contenedor LXC de Proxmox.

---

## 📋 Requisitos

- **Proxmox VE** 7.x o 8.x
- **Template**: Debian 12 (descargar desde Proxmox si no lo tienes)
- Acceso SSH al host Proxmox como root

---

## 🚀 Instalación Paso a Paso

### Paso 1: Personalizar la configuración

Antes de ejecutar cualquier script, editar los valores en los archivos:

| Archivo | Qué cambiar |
|---------|-------------|
| `scripts/01-create-lxc.sh` | IP del contenedor, gateway, CTID, contraseña |
| `scripts/02-install-nagios.sh` | Contraseña web (`NAGIOS_ADMIN_PASS`), email |
| `config/contacts.cfg` | Email del administrador |
| `config/hosts/internal-hosts.cfg` | IPs de tus dispositivos internos |
| `config/hosts/external-hosts.cfg` | IPs/dominios externos a monitorear |

### Paso 2: Crear el contenedor LXC

Copiar `scripts/01-create-lxc.sh` al **host Proxmox** y ejecutar:

```bash
bash 01-create-lxc.sh
```

### Paso 3: Copiar archivos al contenedor

Desde el host Proxmox (asumiendo CTID=200):

```bash
# Copiar scripts
pct push 200 scripts/02-install-nagios.sh /root/02-install-nagios.sh
pct push 200 scripts/03-add-host.sh /root/03-add-host.sh
pct push 200 scripts/04-install-webpanel.sh /root/04-install-webpanel.sh

# Copiar configuraciones
pct exec 200 -- mkdir -p /root/config/hosts
pct push 200 config/templates.cfg /root/config/templates.cfg
pct push 200 config/commands.cfg /root/config/commands.cfg
pct push 200 config/contacts.cfg /root/config/contacts.cfg
pct push 200 config/hosts/internal-hosts.cfg /root/config/hosts/internal-hosts.cfg
pct push 200 config/hosts/external-hosts.cfg /root/config/hosts/external-hosts.cfg

# Copiar panel web
pct exec 200 -- mkdir -p /root/webpanel
pct push 200 webpanel/index.html /root/webpanel/index.html
pct push 200 webpanel/style.css /root/webpanel/style.css
pct push 200 webpanel/app.js /root/webpanel/app.js
pct push 200 webpanel/api.php /root/webpanel/api.php
```

### Paso 4: Instalar Nagios

Entrar al contenedor e instalar:

```bash
pct enter 200
bash /root/02-install-nagios.sh
```

La instalación tarda aproximadamente **5-10 minutos**. Al finalizar te mostrará la URL de acceso.

### Paso 5: Instalar el Panel Web de Administración

Dentro del contenedor:

```bash
bash /root/04-install-webpanel.sh
```

### Paso 6: Acceder a las interfaces web

| Interfaz | URL | Descripción |
|----------|-----|-------------|
| **Panel de Monitoreo** | `http://<IP>/monitor` | Dashboard fácil para agregar hosts y ver estado |
| **Nagios Original** | `http://<IP>/nagios` (usuario: `nagiosadmin`) | Interfaz completa de Nagios |

---

## ➕ Agregar Nuevos Hosts

### Opción 1: Panel Web (recomendado) ⭐

1. Abrir `http://<IP_CONTENEDOR>/monitor` en el navegador
2. Click en **"+ Agregar Host"**
3. Completar: nombre, IP, tipo (interno/externo) y nivel de monitoreo
4. Click en **"Agregar Host"** — se recarga automáticamente

El panel permite también **editar** y **eliminar** hosts desde la tabla.

### Opción 2: Script interactivo (por SSH)

Dentro del contenedor:

```bash
bash /root/03-add-host.sh
```

Te pedirá nombre, IP, tipo (interno/externo) y nivel de monitoreo.

### Opción 3: Manualmente (editar archivos .cfg)

Crear un archivo en `/usr/local/nagios/etc/objects/hosts/`:

```cfg
define host {
    use                     icmp-host-internal    ; o icmp-host-external
    host_name               mi-servidor
    alias                   Mi Servidor
    address                 192.168.1.100
    parents                 gateway               ; opcional, host padre
}

define service {
    use                     icmp-ping-service
    host_name               mi-servidor
    service_description     PING - Latencia y Pérdida de Paquetes
    check_command           check_ping_detailed
}
```

Luego validar y reiniciar:

```bash
/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
systemctl reload nagios
```

---

## 📊 Niveles de Monitoreo (Comandos de Ping)

| Comando | Paquetes | Warning | Critical | Uso recomendado |
|---------|----------|---------|----------|-----------------|
| `check_ping_quick` | 5 | 100ms / 20% | 500ms / 60% | Checks rápidos |
| `check_host_ping` | Configurable | Configurable | Configurable | Personalizado |
| `check_ping_detailed` | 20 | 80ms / 10% | 300ms / 40% | Mayor precisión |
| `check_ping_strict` | 10 | 50ms / 5% | 200ms / 20% | Servicios críticos |

---

## 🔧 Comandos Útiles

```bash
# Ver estado de Nagios
systemctl status nagios

# Reiniciar Nagios
systemctl restart nagios

# Recargar configuración (sin downtime)
systemctl reload nagios

# Validar configuración antes de aplicar
/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg

# Ver logs
tail -f /usr/local/nagios/var/nagios.log
```

---

## 🔥 Troubleshooting

| Problema | Solución |
|----------|----------|
| No se puede acceder a `/nagios` | Verificar que Apache está corriendo: `systemctl status apache2` |
| Hosts en estado PENDING | Esperar 5 minutos o forzar check desde la web |
| Error "Could not open command file" | `chmod 775 /usr/local/nagios/var/rw/` y `chown nagios:nagcmd /usr/local/nagios/var/rw/nagios.cmd` |
| Ping falla a hosts locales | Verificar que el contenedor tiene conectividad: `ping <IP>` desde dentro del LXC |
| No llegan notificaciones | Verificar que `postfix` o `msmtp` está instalado y configurado para enviar emails |

---

## 📁 Estructura de Archivos en el Contenedor

```
/usr/local/nagios/
├── bin/nagios                      # Binario principal
├── etc/
│   ├── nagios.cfg                  # Config principal
│   ├── htpasswd.users              # Usuarios web
│   └── objects/
│       ├── templates_custom.cfg    # Templates ICMP
│       ├── commands_custom.cfg     # Comandos de ping
│       ├── contacts.cfg            # Contactos
│       └── hosts/                  # Un .cfg por host
│           ├── internal-hosts.cfg
│           └── external-hosts.cfg
├── libexec/                        # Plugins (check_ping, etc)
└── var/
    ├── nagios.log                  # Log principal
    └── rw/nagios.cmd               # Pipe de comandos externos
```
