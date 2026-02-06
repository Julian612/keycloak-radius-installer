#!/usr/bin/env bash
set -euo pipefail

# ============================
# Keycloak RADIUS Plugin Installer (vzakharchenko)
# Für Keycloak via Proxmox Helper Script (LXC)
# ============================

KEYCLOAK_DIR="/opt/keycloak"
SRC_BASE="/opt/src"
REPO_DIR="${SRC_BASE}/keycloak-radius-plugin"
REPO_URL="https://github.com/vzakharchenko/keycloak-radius-plugin.git"
KC_CONFIG_DIR="${KEYCLOAK_DIR}/config"
RADIUS_CFG="${KC_CONFIG_DIR}/radius.config"
PROVIDERS_DIR="${KEYCLOAK_DIR}/providers"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then stripping='Dieses Script muss als root laufen (sudo).'; err "$stripping"; exit 1; fi
}

require_keycloak() {
  if [[ ! -x "${KEYCLOAK_DIR}/bin/kc.sh" ]]; then
    err "Keycloak nicht gefunden unter ${KEYCLOAK_DIR}. Erwartet: ${KEYCLOAK_DIR}/bin/kc.sh"
    exit 1
  fi
  mkdir -p "${KC_CONFIG_DIR}" "${PROVIDERS_DIR}" "${SRC_BASE}"
}

prompt_secret() {
  local secret=""
  echo "RADIUS sharedSecret setzen."
  echo "1) automatisch generieren (empfohlen)"
  echo "2) manuell eingeben"
  read -r -p "Auswahl [1/2] (Default: 1): " choice
  choice="${choice:-1}"

  if [[ "${choice}" == "2" ]]; then
    read -r -s -p "sharedSecret (Eingabe wird nicht angezeigt): " secret
    echo
    if [[ -z "${secret}" ]]; then
      err "Leeres sharedSecret ist nicht erlaubt."
      exit 1
    fi
  else
    secret="$(openssl rand -base64 48 | tr -d '\n')"
    log "sharedSecret wurde generiert."
  fi

  echo "${secret}"
}

install_deps() {
  log "Installiere Abhängigkeiten (git, jq, maven, build tools)…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git jq openssl \
    maven \
    build-essential
}

clone_repo() {
  log "Hole Repo: ${REPO_URL}"
  if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" fetch --all --tags
    git -C "${REPO_DIR}" pull --ff-only || true
  else
    rm -rf "${REPO_DIR}"
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
  fi
}

# Wichtig: POM nicht voraussetzen, sondern finden
find_pom() {
  local pom=""

  # Bevorzugt: keycloak-plugins/pom.xml (typische Struktur)
  if [[ -f "${REPO_DIR}/keycloak-plugins/pom.xml" ]]; then
    pom="${REPO_DIR}/keycloak-plugins/pom.xml"
    echo "${pom}"
    return 0
  fi

  # Alternative: Root-POM
  if [[ -f "${REPO_DIR}/pom.xml" ]]; then
    pom="${REPO_DIR}/pom.xml"
    echo "${pom}"
    return 0
  fi

  # Fallback: erster POM in max depth 4
  pom="$(find "${REPO_DIR}" -maxdepth 4 -type f -name "pom.xml" | head -n 1 || true)"
  if [[ -n "${pom}" ]]; then
    warn "Ungewöhnliche Repo-Struktur. Verwende gefundenen POM: ${pom}"
    echo "${pom}"
    return 0
  fi

  err "Kein pom.xml im Repo gefunden. Build nicht möglich."
  err "Prüfe Repo-Inhalt unter: ${REPO_DIR}"
  exit 1
}

build_plugin() {
  local pom_file
  pom_file="$(find_pom)"
  log "Baue Plugin via Maven (POM: ${pom_file})…"

  # Maven immer mit -f aufrufen, damit Working Directory egal ist
  mvn -f "${pom_file}" -DskipTests package
}

copy_jars() {
  log "Kopiere Provider-JARs nach ${PROVIDERS_DIR}…"

  # Nur die „richtigen“ JARs (keine sources/javadoc/original/tests)
  mapfile -t jars < <(
    find "${REPO_DIR}" -type f -path "*/target/*.jar" \
      ! -name "*-sources.jar" \
      ! -name "*-javadoc.jar" \
      ! -name "*-tests.jar" \
      ! -name "original-*.jar"
  )

  if [[ "${#jars[@]}" -eq 0 ]]; then
    err "Keine Build-JARs gefunden (target/*.jar). Maven-Build fehlgeschlagen oder anderer Build-Output."
    exit 1
  fi

  # Optional: alte radius/mikrotik jars entfernen (um Dubletten zu vermeiden)
  rm -f "${PROVIDERS_DIR}"/radius-plugin-*.jar "${PROVIDERS_DIR}"/mikrotik-radius-plugin-*.jar || true

  for f in "${jars[@]}"; do
    # nur die beiden relevanten Module, falls mehrere gebaut werden
    case "$(basename "$f")" in
      radius-plugin-*.jar|mikrotik-radius-plugin-*.jar)
        cp -f "$f" "${PROVIDERS_DIR}/"
        ;;
    esac
  done

  log "Provider-Verzeichnis:"
  ls -lh "${PROVIDERS_DIR}" | egrep -i 'radius|mikrotik' || true
}

write_radius_config() {
  log "Erzeuge ${RADIUS_CFG}…"
  local secret
  secret="$(prompt_secret)"

  # Default: externalDictionary null, damit Keycloak nicht /opt/dictionary verlangt
  cat > "${RADIUS_CFG}" <<EOF
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

  chmod 600 "${RADIUS_CFG}"
  log "radius.config geschrieben (Rechte 600)."
}

kc_build_restart() {
  log "Keycloak build (Provider registrieren)…"
  "${KEYCLOAK_DIR}/bin/kc.sh" build

  log "Keycloak via systemd neu starten…"
  systemctl restart keycloak

  log "Status:"
  systemctl status keycloak --no-pager -l || true

  log "RADIUS Ports prüfen (1812/1813 UDP):"
  ss -lunp | egrep ':1812|:1813' || true

  log "Letzte Logs (Radius/Mikrotik):"
  journalctl -u keycloak -n 120 --no-pager | egrep -i 'radius|mikrotik|provider|spi|error|warn' || true
}

main() {
  require_root
  require_keycloak
  install_deps
  clone_repo
  build_plugin
  copy_jars
  write_radius_config
  kc_build_restart
  log "Fertig."
}

main "$@"
