# dns-gitops

Un servidor DNS (BIND9) gestionado con GitOps: las zonas viven en este repositorio, GitHub las
valida en cada pull request y el servidor se actualiza solo desde `main`. Nadie edita el servidor
a mano, y cada cambio queda con autor, fecha y motivo.

Es el repositorio de acompañamiento del vídeo *Servidor DNS BIND9 en Ubuntu 26.04 con GitOps*.
Probado con BIND 9.20 en Ubuntu Server 26.04 LTS y en Debian 13.

```
 pull request ──► GitHub Actions: render-check.sh ──► merge a main (rama protegida)
                                                          │
                       el servidor trae main cada 60 s ◄──┘   (pull: no hay puertos abiertos)
 systemd timer ► dns-sync: fetch → ff-only → render-check → instalar → rndc reload → verificar
```

## Qué hay aquí

```
zones/lab.antoniocintora.com.zone        zona directa, con @SERIAL@ en vez del serial
zones/50.168.192.in-addr.arpa.zone       zona inversa
named/named.conf.zones                   las zonas que sirve BIND (solo bloques "zone")
named/named.conf.options                 configuración de BIND (sustituye a la de la distro)
bin/render-check.sh                      pone el serial y valida; lo usan el CI y el servidor
bin/dns-sync                             el despliegue; lo lanza el timer
systemd/dns-sync.service, dns-sync.timer
.github/workflows/check.yml              el CI: render-check.sh en cada pull request
```

Cambia `lab.antoniocintora.com` y la red `192.168.50.0/24` por las tuyas. El nombre de cada
fichero de `zones/` es el nombre de la zona, y cada una debe estar declarada en
`named/named.conf.zones` con `file "/etc/bind/zones/<zona>.zone";`.

## Cómo se garantiza que todo queda auditado

1. **`main` está protegida** (ver más abajo): solo entra lo que ha pasado la CI por un pull request.
2. **El servidor solo acepta Git.** `dns-sync` hace `git merge --ff-only origin/main`. Si alguien
   reescribe el historial, se niega y avisa.
3. **Lo editado a mano se revierte.** En cada ejecución compara lo instalado con lo renderizado
   desde Git. Si difieren sin que haya un commit nuevo, lo restaura y deja un aviso `DRIFT` con el
   diff y la hora de modificación.
4. **Un fallo nunca deja BIND roto.** Si la validación falla, no se toca nada. Si falla algo
   después de instalar (`named-checkconf -z`, `rndc`, o BIND no sirve el serial esperado), devuelve
   los ficheros anteriores.
5. **Queda registro:** `journalctl -u dns-sync` (con prioridad: `-p warning`) y
   `/var/lib/dns-gitops/audit.log`, con el hash del commit, el autor y el motivo.

El serial de cada zona es el timestamp de su último commit (`git log -1 --format=%ct -- zones/<zona>`):
nadie lo sube a mano, y el mismo commit da el mismo serial en cualquier servidor.

## Instalación en el servidor

```bash
sudo apt update && sudo apt install -y bind9 bind9-utils bind9-dnsutils git

sudo mkdir -p /var/lib/dns-gitops
sudo git clone https://github.com/LordAntonio99/dns-gitops /var/lib/dns-gitops/repo
cd /var/lib/dns-gitops/repo

sudo install -m 0755 bin/dns-sync bin/render-check.sh /usr/local/sbin/
sudo install -m 0644 systemd/dns-sync.service systemd/dns-sync.timer /etc/systemd/system/

# BIND carga la lista de zonas desde el repositorio
echo 'include "/etc/bind/named.conf.zones";' | sudo tee -a /etc/bind/named.conf.local
sudo touch /etc/bind/named.conf.zones

sudo systemctl daemon-reload
sudo systemctl start dns-sync.service          # primer despliegue, a mano
sudo journalctl -u dns-sync -n 10 --no-pager -o cat
sudo systemctl enable --now dns-sync.timer     # y a partir de aquí, cada 60 s
```

Si ya tenías una zona declarada a mano en `named.conf.local`, **bórrala** antes del primer
despliegue: la misma zona declarada dos veces no carga.

`dns-sync` y `render-check.sh` se instalan a mano y **no se actualizan desde Git**: lo que se
despliega son datos (zonas y configuración). Si un merge pudiera cambiar el script, también
podría ejecutar código como root en el servidor.

## Proteger `main` en GitHub

Settings → Branches (o Rules → Rulesets) → regla para `main`:

- Require a pull request before merging
- Require status checks to pass → **`zonas`** (el nombre del job de `check.yml`)
- Block force pushes
- Do not allow bypassing the above settings (también para administradores)

## Operar

| Quiero… | Hago… |
|---|---|
| Añadir o cambiar un registro | Una rama, editar `zones/<zona>.zone`, pull request, merge. En menos de 60 s lo sirve BIND |
| Saber quién cambió un registro y por qué | `git log -p -- zones/<zona>.zone` y `git blame zones/<zona>.zone` |
| Ver qué ha desplegado el servidor | `sudo journalctl -u dns-sync -o cat` y `sudo cat /var/lib/dns-gitops/audit.log` |
| Ver solo avisos y errores | `sudo journalctl -u dns-sync -p warning -o cat` |
| Volver atrás | El botón *Revert* del pull request (otro pull request) o `git revert` |
| Probar una zona antes de subirla | `bash bin/render-check.sh . /tmp/render` (necesita `bind9-utils`) |
| Ver si dns-sync está fallando | `systemctl --failed` |

## Repositorio privado

El servidor solo necesita **leer**. Crea una *deploy key* de solo lectura en GitHub, guarda la clave
privada en `/var/lib/dns-gitops/.ssh/deploy` (modo 0600) y en `/etc/default/dns-sync` pon:

```
GIT_SSH_COMMAND=ssh -i /var/lib/dns-gitops/.ssh/deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
```

Clona con la URL SSH. Nunca pongas en el servidor una clave con permiso de escritura.

## Límites conocidos

- **Un solo servidor.** No hay secundarios ni DNSSEC. Si añades secundarios, ten en cuenta que dos
  commits sobre la misma zona **en el mismo segundo** dan el mismo serial y un secundario no
  retransferiría; en la práctica, con pull requests no ocurre.
- **Solo zonas estáticas.** No hay actualizaciones dinámicas (DDNS): BIND no escribe en las zonas.
- **Los commits no se verifican por firma** en el servidor: los merges hechos desde la web de
  GitHub los firma GitHub, no su autor. La garantía es la protección de `main` más el
  `--ff-only`. Verificar firmas sería un endurecimiento adicional.
- **El historial no se puede reescribir.** Tras un `force-push` a `main`, el servidor se niega a
  seguir hasta que alguien lo revise. Es intencionado.
- **Si `main` contiene un commit inválido** (por ejemplo, por saltarse la CI), el servidor no lo
  despliega y repite el error cada minuto en el journal hasta que llegue un commit que lo arregle.
  En `audit.log` solo queda una vez.
- **No se versiona nada con secretos.** La configuración de AdGuard Home (`AdGuardHome.yaml`)
  incluye el hash de la contraseña y por eso no está en este repositorio.
