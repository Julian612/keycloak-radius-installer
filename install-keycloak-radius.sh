#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Keycloak RADIUS Plugin Installer (UniFi)
# - Release-JAR Installation (no Maven)
# - Creates /opt/keycloak/config/radius.config
# - Builds Keycloak, restarts systemd service
# ==========================================

KEYCLOAK_HOME="/opt/keycloak"
PROVIDERS_DIR="${KEYCLOAK_HOME}/providers"
CONFIG_DIR="${KEYCLOAK_HOME}/config"
RADIUS_CFG="${CONFIG_DIR}/radius.config"
SERVICE_NAME="keycloak"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates jq openssl
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "${prompt} [${default}]: " var || true
  if [[ -z "${var}" ]]; then
    echo "${default}"
  else
    echo "${var}"
  fi
}

prompt_secret() {
  local prompt="$1"
  local var
  read -r -s -p "${prompt}: " var
  echo
  echo "${var}"
}

ensure_paths() {
  [[ -d "${KEYCLOAK_HOME}" ]] || { echo "ERROR: ${KEYCLOAK_HOME} not found"; exit 1; }
  mkdir -p "${PROVIDERS_DIR}" "${CONFIG_DIR}"
}

download_plugin() {
  local version_tag="$1"          # e.g. v1.6.1-26.4.0
  local jar_name="$2"             # e.g. keycloak-radius-plugin.jar (depends on release assets)
  local url="https://github.com/vzakharchenko/keycloak-radius-plugin/releases/download/${version_tag}/${jar_name}"

  echo "[INFO] Downloading plugin: ${url}"
  curl -fL "${url}" -o "${PROVIDERS_DIR}/${jar_name}"

  # Keep only runtime jar(s) that match jar_name; optionally cleanup older radius artifacts
  echo "[INFO] Providers directory after download:"
  ls -lh "${PROVIDERS_DIR}" | sed -n '1,200p'
}

write_radius_config() {
  local shared_secret="$1"
  local auth_port="$2"
  local acct_port="$3"
  local threads="$4"
  local external_dict="$5"  # "null" or a path

  # externalDictionary can be null or a path (repo example uses /opt/dictionary)  [oai_citation:5‡GitHub](https://github.com/vzakharchenko/keycloak-radius-plugin)
  if [[ "${external_dict}" == "null" ]]; then
    jq -n \
      --arg s "${shared_secret}" \
      --argjson ap "${auth_port}" \
      --argjson acp "${acct_port}" \
      --argjson nt "${threads}" \
      '{
        sharedSecret: $s,
        authPort: $ap,
        accountPort: $acp,
        numberThreads: $nt,
        useUdpRadius: true,
        externalDictionary: null,
        otpWithoutPassword: [],
        radsec: {useRadSec:false, privateKey:"config/private.key", certificate:"config/public.crt", numberThreads:$nt},
        coa: {useCoA:false, port:3799}
      }' > "${RADIUS_CFG}"
  else
    jq -n \
      --arg s "${shared_secret}" \
      --argjson ap "${auth_port}" \
      --argjson acp "${acct_port}" \
      --argjson nt "${threads}" \
      --arg d "${external_dict}" \
      '{
        sharedSecret: $s,
        authPort: $ap,
        accountPort: $acp,
        numberThreads: $nt,
        useUdpRadius: true,
        externalDictionary: $d,
        otpWithoutPassword: [],
        radsec: {useRadSec:false, privateKey:"config/private.key", certificate:"config/public.crt", numberThreads:$nt},
        coa: {useCoA:false, port:3799}
      }' > "${RADIUS_CFG}"
  fi

  chmod 600 "${RADIUS_CFG}"
  echo "[INFO] Wrote ${RADIUS_CFG}:"
  cat "${RADIUS_CFG}" | jq .
}

cleanup_non_runtime_jars() {
  # Avoid copying/building tests/sources/javadoc into providers: reduces split-package warnings
  # If you already have such jars, remove them:
  rm -f "${PROVIDERS_DIR}"/*-tests.jar "${PROVIDERS_DIR}"/*-sources.jar "${PROVIDERS_DIR}"/*-javadoc.jar 2>/dev/null || true
}

build_and_restart() {
  echo "[INFO] Running kc.sh build…"
  "${KEYCLOAK_HOME}/bin/kc.sh" build

  echo "[INFO] Restarting ${SERVICE_NAME}…"
  systemctl restart "${SERVICE_NAME}"

  echo "[INFO] systemctl status (short):"
  systemctl --no-pager -l status "${SERVICE_NAME}" | sed -n '1,80p'
}

verify_listeners() {
  local auth_port="$1"
  local acct_port="$2"
  echo "[INFO] UDP listeners (auth/account):"
  ss -lunp | egrep ":${auth_port}\b|:${acct_port}\b" || true

  echo "[INFO] Keycloak logs (radius-related):"
  journalctl -u "${SERVICE_NAME}" -n 120 --no-pager | egrep -i 'radius|RadiusServer|KeycloakRadiusServer|error|warn' || true
}

print_next_steps() {
  local auth_port="$1"
  cat <<EOF

[OK] Installation abgeschlossen.

Wichtig:
1) Shared Secret:
   - Muss identisch sein in:
     - ${RADIUS_CFG}  (sharedSecret)
     - UniFi RADIUS Profile (Shared Secret)
     - Tests (radtest, eapol_test etc.)

2) UniFi:
   - RADIUS Server: <IP deiner Keycloak-VM/LXC>
   - Auth Port: ${auth_port}
   - Accounting: wie konfiguriert in ${RADIUS_CFG}

3) Wenn du FreeRADIUS radtest nutzt:
   - "invalid Response Authenticator / Shared secret is incorrect" = Secret mismatch.

EOF
}

main() {
  need_root
  ensure_paths

  if ! have_cmd jq || ! have_cmd openssl; then
    echo "[INFO] Installing dependencies…"
    install_deps
  fi

  echo "[INFO] Keycloak home: ${KEYCLOAK_HOME}"

  # Pick a release that matches your Keycloak (example from repo: v1.6.1-26.4.0)  [oai_citation:6‡GitHub](https://github.com/vzakharchenko/keycloak-radius-plugin)
  RELEASE_TAG="$(prompt_default "Keycloak-radius-plugin release tag" "v1.6.1-26.4.0")"
  JAR_NAME="$(prompt_default "Release asset jar filename" "keycloak-radius-plugin.jar")"

  # Shared Secret
  gen_secret="$(openssl rand -base64 48 | tr -d '\n')"
  echo "[INFO] Generated shared secret (can be overridden)."
  shared_secret="$(prompt_default "RADIUS shared secret" "${gen_secret}")"

  auth_port="$(prompt_default "RADIUS auth port" "1812")"
  acct_port="$(prompt_default "RADIUS accounting port" "1813")"
  threads="$(prompt_default "RADIUS numberThreads" "8")"

  # externalDictionary: set to null unless you really need custom vendor dicts
  ext_dict_choice="$(prompt_default "externalDictionary path (enter 'null' for none)" "null")"

  echo "[INFO] Downloading plugin…"
  download_plugin "${RELEASE_TAG}" "${JAR_NAME}"

  echo "[INFO] Cleaning up non-runtime jars (tests/sources/javadoc)…"
  cleanup_non_runtime_jars

  echo "[INFO] Writing radius config…"
  write_radius_config "${shared_secret}" "${auth_port}" "${acct_port}" "${threads}" "${ext_dict_choice}"

  build_and_restart
  verify_listeners "${auth_port}" "${acct_port}"
  print_next_steps "${auth_port}"
}

main "$@"
