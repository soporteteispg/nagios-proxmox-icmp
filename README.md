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

Este script se encargará de crear el contenedor (por defecto CTID: `201`), instalar Nagios y el Panel Web.

1. Ingresá por SSH al nodo Proxmox como `root`.
2. Lanzá la creación del deployment:

```bash
wget https://raw.githubusercontent.com/soporteteispg/Nagios/main/scripts/deploy-proxmox.sh
bash deploy-proxmox.sh https://github.com/soporteteispg/Nagios.git
```

Si el repositorio es privado (requiere autenticación), podés enviar el token de acceso personal (PAT) directamente de esta forma:
```bash
bash deploy-proxmox.sh https://TOKEN@github.com/soporteteispg/Nagios.git
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

## 📝 Licencia
Este proyecto es de código abierto y se distribuye bajo la licencia [GPLv3](./LICENSE).
