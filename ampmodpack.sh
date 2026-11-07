#!/usr/bin/env bash
# ampmodpack.sh - CurseForge modpack installer/launcher for the AMP Generic module.
#
# Layout (inside the AMP instance):
#   <root>/server/   the Minecraft server (world, mods, configs) - the only thing players care about
#   <root>/tools/    this script, Java runtimes, mc-image-helper, install state
#   <root>/backups/  pre-update snapshots made by this script
#
# Subcommands:
#   update  install the modpack the first time, or upgrade/repair it (AMP "Update" button)
#   start   launch the server (AMP "Start" button); execs java so AMP owns the process
#   status  print what is installed (for troubleshooting from a shell)
#
# The CurseForge API key is passed by AMP as an argument and handed to mc-image-helper through
# the CF_API_KEY environment variable. It is never written to disk by this script.

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.2"
DEFAULT_HELPER_VERSION="1.76.0"
DEFAULT_EXCLUDE_FILE="https://raw.githubusercontent.com/itzg/docker-minecraft-server/master/files/cf-exclude-include.json"

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TOOLS_DIR")"
SERVER_DIR="$ROOT_DIR/server"
BACKUP_DIR="$ROOT_DIR/backups"
STATE_DIR="$TOOLS_DIR/state"
JAVA_DIR="$TOOLS_DIR/java"
HELPER_DIR="$TOOLS_DIR/mc-image-helper"
PID_FILE="$STATE_DIR/server.pid"
RUNTIME_ENV="$STATE_DIR/runtime.env"
RESULTS_FILE="$STATE_DIR/install-results.env"
PACK_HASHES="$STATE_DIR/pack-files.sha256"
CF_MANIFEST="$SERVER_DIR/.curseforge-manifest.json"

# Files that belong to the server operator, not the pack. Always preserved across updates.
ALWAYS_KEEP=(
  server.properties ops.json whitelist.json banned-ips.json banned-players.json
  eula.txt usercache.json usernamecache.json
)

# Messages go to fd 3 (a copy of the real stdout) so they still reach AMP's console when they are
# printed from inside a $(command substitution).
exec 3>&1
log()  { printf '[modpack] %s\n' "$*" >&3; }
warn() { printf '[modpack] WARNING: %s\n' "$*" >&3; }
die()  { printf '[modpack] ERROR: %s\n' "$*" >&3; exit 1; }

is_true() { case "${1,,}" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }

# AMP leaves a placeholder untouched if a setting does not exist; treat "{{...}}" as empty.
clean() { case "$1" in *'{{'*'}}'*) printf '' ;; *) printf '%s' "$1" ;; esac; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ---------------------------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------------------------
fetch() { # fetch URL OUTFILE
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 -O "$out" "$url"
  else
    die "Neither curl nor wget is available to download $url"
  fi
}

fetch_text() { # fetch_text URL  -> stdout
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 20 "$1"
  else
    wget -q --tries=2 --timeout=20 -O - "$1"
  fi
}

cpu_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Java (Eclipse Temurin JRE downloaded into tools/java/<major>)
# ---------------------------------------------------------------------------------------------
ensure_temurin() { # ensure_temurin MAJOR [refresh]  -> prints JAVA_HOME
  local major="$1" refresh="${2:-refresh}" arch home latest current tmp
  arch="$(cpu_arch)"
  home="$JAVA_DIR/$major"
  current="$(cat "$home/.release_name" 2>/dev/null || true)"

  if [[ -x "$home/bin/java" && ( "$refresh" != "refresh" || -n "${AMPMODPACK_NO_JAVA_REFRESH:-}" ) ]]; then
    printf '%s' "$home"; return 0
  fi

  latest="$(fetch_text "https://api.adoptium.net/v3/assets/latest/${major}/hotspot?architecture=${arch}&image_type=jre&os=linux&vendor=eclipse" 2>/dev/null \
            | grep -o '"release_name" *: *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"

  if [[ -x "$home/bin/java" ]]; then
    if [[ -z "$latest" || "$latest" == "$current" ]]; then
      [[ -z "$latest" ]] && warn "Could not check for Java $major updates; keeping $current"
      printf '%s' "$home"; return 0
    fi
  fi

  log "Downloading Eclipse Temurin Java $major JRE ${latest:+($latest)}..."
  mkdir -p "$JAVA_DIR"
  tmp="$(mktemp -d "$JAVA_DIR/.dl-XXXXXX")"
  if ! fetch "https://api.adoptium.net/v3/binary/latest/${major}/ga/linux/${arch}/jre/hotspot/normal/eclipse" "$tmp/java.tar.gz"; then
    rm -rf "$tmp"
    [[ -x "$home/bin/java" ]] && { warn "Java download failed; keeping existing $current"; printf '%s' "$home"; return 0; }
    die "Could not download Java $major from api.adoptium.net"
  fi
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/java.tar.gz" -C "$tmp/x" --strip-components=1
  [[ -x "$tmp/x/bin/java" ]] || { rm -rf "$tmp"; die "Downloaded Java $major archive did not contain bin/java"; }
  printf '%s' "${latest:-unknown}" > "$tmp/x/.release_name"
  rm -rf "$home"
  mv "$tmp/x" "$home"
  rm -rf "$tmp"
  log "Java $major ready: $("$home/bin/java" -version 2>&1 | head -n1)"
  printf '%s' "$home"
}

# Minecraft version -> required Java major version.
java_for_mc() {
  local v="$1" major minor patch
  IFS=. read -r major minor patch <<<"$v"
  minor="${minor:-0}"; patch="${patch:-0}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || { echo 21; return; }
  if (( major == 1 )); then
    if   (( minor <= 16 )); then echo 8
    elif (( minor <= 19 )); then echo 17
    elif (( minor == 20 && patch <= 4 )); then echo 17
    else echo 21
    fi
  elif (( major >= 26 )); then echo 25   # year-based versions (26.1+) need Java 25
  else echo 21
  fi
}

# Resolve the java binary for a JavaRuntime setting. MODE: refresh (update) | norefresh (start)
resolve_java() { # resolve_java CHOICE CUSTOM_PATH MC_VERSION MODE -> prints path to java binary
  local choice="$1" custom="$2" mc="$3" mode="$4" major home
  case "$choice" in
    ""|auto)
      if [[ -n "$mc" ]]; then major="$(java_for_mc "$mc")"; else major=21; fi ;;
    8|11|16|17|21|25) major="$choice" ;;
    system)
      command -v java >/dev/null 2>&1 || die "Java setting is 'container/system java' but no java is on PATH"
      command -v java; return 0 ;;
    custom)
      [[ -n "$custom" ]] || die "Java setting is 'custom path' but the custom Java path is empty"
      [[ -d "$custom" && -x "$custom/bin/java" ]] && { printf '%s' "$custom/bin/java"; return 0; }
      [[ -x "$custom" ]] || die "Custom Java path is not executable: $custom"
      printf '%s' "$custom"; return 0 ;;
    *) die "Unknown Java setting: $choice" ;;
  esac
  if [[ "$mode" == "norefresh" ]]; then
    [[ -x "$JAVA_DIR/$major/bin/java" ]] || die "Java $major is not downloaded yet. Run Update once after changing the Java setting."
    printf '%s' "$JAVA_DIR/$major/bin/java"; return 0
  fi
  home="$(ensure_temurin "$major" refresh)"
  printf '%s' "$home/bin/java"
}

java_major_of() { # java_major_of /path/to/java -> 8, 17, 21, ...
  local v
  v="$("$1" -version 2>&1 | head -n1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
  case "$v" in 1.*) v="${v#1.}" ;; esac
  printf '%s' "${v%%[.+-]*}"
}

# ---------------------------------------------------------------------------------------------
# mc-image-helper
# ---------------------------------------------------------------------------------------------
ensure_helper() { # ensure_helper VERSION -> prints install dir
  local ver="$1" dir tmp sum_expected sum_actual
  if [[ "$ver" == "latest" ]]; then
    ver="$(fetch_text https://api.github.com/repos/itzg/mc-image-helper/releases/latest 2>/dev/null \
           | grep -o '"tag_name" *: *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [[ -n "$ver" ]] || die "Could not look up the latest mc-image-helper release"
  fi
  dir="$HELPER_DIR/$ver"
  if [[ -x "$dir/bin/mc-image-helper" ]]; then printf '%s' "$dir"; return 0; fi

  log "Downloading mc-image-helper $ver..."
  mkdir -p "$HELPER_DIR"
  tmp="$(mktemp -d "$HELPER_DIR/.dl-XXXXXX")"
  local base="https://github.com/itzg/mc-image-helper/releases/download/${ver}/mc-image-helper-${ver}.tgz"
  fetch "$base" "$tmp/helper.tgz" || { rm -rf "$tmp"; die "Could not download $base"; }
  if fetch "$base.sha256" "$tmp/helper.tgz.sha256" 2>/dev/null && command -v sha256sum >/dev/null 2>&1; then
    sum_expected="$(awk '{print $1}' "$tmp/helper.tgz.sha256")"
    sum_actual="$(sha256sum "$tmp/helper.tgz" | awk '{print $1}')"
    [[ "$sum_expected" == "$sum_actual" ]] || { rm -rf "$tmp"; die "mc-image-helper checksum mismatch"; }
  else
    warn "Could not verify mc-image-helper checksum"
  fi
  tar -xzf "$tmp/helper.tgz" -C "$tmp"
  [[ -x "$tmp/mc-image-helper-${ver}/bin/mc-image-helper" ]] || chmod +x "$tmp/mc-image-helper-${ver}/bin/mc-image-helper"
  rm -rf "$dir"
  mv "$tmp/mc-image-helper-${ver}" "$dir"
  rm -rf "$tmp"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------------------------
# Helpers for the installed pack
# ---------------------------------------------------------------------------------------------
manifest_value() { # manifest_value KEY -> string value from .curseforge-manifest.json
  [[ -f "$CF_MANIFEST" ]] || return 0
  tr -d '\n' < "$CF_MANIFEST" | grep -o "\"$1\" *: *\"[^\"]*\"" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true
}

manifest_number() {
  [[ -f "$CF_MANIFEST" ]] || return 0
  tr -d '\n' < "$CF_MANIFEST" | grep -o "\"$1\" *: *[0-9]*" | head -n1 | sed 's/.*: *//' || true
}

manifest_files() { # list of files the helper installed (relative to server dir), one per line
  [[ -f "$CF_MANIFEST" ]] || return 0
  tr -d '\n' < "$CF_MANIFEST" \
    | sed -n 's/.*"files" *: *\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | sed 's#\\/#/#g' | grep -v '^$' || true
}

server_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  grep -qa java "/proc/$pid/cmdline" 2>/dev/null
}

set_property() { # set_property FILE KEY VALUE   (edit in place, keep everything else)
  local file="$1" key="$2" value="$3"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
    local cur; cur="$(grep -m1 "^${key}=" "$file" | cut -d= -f2-)"
    [[ "$cur" == "$value" ]] && return 0
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

level_name() {
  local n=""
  [[ -f "$SERVER_DIR/server.properties" ]] && n="$(grep -m1 '^level-name=' "$SERVER_DIR/server.properties" | cut -d= -f2- || true)"
  printf '%s' "${n:-world}"
}

# ---------------------------------------------------------------------------------------------
# Pre-update backup
# ---------------------------------------------------------------------------------------------
pre_update_backup() { # pre_update_backup KEEP
  local keep="$1" stamp out items=() f level
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  level="$(level_name)"
  (
    cd "$SERVER_DIR"
    for f in "$level" "${level}_nether" "${level}_the_end" config defaultconfigs kubejs serverconfig \
             .curseforge-manifest.json "${ALWAYS_KEEP[@]}"; do
      [[ -e "$f" ]] && items+=("$f")
    done
    # Back up the hash list too, so a restored backup still knows which configs you edited
    [[ ${#items[@]} -gt 0 ]] || { log "Nothing to back up yet"; exit 0; }
    mkdir -p "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S)"
    out="$BACKUP_DIR/pre-update-${stamp}.tar.gz"
    log "Backing up world and configs to backups/$(basename "$out") ..."
    tar -czf "$out.partial" "${items[@]}"
    mv "$out.partial" "$out"
    log "Backup done ($(du -h "$out" | cut -f1))"
  )
  # Rotate: keep the newest $keep
  if (( keep > 0 )); then
    ls -1t "$BACKUP_DIR"/pre-update-*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
      log "Removing old backup $(basename "$old")"; rm -f -- "$old"
    done
  fi
}

# ---------------------------------------------------------------------------------------------
# CurseForge API key check (gives a clear message instead of mc-image-helper's generic error)
# ---------------------------------------------------------------------------------------------
API_KEY_FILE_NAME="curseforge-api-key.txt"   # optional, in the instance's curseforge-modpack/ folder

api_probe() { # api_probe KEY -> HTTP status code from CurseForge ("" if unreachable)
  local key="$1" url="https://api.curseforge.com/v1/games/432"
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w '%{http_code}' --connect-timeout 20 -H "x-api-key: $key" -H 'Accept: application/json' "$url" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -q -S -O /dev/null --timeout=20 --header="x-api-key: $key" --header='Accept: application/json' "$url" 2>&1 \
      | awk '/^ *HTTP\//{c=$2} END{print c}' || true
  fi
}

describe_key() { # describe_key LABEL KEY  - never prints the key itself
  local label="$1" key="$2" odd
  # "$2a$10$" is the same for every CurseForge key, so it is safe to show.
  odd="$(printf '%s' "$key" | tr -d 'A-Za-z0-9./$' | od -An -c | tr -s ' ' | sed 's/^ //; s/ $//')"
  log "$label: ${#key} characters (a real key has 60), starts with '${key:0:7}'${odd:+, unexpected characters: [$odd]}"
}

# Picks a working API key: the AMP setting as given, the setting with stray characters removed
# (in case AMP escaped or quoted it), or the key file. Sets API_KEY.
resolve_api_key() {
  local setting="$1" file="$ROOT_DIR/$API_KEY_FILE_NAME" candidates=() labels=() i code first_code=""
  if [[ -n "$setting" ]]; then
    candidates+=("$setting"); labels+=("API key from the AMP setting")
    local cleaned; cleaned="$(printf '%s' "$setting" | tr -cd 'A-Za-z0-9./$')"
    if [[ "$cleaned" != "$setting" && -n "$cleaned" ]]; then
      candidates+=("$cleaned"); labels+=("API key from the AMP setting, stray characters removed")
    fi
  fi
  if [[ -f "$file" ]]; then
    candidates+=("$(tr -d ' \t\r\n' < "$file")"); labels+=("API key from $API_KEY_FILE_NAME")
  fi
  (( ${#candidates[@]} > 0 )) || die "No CurseForge API key. Set 'CurseForge API Key' in the instance settings (or put it in curseforge-modpack/$API_KEY_FILE_NAME), then Update again."

  for i in "${!candidates[@]}"; do
    describe_key "${labels[$i]}" "${candidates[$i]}"
    code="$(api_probe "${candidates[$i]}")"
    [[ -n "$first_code" ]] || first_code="${code:-none}"
    if [[ "$code" == 200 ]]; then
      log "CurseForge accepted it"
      API_KEY="${candidates[$i]}"; return 0
    fi
    log "CurseForge answered HTTP ${code:-'(no response)'}"
    if [[ "$code" != 401 && "$code" != 403 ]]; then
      warn "Could not verify the key with CurseForge; trying it anyway"
      API_KEY="${candidates[$i]}"; return 0
    fi
  done
  die "CurseForge rejected the API key (HTTP $first_code). Copy it again from https://console.curseforge.com/ (API keys). If it is definitely right, put it in a text file named $API_KEY_FILE_NAME in the instance's curseforge-modpack/ folder and clear the setting."
}

# ---------------------------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------------------------
cmd_update() {
  local source="" version="" api_key="" java_choice="auto" java_path="" protect="modified"
  local backup="true" backup_keep="3" exclude_file="" exclude_mods="" include_mods=""
  local loader_version="" force="false" helper_version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source="$(clean "${2-}")"; shift 2 ;;
      --version) version="$(clean "${2-}")"; shift 2 ;;
      --api-key) api_key="$(clean "${2-}")"; shift 2 ;;
      --java) java_choice="$(clean "${2-}")"; shift 2 ;;
      --java-path) java_path="$(clean "${2-}")"; shift 2 ;;
      --protect) protect="$(clean "${2-}")"; shift 2 ;;
      --backup) backup="$(clean "${2-}")"; shift 2 ;;
      --backup-keep) backup_keep="$(clean "${2-}")"; shift 2 ;;
      --exclude-file) exclude_file="$(clean "${2-}")"; shift 2 ;;
      --exclude-mods) exclude_mods="$(clean "${2-}")"; shift 2 ;;
      --include-mods) include_mods="$(clean "${2-}")"; shift 2 ;;
      --loader-version) loader_version="$(clean "${2-}")"; shift 2 ;;
      --force) force="$(clean "${2-}")"; shift 2 ;;
      --helper-version) helper_version="$(clean "${2-}")"; shift 2 ;;
      *) die "Unknown update option: $1" ;;
    esac
  done
  source="$(trim "$source")"; version="$(trim "$version")"; api_key="$(trim "$api_key")"
  helper_version="$(trim "${helper_version:-$DEFAULT_HELPER_VERSION}")"
  [[ -n "$protect" ]] || protect="modified"

  log "ampmodpack $SCRIPT_VERSION - update"
  [[ -n "$source" ]]  || die "Set 'Modpack' (CurseForge page URL or slug) in the instance settings, then Update again."
  if server_running; then die "The server is still running. Stop it first, then Update."; fi
  resolve_api_key "$api_key"; api_key="$API_KEY"

  mkdir -p "$SERVER_DIR" "$STATE_DIR" "$SERVER_DIR/manual-downloads"

  # --- tools
  local helper helper_java_home server_java mc_prev
  helper="$(ensure_helper "$helper_version")"
  log "mc-image-helper: $(basename "$helper")"
  helper_java_home="$(ensure_temurin 21 refresh)"   # mc-image-helper itself needs Java 17+

  mc_prev="$(manifest_value minecraftVersion)"
  server_java="$(resolve_java "$java_choice" "$java_path" "$mc_prev" refresh)"

  # --- what the user asked for
  local args=(install-curseforge
    --output-directory="$SERVER_DIR"
    --results-file="$RESULTS_FILE"
    --downloads-repo="$SERVER_DIR/manual-downloads"
    --use-http2=false
  )
  if [[ "$source" =~ ^https?:// ]]; then
    args+=(--modpack-page-url="$source")
  else
    args+=(--slug="${source,,}")
  fi
  if [[ -n "$version" ]]; then
    if [[ "$version" =~ ^[0-9]+$ ]]; then
      args+=(--file-id="$version")
    elif [[ "$version" =~ ^https?:// ]]; then
      # a .../files/<id> URL: use the id
      local fid; fid="$(sed -n 's#.*/files/\([0-9][0-9]*\).*#\1#p' <<<"$version")"
      [[ -n "$fid" ]] || die "Could not find a file ID in pinned version URL: $version"
      args+=(--file-id="$fid")
    else
      args+=(--filename-matcher="$version")
    fi
    log "Pinned version: $version"
  else
    log "Version: latest"
  fi
  case "${exclude_file,,}" in
    none|off|false) ;;
    "") args+=(--exclude-include-file="$DEFAULT_EXCLUDE_FILE") ;;
    *) args+=(--exclude-include-file="$exclude_file") ;;
  esac
  [[ -n "$(trim "$exclude_mods")" ]] && args+=(--exclude-mods="$(tr -d ' ' <<<"$exclude_mods")")
  [[ -n "$(trim "$include_mods")" ]] && args+=(--force-include-mods="$(tr -d ' ' <<<"$include_mods")")
  [[ -n "$(trim "$loader_version")" ]] && args+=(--mod-loader-version="$(trim "$loader_version")")
  if is_true "$force"; then args+=(--force-synchronize --force-reinstall-modloader); log "Repair mode: re-syncing all files and reinstalling the mod loader"; fi
  case "$protect" in
    existing) args+=(--overrides-skip-existing) ;;
    modified|pack) ;;
    *) die "Unknown config protection mode: $protect" ;;
  esac

  # --- back up
  if [[ -f "$CF_MANIFEST" ]] && is_true "$backup"; then
    pre_update_backup "$backup_keep"
  fi

  # --- protect the operator's files
  local stage keep_list=() f
  stage="$(mktemp -d "$STATE_DIR/.keep-XXXXXX")"
  for f in "${ALWAYS_KEEP[@]}"; do [[ -f "$SERVER_DIR/$f" ]] && keep_list+=("$f"); done
  if [[ "$protect" == "modified" && -f "$PACK_HASHES" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && keep_list+=("$f")
    done < <(cd "$SERVER_DIR" && sha256sum --quiet -c "$PACK_HASHES" 2>/dev/null | sed -n 's/: FAILED$//p' | grep -v '^mods/' || true)
  fi
  if (( ${#keep_list[@]} > 0 )); then
    mapfile -t keep_list < <(printf '%s\n' "${keep_list[@]}" | awk '!seen[$0]++')
  fi
  for f in "${keep_list[@]}"; do
    [[ -f "$SERVER_DIR/$f" ]] || continue
    mkdir -p "$stage/$(dirname "$f")"
    cp -p "$SERVER_DIR/$f" "$stage/$f"
  done
  if (( ${#keep_list[@]} > 0 )); then
    log "Protecting ${#keep_list[@]} file(s) from being overwritten: ${keep_list[*]}"
  fi

  restore_kept() {
    local g
    (cd "$stage" && find . -type f | sed 's#^\./##') | while IFS= read -r g; do
      if [[ -f "$SERVER_DIR/$g" ]] && ! cmp -s "$stage/$g" "$SERVER_DIR/$g"; then
        # The pack shipped a different version: keep the operator's, park the pack's for reference
        mkdir -p "$ROOT_DIR/pack-new-configs/$(dirname "$g")"
        cp -p "$SERVER_DIR/$g" "$ROOT_DIR/pack-new-configs/$g"
        log "Kept your version of $g (the pack's new version was saved to pack-new-configs/$g)"
      fi
      mkdir -p "$SERVER_DIR/$(dirname "$g")"
      cp -p "$stage/$g" "$SERVER_DIR/$g"
    done
  }

  # --- run mc-image-helper
  local manifest_before manifest_after rc=0
  manifest_before="$(sha256sum "$CF_MANIFEST" 2>/dev/null | awk '{print $1}' || true)"
  rm -f "$RESULTS_FILE"
  log "Running mc-image-helper install-curseforge (server Java: $server_java)"
  (
    cd "$SERVER_DIR"
    export JAVA_HOME="$helper_java_home"
    # The Forge/NeoForge installer is launched as plain "java" from PATH: use the server's Java
    PATH="$(dirname "$server_java"):$PATH"; export PATH
    export CF_API_KEY="$api_key"
    exec "$helper/bin/mc-image-helper" "${args[@]}" 3>&-
  ) || rc=$?

  if (( rc != 0 )); then
    restore_kept
    rm -rf "$stage"
    log "----------------------------------------------------------------------"
    if [[ -f "$SERVER_DIR/MODS_NEED_DOWNLOAD.txt" ]]; then
      log "Some mods do not allow automatic downloads. Download each file listed above (also in"
      log "server/MODS_NEED_DOWNLOAD.txt) from CurseForge, put them in server/manual-downloads/mods/,"
      log "then press Update again."
    fi
    log "Update FAILED (mc-image-helper exit code $rc). Your world was not touched."
    log "See README 'If an update fails'. Backups are in the backups/ folder."
    exit "$rc"
  fi

  # Record the pack's own file hashes BEFORE restoring operator files, so that next time we can
  # tell which pack files the operator edited. Skip when nothing was (re)installed.
  manifest_after="$(sha256sum "$CF_MANIFEST" 2>/dev/null | awk '{print $1}' || true)"
  if [[ "$manifest_after" != "$manifest_before" || ! -f "$PACK_HASHES" ]]; then
    (cd "$SERVER_DIR" && manifest_files | while IFS= read -r f; do
       [[ -f "$f" && "$f" != mods/* ]] && sha256sum -- "$f"
     done) > "$PACK_HASHES.tmp" || true
    mv "$PACK_HASHES.tmp" "$PACK_HASHES"
  fi
  restore_kept
  rm -rf "$stage"

  # --- work out how to start it
  local mc loader server_entry launch=""
  mc="$(manifest_value minecraftVersion)"
  loader="$(manifest_value modLoaderId)"
  server_entry="$(grep -m1 '^SERVER=' "$RESULTS_FILE" 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//' || true)"
  [[ -n "$server_entry" ]] || die "mc-image-helper did not report a server entry point (results file: $RESULTS_FILE)"
  server_entry="${server_entry#"$SERVER_DIR"/}"

  # Modern Forge/NeoForge (MC 1.17+): the installer writes run.sh containing
  #   java @user_jvm_args.txt @libraries/net/<loader>/<ver>/unix_args.txt "$@"
  # We run the same thing ourselves (so AMP owns the java process and our memory/JVM settings win).
  # Older Forge (a forge-*.jar) and Fabric (a launcher jar) use -jar.
  local unix_args=""
  if [[ -f "$SERVER_DIR/run.sh" ]]; then
    unix_args="$(grep -o '@libraries/[^ "]*/unix_args\.txt' "$SERVER_DIR/run.sh" | head -n1 || true)"
    [[ -n "$unix_args" && -f "$SERVER_DIR/${unix_args#@}" ]] || unix_args=""
  fi
  if [[ -n "$unix_args" && "$loader" =~ ^(neo)?forge ]]; then
    launch="$unix_args"
  elif [[ "$server_entry" == *.jar && -f "$SERVER_DIR/$server_entry" ]]; then
    launch="-jar $server_entry"
  else
    die "Could not work out how to start this server (entry point: '$server_entry', loader: '$loader')"
  fi

  # Java for running the server (auto mode now knows the Minecraft version)
  local run_java
  run_java="$(resolve_java "$java_choice" "$java_path" "$mc" refresh)"

  {
    printf 'MC_VERSION=%q\n' "$mc"
    printf 'MOD_LOADER=%q\n' "$loader"
    printf 'MODPACK_NAME=%q\n' "$(manifest_value modpackName)"
    printf 'MODPACK_VERSION=%q\n' "$(manifest_value modpackVersion)"
    printf 'MODPACK_FILE_ID=%q\n' "$(manifest_number fileId)"
    printf 'LAUNCH=%q\n' "$launch"
    printf 'UPDATED_AT=%q\n' "$(date -Iseconds)"
  } > "$RUNTIME_ENV"

  log "----------------------------------------------------------------------"
  log "Installed: $(manifest_value modpackName) $(manifest_value modpackVersion) (file $(manifest_number fileId))"
  log "Minecraft $mc, loader $loader, Java $(java_major_of "$run_java")"
  log "Start command: java ... $launch nogui"
  if [[ ! -f "$SERVER_DIR/eula.txt" ]] || ! grep -q '^eula=true' "$SERVER_DIR/eula.txt"; then
    log "Remember to tick 'Accept the Minecraft EULA' in the settings before starting."
  fi
  log "Update finished."
}

# ---------------------------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------------------------
cmd_start() {
  local java_choice="auto" java_path="" ram="" port="" eula="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --java) java_choice="$(clean "${2-}")"; shift 2 ;;
      --java-path) java_path="$(clean "${2-}")"; shift 2 ;;
      --ram) ram="$(clean "${2-}")"; shift 2 ;;
      --port) port="$(clean "${2-}")"; shift 2 ;;
      --eula) eula="$(clean "${2-}")"; shift 2 ;;
      --) shift; break ;;
      *) die "Unknown start option: $1" ;;
    esac
  done
  local jvm_args=()
  local a
  for a in "$@"; do a="$(clean "$a")"; [[ -n "$a" ]] && jvm_args+=("$a"); done

  [[ -f "$RUNTIME_ENV" ]] || die "The modpack is not installed yet. Press Update first."
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"

  is_true "$eula" || die "You must accept the Minecraft EULA (https://aka.ms/MinecraftEULA): tick 'Accept the Minecraft EULA' in the instance settings."
  printf '# Accepted via AMP instance setting\neula=true\n' > "$SERVER_DIR/eula.txt"

  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid server port: '$port'"
  set_property "$SERVER_DIR/server.properties" server-port "$port"

  [[ "$ram" =~ ^[0-9]+$ ]] || die "Invalid RAM setting: '$ram' (megabytes)"
  local xms=$(( ram < 2048 ? ram : 2048 ))

  local java
  java="$(resolve_java "$java_choice" "$java_path" "$MC_VERSION" norefresh)"
  local want; want="$(java_for_mc "$MC_VERSION")"
  local have; have="$(java_major_of "$java")"
  if [[ -n "$have" && "$have" =~ ^[0-9]+$ && "$have" -lt "$want" ]]; then
    warn "Minecraft $MC_VERSION needs Java $want or newer, but the selected Java is $have."
  fi

  mkdir -p "$STATE_DIR"
  echo $$ > "$PID_FILE"
  cd "$SERVER_DIR"
  log "Starting $MODPACK_NAME $MODPACK_VERSION (Minecraft $MC_VERSION, $MOD_LOADER) with Java $have, ${ram} MB"
  # shellcheck disable=SC2086
  exec "$java" "-Xms${xms}M" "-Xmx${ram}M" "${jvm_args[@]}" $LAUNCH nogui 3>&-
}

cmd_status() {
  echo "Root:    $ROOT_DIR"
  echo "Server:  $SERVER_DIR"
  [[ -f "$RUNTIME_ENV" ]] && cat "$RUNTIME_ENV" || echo "Not installed yet"
  echo "Java runtimes:"; ls -1 "$JAVA_DIR" 2>/dev/null | sed 's/^/  /' || true
  echo "mc-image-helper:"; ls -1 "$HELPER_DIR" 2>/dev/null | sed 's/^/  /' || true
  echo "Server running: $(server_running && echo yes || echo no)"
  echo "Backups:"; ls -1sh "$BACKUP_DIR" 2>/dev/null | sed 's/^/  /' || true
}

case "${1:-}" in
  update) shift; cmd_update "$@" ;;
  start)  shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) echo "Usage: $0 {update|start|status} [options]"; exit 2 ;;
esac
