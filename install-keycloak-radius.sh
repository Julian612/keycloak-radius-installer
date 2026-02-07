#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Keycloak RADIUS Plugin Installer (UniFi-friendly)
# - Resolves release assets via GitHub API (no hardcoded filenames)
# - Installs ONLY radius-plugin jar by default (no Mikrotik)
# - Creates/updates /opt/keycloak/config/radius.config
# - Removes *-tests/*-sources/*-javadoc jars to avoid split-package warnings
# - Runs kc.sh build + systemctl restart keycloak
# ------------------------------------------------------------

REPO="vzakharchenko/keycloak-radius-plugin"
GH_API="https://api.github.com/repos/${REPO}"
KEYCLOAK_HOME_DEFAULT="/opt/keycloak"
RADIUS_CONFIG_DEFAULT_REL="config/radius.config"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Bitte als root ausführen."
  fi
}

install_deps() {
  log "Installiere Abhängigkeiten (curl, jq, openssl, iproute2, ca-certificates)…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl jq openssl iproute2 ca-certificates
}

detect_keycloak_home() {
  local kc_home="${KEYCLOAK_HOME:-}"
  if [[ -z "$kc_home" ]]; then
    if [[ -d "$KEYCLOAK_HOME_DEFAULT" && -x "$KEYCLOAK_HOME_DEFAULT/bin/kc.sh" ]]; then
      kc_home="$KEYCLOAK_HOME_DEFAULT"
    else
      die "Keycloak nicht gefunden. Setze KEYCLOAK_HOME oder installiere Keycloak nach /opt/keycloak."
    fi
  fi
  [[ -x "$kc_home/bin/kc.sh" ]] || die "kc.sh nicht gefunden unter: $kc_home/bin/kc.sh"
  echo "$kc_home"
}

prompt() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local secret="${4:-false}"

  local value=""
  if [[ "$secret" == "true" ]]; then
    if [[ -n "$default" ]]; then
      read -r -s -p "$question [$default]: " value; echo
    else
      read -r -s -p "$question: " value; echo
    fi
  else
    if [[ -n "$default" ]]; then
      read -r -p "$question [$default]: " value
    else
      read -r -p "$question: " value
    fi
  fi

  if [[ -z "$value" ]]; then value="$default"; fi
  printf -v "$var_name" "%s" "$value"
}

gh_latest_tag() {
  curl -fsSL "${GH_API}/releases/latest" | jq -r '.tag_name'
}

gh_release_by_tag() {
  local tag="$1"
  curl -fsSL "${GH_API}/releases/tags/${tag}"
}

pick_asset_url() {
  # Pick a browser_download_url for an asset that matches a regex
  local json="$1"
  local regex="$2"
  echo "$json" | jq -r --arg re "$regex" '
    .assets[]
    | select(.browser_download_url | test($re))
    | .browser_download_url
  ' | head -n 1
}

download_to() {
  local url="$1"
  local out="$2"
  log "Download: $url"
  curl -fL --retry 3 --retry-delay 1 -o "$out" "$url"
}

clean_provider_dir() {
  local providers_dir="$1"
  # Remove jars that commonly cause split-package warnings or are not needed at runtime
  rm -f \
    "${providers_dir}"/*-tests.jar \
    "${providers_dir}"/*-test.jar \
    "${providers_dir}"/*-sources.jar \
    "${providers_dir}"/*-javadoc.jar 2>/dev/null || true
}

write_radius_config() {
  local config_path="$1"
  local shared_secret="$2"
  local auth_port="$3"
  local acct_port="$4"

  mkdir -p "$(dirname "$config_path")"

  # If file exists, keep other settings but enforce values we manage.
  if [[ -f "$config_path" ]]; then
    log "Aktualisiere bestehende radius.config: $config_path"
    tmp="$(mktemp)"
    jq --arg s "$shared_secret" \
       --argjson ap "$auth_port" \
       --argjson acp "$acct_port" \
       '
       .sharedSecret=$s
       | .authPort=$ap
       | .accountPort=$acp
       | .externalDictionary=null
       ' "$config_path" > "$tmp"
    mv "$tmp" "$config_path"
  else
    log "Erstelle radius.config: $config_path"
    cat >"$config_path" <<EOF
{
  "sharedSecret": "$shared_secret",
  "authPort": $auth_port,
  "accountPort": $acct_port,
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

  chmod 600 "$config_path"
}

restart_keycloak() {
  if systemctl list-unit-files | grep -q '^keycloak\.service'; then
    systemctl restart keycloak
    systemctl --no-pager -l status keycloak || true
  else
    warn "keycloak.service nicht gefunden. Bitte Keycloak manuell neu starten."
  fi
}

verify_ports() {
  local auth_port="$1"
  local acct_port="$2"
  log "Port-Check (UDP): ${auth_port}/${acct_port}"
  ss -lunp | egrep ":(${auth_port}|${acct_port})\b" || true
}

main() {
  need_root
  install_deps

  local KEYCLOAK_HOME
  KEYCLOAK_HOME="$(detect_keycloak_home)"
  log "Keycloak home: $KEYCLOAK_HOME"

  local PROVIDERS_DIR="${KEYCLOAK_HOME}/providers"
  mkdir -p "$PROVIDERS_DIR"
  log "Providers dir: $PROVIDERS_DIR"

  # ---- Tag selection (pin if provided) ----
  local TAG="${KC_RADIUS_TAG:-}"
  if [[ -z "$TAG" ]]; then
    log "Ermittle latest release tag via GitHub API…"
    TAG="$(gh_latest_tag)"
  fi
  [[ -n "$TAG" && "$TAG" != "null" ]] || die "Konnte Release-Tag nicht ermitteln."
  log "Release tag: $TAG"

  local release_json
  release_json="$(gh_release_by_tag "$TAG")"

  # ---- Asset resolution: prefer runtime jar if present; fallback to source build instructions otherwise ----
  # We try typical asset patterns:
  # - radius-plugin-*.jar
  # - keycloak-radius-plugin.jar (older naming)
  # - any zip that contains built jars (last resort)
  local RADIUS_JAR_URL
  RADIUS_JAR_URL="$(pick_asset_url "$release_json" 'radius-plugin-.*\.jar$')"
  if [[ -z "$RADIUS_JAR_URL" ]]; then
    RADIUS_JAR_URL="$(pick_asset_url "$release_json" 'keycloak-radius-plugin.*\.jar$')"
  fi

  if [[ -z "$RADIUS_JAR_URL" ]]; then
    # Some releases may only ship zips. Try to pick a zip that likely contains providers.
    local ZIP_URL
    ZIP_URL="$(pick_asset_url "$release_json" 'keycloak-radius.*\.zip$')"
    if [[ -z "$ZIP_URL" ]]; then
      ZIP_URL="$(pick_asset_url "$release_json" '.*\.zip$')"
    fi
    [[ -n "$ZIP_URL" ]] || die "Kein passendes Asset (jar/zip) im Release gefunden. Tag: $TAG"

    log "Release liefert kein direktes JAR. Verwende ZIP-Install (Extraktion und JAR-Suche)."
    local tmpdir
    tmpdir="$(mktemp -d)"
    download_to "$ZIP_URL" "${tmpdir}/release.zip"
    (cd "$tmpdir" && unzip -q release.zip)

    # Find radius-plugin jar inside extracted content
    local found
    found="$(find "$tmpdir" -type f -name 'radius-plugin-*.jar' | head -n 1 || true)"
    [[ -n "$found" ]] || die "Im ZIP wurde kein radius-plugin-*.jar gefunden."

    log "Kopiere radius-plugin JAR aus ZIP: $found"
    cp -f "$found" "$PROVIDERS_DIR/"
    rm -rf "$tmpdir"
  else
    log "Lade radius plugin JAR aus Release…"
    local out="${PROVIDERS_DIR}/$(basename "$RADIUS_JAR_URL")"
    download_to "$RADIUS_JAR_URL" "$out"
  fi

  # Remove unneeded jars if present
  clean_provider_dir "$PROVIDERS_DIR"

  # ---- Config ----
  local CONFIG_PATH="${KC_RADIUS_CONFIG_PATH:-${KEYCLOAK_HOME}/${RADIUS_CONFIG_DEFAULT_REL}}"
  log "Config file: $CONFIG_PATH"

  local DEFAULT_SECRET
  DEFAULT_SECRET="$(openssl rand -base64 48 | tr -d '\n')"

  local SHARED_SECRET AUTH_PORT ACCT_PORT
  prompt SHARED_SECRET "RADIUS Shared Secret (muss in UniFi identisch gesetzt werden)" "$DEFAULT_SECRET" "true"
  prompt AUTH_PORT "RADIUS Auth Port" "1812" "false"
  prompt ACCT_PORT "RADIUS Accounting Port" "1813" "false"

  # Ensure numeric
  [[ "$AUTH_PORT" =~ ^[0-9]+$ ]] || die "Auth Port ist keine Zahl."
  [[ "$ACCT_PORT" =~ ^[0-9]+$ ]] || die "Accounting Port ist keine Zahl."

  write_radius_config "$CONFIG_PATH" "$SHARED_SECRET" "$AUTH_PORT" "$ACCT_PORT"

  # ---- Build & restart ----
  log "kc.sh build…"
  "${KEYCLOAK_HOME}/bin/kc.sh" build

  log "Keycloak restart…"
  restart_keycloak

  verify_ports "$AUTH_PORT" "$ACCT_PORT"

  log "Fertig. Shared Secret steht in: $CONFIG_PATH (sharedSecret)"
  log "Hinweis: Für radtest/freeradius/unifi muss exakt dieses Shared Secret verwendet werden."
}

main "$@"
