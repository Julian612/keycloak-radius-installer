#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*" >&2; }
err(){ echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || err "Bitte als root ausführen."
}

detect_keycloak_home() {
  if [[ -n "${KEYCLOAK_HOME:-}" && -d "$KEYCLOAK_HOME" ]]; then
    echo "$KEYCLOAK_HOME"; return
  fi
  if [[ -d /opt/keycloak ]]; then
    echo "/opt/keycloak"; return
  fi
  err "Keycloak Home nicht gefunden. Setze KEYCLOAK_HOME (z.B. /opt/keycloak)."
}

install_deps_debian() {
  if command -v apt-get >/dev/null 2>&1; then
    log "Installiere Abhängigkeiten (curl, jq, unzip, openssl, ss)…"
    apt-get update -y
    apt-get install -y curl jq unzip openssl iproute2 ca-certificates
  else
    warn "Kein apt-get gefunden. Stelle sicher, dass curl/jq/unzip/openssl/ss vorhanden sind."
  fi
}

prompt_secret() {
  local default_secret="$1"
  echo
  echo "Shared Secret für RADIUS:"
  echo " - Enter = zufällig generiert"
  echo " - oder eigenes Secret eingeben"
  read -r -s -p "Shared Secret: " s || true
  echo
  if [[ -z "${s:-}" ]]; then
    echo "$default_secret"
  else
    echo "$s"
  fi
}

github_latest_tag() {
  # GitHub API: latest release tag_name
  curl -fsSL "https://api.github.com/repos/vzakharchenko/keycloak-radius-plugin/releases/latest" \
    | jq -r '.tag_name'
}

download_release_zip() {
  local tag="$1"
  local out="$2"
  local url="https://github.com/vzakharchenko/keycloak-radius-plugin/releases/download/${tag}/keycloak-radius.zip"
  log "Lade Release-Zip: $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

write_radius_config() {
  local cfg="$1"
  local secret="$2"

  mkdir -p "$(dirname "$cfg")"

  # Minimal, bewährt aus deinem Setup: externalDictionary = null
  cat > "$cfg" <<EOF
{
  "sharedSecret": "${secret}",
  "authPort": 1812,
  "accountPort": 1813,
  "numberThreads": 8,
  "useUdpRadius": true,
  "externalDictionary": null,
  "otpWithoutPassword": [],
  "radsec": {
    "useRadSec": false,
    "privateKey": "config/private.key",
    "certificate": "config/public.crt",
    "numberThreads": 8
  },
  "coa": {
    "useCoA": false,
    "port": 3799
  }
}
EOF

  chmod 600 "$cfg"
}

cleanup_bad_jars() {
  local providers_dir="$1"
  # Verhindert «split package» durch unnötige Tests/Sources/Javadoc JARs in providers
  rm -f "$providers_dir"/*-tests.jar "$providers_dir"/*-sources.jar "$providers_dir"/*-javadoc.jar 2>/dev/null || true
}

install_from_zip() {
  local zip="$1"
  local providers_dir="$2"

  local tmp
  tmp="$(mktemp -d)"
  unzip -q -o "$zip" -d "$tmp"

  # Zip-Struktur variiert; wir suchen «radius-plugin*.jar» und kopieren NUR die Haupt-JAR
  local jar
  jar="$(find "$tmp" -type f -name 'radius-plugin-*.jar' \
        ! -name '*-tests.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' \
        | head -n 1 || true)"

  [[ -n "$jar" ]] || err "Konnte radius-plugin JAR im Zip nicht finden."

  mkdir -p "$providers_dir"
  log "Installiere Provider JAR: $(basename "$jar")"
  cp -f "$jar" "$providers_dir/"

  cleanup_bad_jars "$providers_dir"
  rm -rf "$tmp"
}

rebuild_and_restart() {
  local kc_home="$1"
  local kc_bin="$kc_home/bin/kc.sh"

  [[ -x "$kc_bin" ]] || err "kc.sh nicht gefunden/ausführbar: $kc_bin"

  log "Keycloak build (Provider registrieren)…"
  "$kc_bin" build

  if systemctl list-unit-files | grep -q '^keycloak\.service'; then
    log "Restart keycloak.service…"
    systemctl restart keycloak
    systemctl --no-pager -l status keycloak || true
  else
    warn "Kein systemd keycloak.service gefunden. Starte Keycloak manuell mit: $kc_bin start --optimized"
  fi
}

verify_ports() {
  log "Prüfe, ob UDP 1812/1813 lauscht…"
  ss -lunp | egrep ':1812|:1813' || warn "Noch keine Listener auf 1812/1813 sichtbar."
}

main() {
  require_root
  install_deps_debian

  local kc_home providers_dir cfg_dir cfg_file
  kc_home="$(detect_keycloak_home)"
  providers_dir="$kc_home/providers"
  cfg_dir="$kc_home/config"
  cfg_file="$cfg_dir/radius.config"

  log "Keycloak home: $kc_home"
  log "Providers dir: $providers_dir"
  log "Config file: $cfg_file"

  local default_secret
  default_secret="$(openssl rand -base64 48 | tr -d '\n')"
  local secret
  secret="$(prompt_secret "$default_secret")"

  # Tag bestimmen
  local tag="${KC_RADIUS_TAG:-}"
  if [[ -z "$tag" ]]; then
    log "Ermittle latest release tag…"
    tag="$(github_latest_tag)"
  fi
  [[ -n "$tag" && "$tag" != "null" ]] || err "Konnte Release-Tag nicht ermitteln. Setze KC_RADIUS_TAG manuell."

  local zip="/tmp/keycloak-radius-${tag}.zip"
  download_release_zip "$tag" "$zip"

  install_from_zip "$zip" "$providers_dir"
  write_radius_config "$cfg_file" "$secret"

  rebuild_and_restart "$kc_home"
  verify_ports

  echo
  log "Fertig."
  log "Wichtig: Das Shared Secret brauchst du in UniFi (RADIUS Profile) 1:1 identisch."
  log "Config: $cfg_file"
}

main "$@"
