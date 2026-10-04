#!/usr/bin/env bash
# render-check.sh — renderiza las zonas (pone el serial) y las valida con las herramientas de BIND.
#
# Lo usan el CI de GitHub y el servidor (dns-sync): los dos validan exactamente lo mismo.
#
# Uso: render-check.sh <repo> <salida>
#   <repo>    directorio del repositorio (zones/ y named/)
#   <salida>  directorio donde deja lo renderizado: zones/, named/ y serials
#
# El serial de cada zona es el timestamp de su último commit (git log -1 --format=%ct -- <zona>).
# Nadie lo sube a mano, y el mismo commit da siempre el mismo serial en cualquier servidor.
# Con SERIAL=<n> se fuerza uno para todas las zonas (solo para pruebas).
set -euo pipefail

repo=${1:?uso: render-check.sh <repo> <salida>}
out=${2:?uso: render-check.sh <repo> <salida>}
zones_dir=${ZONES_DIR:-/etc/bind/zones}

fail=0
err() { echo "ERROR: $*" >&2; fail=1; }
indent() { local l; while IFS= read -r l; do printf '    %s\n' "$l"; done; }

rm -rf "$out"
mkdir -p "$out/zones" "$out/named"

shopt -s nullglob
zonefiles=("$repo"/zones/*.zone)
(( ${#zonefiles[@]} )) || { echo "ERROR: no hay zonas en $repo/zones" >&2; exit 1; }

# 1) Cada zona: poner el serial y pasar named-checkzone
: > "$out/serials"
for f in "${zonefiles[@]}"; do
    base=${f##*/}
    zone=${base%.zone}

    if (( $(grep -c '@SERIAL@' "$f") != 1 )); then
        err "$base: debe contener @SERIAL@ exactamente una vez (el serial lo pone dns-sync)"
        continue
    fi

    serial=${SERIAL:-$(git -C "$repo" log -1 --format=%ct -- "zones/$base")}
    [[ -n $serial ]] || serial=$(git -C "$repo" log -1 --format=%ct)
    [[ $serial =~ ^[0-9]+$ ]] || { err "$base: serial no numérico ('$serial')"; continue; }

    sed "s/@SERIAL@/$serial/" "$f" > "$out/zones/$base"
    if res=$(named-checkzone "$zone" "$out/zones/$base" 2>&1); then
        printf '%s\t%s\n' "$zone" "$serial" >> "$out/serials"
    else
        err "$base: named-checkzone ha rechazado la zona"
        indent <<<"$res" >&2
    fi
done

# 2) La configuración de BIND
for name in named.conf.options named.conf.zones; do
    if [[ -f $repo/named/$name ]]; then
        cp "$repo/named/$name" "$out/named/$name"
    else
        err "falta named/$name"
    fi
done

if [[ -f $out/named/named.conf.zones ]]; then
    # named.conf.zones solo puede declarar zonas
    if bad=$(grep -nE '^[[:space:]]*(include|controls|key|options|logging|statistics-channels|trust-anchors|managed-keys)\b' \
                "$out/named/named.conf.zones"); then
        err "named.conf.zones solo puede contener bloques zone:"
        indent <<<"$bad" >&2
    fi

    # Cada zona declarada tiene su fichero (con la ruta esperada) y viceversa
    declared=$(grep -oE '^[[:space:]]*zone[[:space:]]+"[^"]+"' "$out/named/named.conf.zones" \
                | sed -E 's/.*"([^"]+)"/\1/' | sort)
    present=$(for f in "${zonefiles[@]}"; do b=${f##*/}; echo "${b%.zone}"; done | sort)
    if [[ $declared != "$present" ]]; then
        err "las zonas de named.conf.zones y los ficheros de zones/ no coinciden"
        diff <(echo "$declared") <(echo "$present") | indent >&2 || true
    fi
    while read -r z; do
        [[ -n $z ]] || continue
        grep -qF "file \"$zones_dir/$z.zone\";" "$out/named/named.conf.zones" \
            || err "la zona $z debe usar file \"$zones_dir/$z.zone\";"
    done <<<"$declared"
fi

# 3) Sintaxis completa de la configuración, con lo renderizado.
#    Se comprueba una copia con "directory" apuntando a la salida: en el runner del CI no existe
#    /var/cache/bind. Lo que se despliega es el fichero original, sin tocar; en el servidor,
#    dns-sync vuelve a comprobar lo ya instalado con named-checkconf -z.
if [[ -f $out/named/named.conf.options && -f $out/named/named.conf.zones ]]; then
    sed -E "s|^([[:space:]]*directory[[:space:]]+)\"[^\"]*\";|\\1\"$out\";|" \
        "$out/named/named.conf.options" > "$out/check-options.conf"
    cat > "$out/named.conf" <<EOF
include "$out/check-options.conf";
include "$out/named/named.conf.zones";
EOF
    if ! res=$(named-checkconf "$out/named.conf" 2>&1); then
        err "named-checkconf ha rechazado la configuración"
        indent <<<"$res" >&2
    fi
fi

(( fail == 0 )) || exit 1
echo "OK: ${#zonefiles[@]} zonas y configuración válidas"
