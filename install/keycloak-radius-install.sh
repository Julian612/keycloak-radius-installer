#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Julian612
# License: MIT
# Source: https://github.com/vzakharchenko/keycloak-radius-plugin

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

REPO="vzakharchenko/keycloak-radius-plugin"
GH_API="https://api.github.com/repos/${REPO}"
KEYCLOAK_HOME="${KEYCLOAK_HOME:-/opt/keycloak}"

msg_info "Installiere Abhängigkeiten"
$STD apt-get install -y curl jq openssl iproute2 ca-certificates
msg_ok "Abhängigkeiten installiert"

# Detect Keycloak
if [[ ! -x "${KEYCLOAK_HOME}/bin/kc.sh" ]]; then
  msg_error "Keycloak nicht gefunden unter ${KEYCLOAK_HOME}. Setze KEYCLOAK_HOME oder stelle sicher, dass Keycloak installiert ist."
  exit 1
fi
msg_ok "Keycloak gefunden: ${KEYCLOAK_HOME}"

PROVIDERS_DIR="${KEYCLOAK_HOME}/providers"
mkdir -p "${PROVIDERS_DIR}"

# Resolve latest release tag
msg_info "Ermittle Release-Tag via GitHub API"
TAG="${KC_RADIUS_TAG:-}"
if [[ -z "${TAG}" ]]; then
  TAG="$(curl -fsSL "${GH_API}/releases/latest" | jq -r '.tag_name')"
fi
[[ -n "${TAG}" && "${TAG}" != "null" ]] || { msg_error "Konnte Release-Tag nicht ermitteln."; exit 1; }
msg_ok "Release-Tag: ${TAG}"

RELEASE_JSON="$(curl -fsSL "${GH_API}/releases/tags/${TAG}")"

pick_asset_url() {
  echo "$RELEASE_JSON" | jq -r --arg re "$1" \
    '.assets[] | select(.browser_download_url | test($re)) | .browser_download_url' \
    | head -n 1
}

# Download JAR (or extract from ZIP as fallback)
msg_info "Lade RADIUS Plugin JAR"
RADIUS_JAR_URL="$(pick_asset_url 'radius-plugin-.*\.jar$')"
[[ -n "${RADIUS_JAR_URL}" ]] || RADIUS_JAR_URL="$(pick_asset_url 'keycloak-radius-plugin.*\.jar$')"

if [[ -n "${RADIUS_JAR_URL}" ]]; then
  $STD curl -fL --retry 3 --retry-delay 1 -o "${PROVIDERS_DIR}/$(basename "${RADIUS_JAR_URL}")" "${RADIUS_JAR_URL}"
else
  ZIP_URL="$(pick_asset_url 'keycloak-radius.*\.zip$')"
  [[ -n "${ZIP_URL}" ]] || ZIP_URL="$(pick_asset_url '.*\.zip$')"
  [[ -n "${ZIP_URL}" ]] || { msg_error "Kein passendes Asset (jar/zip) in Release ${TAG} gefunden."; exit 1; }
  TMPDIR="$(mktemp -d)"
  $STD curl -fL --retry 3 --retry-delay 1 -o "${TMPDIR}/release.zip" "${ZIP_URL}"
  $STD unzip -q "${TMPDIR}/release.zip" -d "${TMPDIR}"
  FOUND_JAR="$(find "${TMPDIR}" -type f -name 'radius-plugin-*.jar' | head -n 1 || true)"
  [[ -n "${FOUND_JAR}" ]] || { rm -rf "${TMPDIR}"; msg_error "Im ZIP kein radius-plugin-*.jar gefunden."; exit 1; }
  cp -f "${FOUND_JAR}" "${PROVIDERS_DIR}/"
  rm -rf "${TMPDIR}"
fi

# Remove unneeded JARs
rm -f \
  "${PROVIDERS_DIR}"/*-tests.jar \
  "${PROVIDERS_DIR}"/*-test.jar \
  "${PROVIDERS_DIR}"/*-sources.jar \
  "${PROVIDERS_DIR}"/*-javadoc.jar 2>/dev/null || true
msg_ok "RADIUS Plugin JAR installiert"

# Write radius.config
CONFIG_PATH="${KC_RADIUS_CONFIG_PATH:-${KEYCLOAK_HOME}/config/radius.config}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

SHARED_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
AUTH_PORT="${KC_RADIUS_AUTH_PORT:-1812}"
ACCT_PORT="${KC_RADIUS_ACCT_PORT:-1813}"

msg_info "Schreibe radius.config"
if [[ -f "${CONFIG_PATH}" ]]; then
  TMP_CFG="$(mktemp)"
  jq --arg s "${SHARED_SECRET}" \
     --argjson ap "${AUTH_PORT}" \
     --argjson acp "${ACCT_PORT}" \
     '.sharedSecret=$s | .authPort=$ap | .accountPort=$acp | .externalDictionary=null' \
     "${CONFIG_PATH}" > "${TMP_CFG}"
  mv "${TMP_CFG}" "${CONFIG_PATH}"
else
  cat >"${CONFIG_PATH}" <<EOF
{
  "sharedSecret": "${SHARED_SECRET}",
  "authPort": ${AUTH_PORT},
  "accountPort": ${ACCT_PORT},
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
fi
chmod 600 "${CONFIG_PATH}"
msg_ok "radius.config geschrieben (${CONFIG_PATH})"

# Rebuild Keycloak
msg_info "kc.sh build"
$STD "${KEYCLOAK_HOME}/bin/kc.sh" build
msg_ok "Keycloak neu gebaut"

# Restart Keycloak service
msg_info "Starte Keycloak neu"
if systemctl list-unit-files 2>/dev/null | grep -q '^keycloak\.service'; then
  $STD systemctl restart keycloak
  msg_ok "Keycloak Service neugestartet"
else
  msg_info "keycloak.service nicht gefunden – bitte Keycloak manuell neu starten"
fi

motd_ssh
customize

echo ""
echo "Keycloak RADIUS Plugin installiert (Version: ${TAG})"
echo "Shared Secret:     ${SHARED_SECRET}"
echo "Auth Port (UDP):   ${AUTH_PORT}"
echo "Accounting Port:   ${ACCT_PORT}"
echo "Config:            ${CONFIG_PATH}"
echo ""
echo "Hinweis: Shared Secret muss in UniFi / FreeRADIUS identisch gesetzt werden."
