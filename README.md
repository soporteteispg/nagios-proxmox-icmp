# Monitoreo ICMP con Nagios y Proxmox LXC

Proyecto de monitoreo ICMP con Nagios Core y panel web personalizado. Está optimizado para ser desplegado automáticamente en contenedores LXC de **Proxmox Virtual Environment** usando scripts de bash.

## 🚀 Características
- **Nagios Core 4.5.7** compilado y configurado
- Configuración separada por hosts internos y externos
- Checkeos rápidos (cada 3-5 minutos)
- **Panel Web Moderno** (Dashboard interactivo con modo oscuro) para agregar, borrar y visualizar el estado de los hosts
- Autodespliegue en Proxmox automatizado

## 🛠️ Requisitos
1. Un servidor con **Proxmox VE 8.0+**
2. Conexión a internet desde el nodo Proxmox para clonar el repositorio y descargar el template de Debian 12.
3. Acceso a la terminal como `root`.

## 📦 Despliegue Automatizado
Para desplegar este proyecto en un nuevo servidor Proxmox, tenés que descargar y ejecutar el script `deploy-proxmox.sh` en la terminal del nodo host de Proxmox.

Este script se encargará de crear el contenedor (por defecto buscará usar el próximo CTID libre a partir del `200`), instalar Nagios y el Panel Web.
Durante el proceso, el script detectará todos los storages disponibles en tu nodo y te permitirá elegir en cuál de ellos crear el contenedor de forma interactiva (usualmente sugiriendo `local-lvm` o `local-zfs`).

1. Ingresá por SSH al nodo Proxmox como `root`.
2. Lanzá la creación del deployment:

```bash
wget https://raw.githubusercontent.com/soporteteispg/nagios-proxmox-icmp/main/scripts/deploy-proxmox.sh
bash deploy-proxmox.sh https://github.com/soporteteispg/nagios-proxmox-icmp.git
```

Si el repositorio es privado (requiere autenticación), podés enviar el token de acceso personal (PAT) directamente de esta forma:
```bash
bash deploy-proxmox.sh https://TOKEN@github.com/soporteteispg/nagios-proxmox-icmp.git
```
*(Si no pasás el parámetro, el script te va a pedir la URL de forma interactiva).*

### ¿Qué hace el script?
- **Script 01**: Descarga Debian 12 si no existe, crea un LXC y le asigna configuración de red por DHCP.
- **Script 02**: Instala las dependencias y compila Nagios 4.5.7 y los nagios-plugins.
- **Script 03**: Utilitario interactivo para añadir hosts a la monitorización.
- **Script 04**: Instala el Panel Web (API PHP y frontend HTML) y configura Apache2. Configura los permisos para editar los hosts desde el panel.

> **Nota para contenedores Unprivileged (LXC)**: Es importante tener en cuenta que el contenedor LXC, por defecto, se ejecuta como unpowered container. Para que Nagios pueda ejecutar comandos ping y checkear ICMP correctamente, los scripts le asignan los permisos adecuados y configuran `net.ipv4.ping_group_range`.

## 📂 Archivos y Estructura
- `/scripts/` — Scripts de bash automatizados y wrapper de Proxmox.
- `/config/` — Archivos `.cfg` de Nagios base y templates.
- `/webpanel/` — Dashboard responsivo con HTML/JS y API en PHP.

## 🚑 Solución de Problemas (Troubleshooting)

### 1. Hosts externos aparecen como DOWN pero hay internet
En contenedores LXC, el comando `ping` requiere permisos especiales (SUID) para que el usuario `nagios` pueda enviar paquetes ICMP. Si los hosts externos (como 8.8.8.8) figuran inactivos:
```bash
# Otorgar permisos SUID al binario ping
chmod u+s /bin/ping
systemctl restart nagios
```
*(Nota: El script `02-install-nagios.sh` ya aplica este fix automáticamente).*

### 2. No se pueden eliminar o editar hosts desde el panel web
Para que el panel web (Apache/PHP) pueda modificar los archivos de configuración, el usuario `www-data` debe tener permisos de escritura mediante el grupo `nagcmd`. Si el panel falla o no guarda los cambios:
```bash
# Arreglar permisos del directorio de hosts
chown -R nagios:nagcmd /usr/local/nagios/etc/objects/hosts/
chmod 664 /usr/local/nagios/etc/objects/hosts/*.cfg
chmod 775 /usr/local/nagios/etc/objects/hosts
```

## 📝 Licencia
Este proyecto es de código abierto y se distribuye bajo la licencia [GPLv3](./LICENSE).
