#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Keycloak RADIUS Plugin installer (vzakharchenko/keycloak-radius-plugin)
# For Keycloak installed by Proxmox Helper Scripts (LXC)
#
# What it does:
# - Installs required packages (git, jq, maven, JDK, etc.)
# - Clones the plugin repo
# - Builds the plugin with Maven
# - Copies the needed JARs into /opt/keycloak/providers
# - Creates /opt/keycloak/config/radius.config (prompts for secrets/ports)
# - Runs kc.sh build and restarts keycloak
#
# Assumptions:
# - Keycloak is installed at /opt/keycloak
# - Keycloak systemd unit is named "keycloak"
# ============================================================

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Bitte als root ausführen."
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-debian}"
  else
    echo "debian"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

prompt_default() {
  local varname="$1"; shift
  local prompt="$1"; shift
  local def="$1"; shift
  local val=""
  read -r -p "${prompt} [${def}]: " val || true
  if [[ -z "${val}" ]]; then val="${def}"; fi
  printf -v "${varname}" "%s" "${val}"
}

prompt_yesno() {
  local varname="$1"; shift
  local prompt="$1"; shift
  local def="$1"; shift # "y" or "n"
  local val=""
  local suffix="y/N"
  [[ "${def}" == "y" ]] && suffix="Y/n"
  read -r -p "${prompt} (${suffix}): " val || true
  val="${val:-$def}"
  val="$(echo "${val}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${val}" == "y" || "${val}" == "yes" ]]; then
    printf -v "${varname}" "%s" "y"
  else
    printf -v "${varname}" "%s" "n"
  fi
}

prompt_secret() {
  local varname="$1"; shift
  local prompt="$1"; shift
  local val=""
  echo
  read -r -s -p "${prompt} (leer lassen = zufällig generieren): " val || true
  echo
  if [[ -z "${val}" ]]; then
    val="$(openssl rand -base64 48 | tr -d '\n')"
    log "Secret wurde zufällig generiert."
  fi
  printf -v "${varname}" "%s" "${val}"
}

check_keycloak_paths() {
  [[ -x /opt/keycloak/bin/kc.sh ]] || die "/opt/keycloak/bin/kc.sh nicht gefunden. Ist Keycloak wirklich unter /opt/keycloak installiert?"
  mkdir -p /opt/keycloak/providers
  mkdir -p /opt/keycloak/config
}

install_deps() {
  log "Installiere benötigte Pakete…"
  apt_install ca-certificates curl git jq openssl unzip tar

  # Maven: bevorzugt apt-maven (keine SHA-Thematik wie beim manuellen Download)
  if ! command -v mvn >/dev/null 2>&1; then
    apt_install maven
  fi

  # Java: Keycloak nutzt bei dir bereits Temurin 21, wir stellen sicher, dass JDK vorhanden ist.
  if ! command -v java >/dev/null 2>&1; then
    apt_install default-jdk
  fi
}

clone_or_update_repo() {
  local repo_url="$1"
  local dir="$2"

  if [[ -d "${dir}/.git" ]]; then
    log "Repo existiert bereits, aktualisiere…"
    git -C "${dir}" fetch --all --prune
    git -C "${dir}" reset --hard origin/master || git -C "${dir}" reset --hard origin/main || true
  else
    log "Klone Repo…"
    git clone --depth 1 "${repo_url}" "${dir}"
  fi
}

build_plugin() {
  local dir="$1"

  log "Baue Plugin via Maven…"
  # Projekttyp: Multi-module. Wir bauen das Ganze und nehmen danach gezielt die JARs.
  ( cd "${dir}" && mvn -q -DskipTests package )
}

copy_jars() {
  local repo_dir="$1"
  local providers_dir="/opt/keycloak/providers"

  local radius_jar
  local mikrotik_jar

  radius_jar="$(find "${repo_dir}" -type f -path '*/radius-plugin/target/*' -name 'radius-plugin-*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' ! -name '*-tests.jar' ! -name 'original-*.jar' | head -n 1 || true)"
  mikrotik_jar="$(find "${repo_dir}" -type f -path '*/mikrotik-radius-plugin/target/*' -name 'mikrotik-radius-plugin-*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' ! -name '*-tests.jar' ! -name 'original-*.jar' | head -n 1 || true)"

  [[ -n "${radius_jar}" ]] || die "radius-plugin JAR nicht gefunden. Build fehlgeschlagen?"
  [[ -n "${mikrotik_jar}" ]] || warn "mikrotik-radius-plugin JAR nicht gefunden (optional)."

  log "Kopiere Provider JARs nach /opt/keycloak/providers…"
  install -m 0644 "${radius_jar}" "${providers_dir}/"
  if [[ -n "${mikrotik_jar}" ]]; then
    install -m 0644 "${mikrotik_jar}" "${providers_dir}/"
  fi

  log "Aktuelle Provider:"
  ls -lh "${providers_dir}" | egrep -i 'radius|mikrotik' || true
}

write_radius_config() {
  local cfg="/opt/keycloak/config/radius.config"

  log "Erzeuge ${cfg}…"

  local sharedSecret authPort accountPort numberThreads useUdpRadius useRadSec coaEnabled coaPort otpWithoutPassword

  prompt_secret sharedSecret "RADIUS sharedSecret setzen"
  prompt_default authPort "Auth-Port (UDP)" "1812"
  prompt_default accountPort "Accounting-Port (UDP)" "1813"
  prompt_default numberThreads "Thread-Anzahl" "8"
  prompt_default useUdpRadius "UDP nutzen? (true/false)" "true"

  # RadSec/CoA: standardmässig aus
  prompt_yesno useRadSec "RadSec (TLS) aktivieren?" "n"
  prompt_yesno coaEnabled "CoA (Change of Authorization) aktivieren?" "n"
  prompt_default coaPort "CoA Port" "3799"

  # otpWithoutPassword: optional
  read -r -p "otpWithoutPassword (CSV-Liste von OTP-Mechanismen, leer lassen = []): " otpWithoutPassword || true
  otpWithoutPassword="${otpWithoutPassword:-}"

  local otp_json="[]"
  if [[ -n "${otpWithoutPassword}" ]]; then
    # CSV → JSON array
    otp_json="$(python3 - <<'PY'
import json,sys
s=sys.stdin.read().strip()
items=[x.strip() for x in s.split(",") if x.strip()]
print(json.dumps(items))
PY
<<< "${otpWithoutPassword}")"
  fi

  # RadSec: wenn aktiviert, fragen wir nach Pfaden oder generieren nicht automatisch (Keys sind betriebsspezifisch)
  local radsec_private="config/private.key"
  local radsec_cert="config/public.crt"
  local radsec_threads="${numberThreads}"

  if [[ "${useRadSec}" == "y" ]]; then
    prompt_default radsec_private "RadSec privateKey Pfad (relativ zu /opt/keycloak)" "config/private.key"
    prompt_default radsec_cert "RadSec certificate Pfad (relativ zu /opt/keycloak)" "config/public.crt"
    prompt_default radsec_threads "RadSec threads" "${numberThreads}"
  fi

  cat > "${cfg}" <<EOF
{
  "sharedSecret": "${sharedSecret}",
  "authPort": ${authPort},
  "accountPort": ${accountPort},
  "numberThreads": ${numberThreads},
  "useUdpRadius": ${useUdpRadius},
  "externalDictionary": null,
  "otpWithoutPassword": ${otp_json},
  "radsec": {
    "useRadSec": $( [[ "${useRadSec}" == "y" ]] && echo "true" || echo "false" ),
    "privateKey": "${radsec_private}",
    "certificate": "${radsec_cert}",
    "numberThreads": ${radsec_threads}
  },
  "coa": {
    "useCoA": $( [[ "${coaEnabled}" == "y" ]] && echo "true" || echo "false" ),
    "port": ${coaPort}
  }
}
EOF

  chmod 600 "${cfg}"
  log "radius.config geschrieben und gesichert (chmod 600)."

  # sanity check json
  jq . "${cfg}" >/dev/null
}

kc_build_and_restart() {
  log "kc.sh build…"
  /opt/keycloak/bin/kc.sh build

  log "Keycloak neu starten…"
  systemctl restart keycloak

  log "Status:"
  systemctl status keycloak --no-pager -l || true

  log "RADIUS Log-Indikatoren:"
  journalctl -u keycloak -n 200 --no-pager | egrep -i 'RadiusServer|KeycloakRadiusServer|radius|mikrotik|ERROR' || true
}

optional_service_optimised() {
  # Keycloak empfiehlt "start --optimized" nach erfolgreichem build.
  # Wir patchen das nur, wenn der Unitfile klar "kc.sh start" nutzt.
  prompt_yesno do_opt "systemd Unit auf 'kc.sh start --optimized' umstellen?" "y"
  [[ "${do_opt}" == "y" ]] || return 0

  local unit_file="/etc/systemd/system/keycloak.service"
  [[ -f "${unit_file}" ]] || { warn "${unit_file} nicht gefunden, überspringe."; return 0; }

  if ! grep -qE 'ExecStart=.*kc\.sh +start(\s|$)' "${unit_file}"; then
    warn "ExecStart in ${unit_file} passt nicht auf 'kc.sh start'. Überspringe automatische Anpassung."
    return 0
  fi

  log "Patche ${unit_file} (kc.sh start -> kc.sh start --optimized)…"
  cp -a "${unit_file}" "${unit_file}.bak.$(date +%Y%m%d_%H%M%S)"
  sed -i -E 's#(ExecStart=.*kc\.sh +start)(\s|$)#\1 --optimized\2#g' "${unit_file}"

  systemctl daemon-reload
  systemctl restart keycloak
  log "Unit angepasst und Dienst neu gestartet."
}

post_steps() {
  echo
  echo "=== Nächste Schritte ==="
  echo "1) Prüfen ob UDP 1812/1813 lauscht:"
  echo "   ss -lunp | egrep '(:1812|:1813)\\b' || true"
  echo
  echo "2) RADIUS-Client (UniFi/MikroTik/VPN) konfigurieren:"
  echo "   - Server: IP dieses Containers"
  echo "   - Ports: 1812/1813 (wie gesetzt)"
  echo "   - Shared Secret: (wie im Prompt gesetzt)"
  echo
  echo "3) Keycloak Admin UI:"
  echo "   - Dieses Plugin erscheint typischerweise NICHT als 'Flow Execution'."
  echo "   - Prüfe stattdessen Users → Credentials und Authentication → Required actions"
  echo
  echo "4) Optionaler Funktionstest (auf einem Client mit freeradius-utils):"
  echo "   radtest USER PASS <KEYCLOAK_IP> 0 <SHARED_SECRET>"
  echo
}

main() {
  require_root
  detect_os >/dev/null

  check_keycloak_paths
  install_deps

  local repo_dir="/opt/src/keycloak-radius-plugin"
  mkdir -p /opt/src

  clone_or_update_repo "https://github.com/vzakharchenko/keycloak-radius-plugin.git" "${repo_dir}"
  build_plugin "${repo_dir}"
  copy_jars "${repo_dir}"
  write_radius_config

  kc_build_and_restart
  optional_service_optimised

  post_steps
  log "Fertig."
}

main "$@"
