#!/usr/bin/env bash
# Shared implementation for Codex credential export/import.
# Exposes codex_auth_transfer_main which expects the first argument
# to indicate the operating system (linux|macos) followed by the
# regular CLI arguments.

# shellcheck shell=bash

PROGRAM_NAME="codex-auth-transfer"
DEFAULT_BUNDLE_NAME="codex-auth-bundle.tar.gz"

codex_auth_transfer::log() {
  printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

codex_auth_transfer::err() {
  printf '[%s][ERROR] %s\n' "$PROGRAM_NAME" "$*" 1>&2
}

codex_auth_transfer::usage() {
  cat <<'USAGE'
Usage:
  codex-auth-transfer.sh export [-o <bundle>]
  codex-auth-transfer.sh import [-f <bundle>] [--force]

Options:
  export            Create an archive with Codex CLI credentials.
  import            Restore credentials from a bundle into the current HOME.
  -o, --output      Name of the bundle to generate (default: codex-auth-bundle.tar.gz).
  -f, --file        Bundle file to restore from (default: codex-auth-bundle.tar.gz).
  --force           Backup and overwrite destinations if they already exist.
  -h, --help        Show this help message.

Environment:
  CODEX_AUTH_TRANSFER_NO_METADATA=1  Skip recording user/host metadata in manifest.
USAGE
}

codex_auth_transfer::timestamp() {
  date +%Y%m%d-%H%M%S
}

codex_auth_transfer::mktemp_dir() {
  local tmp
  if tmp=$(mktemp -d 2>/dev/null); then
    printf '%s\n' "$tmp"
    return 0
  fi
  # macOS' mktemp requires a template.
  tmp=$(mktemp -d -t codex-auth-transfer)
  printf '%s\n' "$tmp"
}

codex_auth_transfer::hash_path() {
  local path="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$path" | sha1sum | awk '{print $1}'
  else
    printf '%s' "$path" | shasum | awk '{print $1}'
  fi
}

codex_auth_transfer::collect_candidates() {
  local os_hint="$1"
  local home="$HOME"
  local base_config base_data
  local -a candidates=()

  case "$os_hint" in
    linux)
      base_config="${XDG_CONFIG_HOME:-$home/.config}"
      base_data="${XDG_DATA_HOME:-$home/.local/share}"
      candidates+=("$base_config/codex" "$base_data/codex" "$home/.codex")
      ;;
    macos)
      base_config="${XDG_CONFIG_HOME:-$home/.config}"
      base_data="${XDG_DATA_HOME:-$home/Library/Application Support}" # fallback to mac convention
      candidates+=(
        "$base_config/codex"
        "$home/Library/Application Support/Codex"
        "$home/Library/Application Support/OpenAI"
        "$home/Library/Application Support/com.openai.codex"
        "$home/.codex"
      )
      ;;
    *)
      codex_auth_transfer::err "Unknown OS hint: $os_hint"
      return 1
      ;;
  esac

  if command -v codex >/dev/null 2>&1; then
    local hinted
    hinted=$(codex config path 2>/dev/null || true)
    if [ -n "${hinted:-}" ] && [ -d "$hinted" ]; then
      candidates=("$hinted" "${candidates[@]}")
    fi
  fi

  local path existing=() found prev
  for path in "${candidates[@]}"; do
    [ -z "$path" ] && continue
    if [ -e "$path" ]; then
      found=0
      for prev in "${existing[@]}"; do
        if [ "$prev" = "$path" ]; then
          found=1
          break
        fi
      done
      [ "$found" -eq 1 ] && continue
      existing+=("$path")
    fi
  done

  for path in "${existing[@]}"; do
    printf '%s\n' "$path"
  done
}

codex_auth_transfer::normalize_bundle_path() {
  local bundle="$1"
  if [ -z "$bundle" ]; then
    printf '%s\n' "$PWD/$DEFAULT_BUNDLE_NAME"
    return 0
  fi
  local dir base
  dir=$(dirname -- "$bundle")
  base=$(basename -- "$bundle")
  if [ "$dir" = "." ]; then
    printf '%s/%s\n' "$PWD" "$base"
  else
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$PWD" "$base")
  fi
}

codex_auth_transfer::stage_paths() {
  local os_hint="$1"
  local stage_dir="$2"
  local list_file="$3"

  local -a paths=()
  while IFS= read -r line; do
    [ -n "$line" ] && paths+=("$line")
  done < <(codex_auth_transfer::collect_candidates "$os_hint")

  if [ "${#paths[@]}" -eq 0 ]; then
    codex_auth_transfer::err "No Codex credential directories were found."
    return 1
  fi

  codex_auth_transfer::log "Detected credential locations:" "$os_hint"
  local p
  for p in "${paths[@]}"; do
    codex_auth_transfer::log "  - $p"
  done

  : > "$list_file"

  local rel dest hash
  for p in "${paths[@]}"; do
    if [ "${p#"$HOME"/}" != "$p" ]; then
      rel=".${p#"$HOME"}"
    else
      hash=$(codex_auth_transfer::hash_path "$p")
      rel=".codex-external/$hash"
    fi

    dest="$stage_dir/$rel"
    mkdir -p "$(dirname -- "$dest")"

    if [ -d "$p" ]; then
      mkdir -p "$dest"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --chmod=Du+rwx,Fu+rw "$p/" "$dest/"
      else
        cp -a "$p/." "$dest/"
        find "$dest" -type d -exec chmod 700 {} +
        find "$dest" -type f -exec chmod 600 {} +
      fi
    else
      mkdir -p "$(dirname -- "$dest")"
      cp "$p" "$dest"
      chmod 600 "$dest" 2>/dev/null || true
    fi

    printf '%s\n' "$rel" >> "$list_file"
  done
}

codex_auth_transfer::write_manifest() {
  local stage_dir="$1"
  local manifest="$stage_dir/.codex_auth_manifest"

  {
    printf 'created_at=%s\n' "$(date -Iseconds)"
    printf 'paths_file=%s\n' ".codex_auth_paths.txt"
    if [ "${CODEX_AUTH_TRANSFER_NO_METADATA:-0}" != "1" ]; then
      printf 'user=%s\n' "${USER:-}"
      printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    fi
  } > "$manifest"
}

codex_auth_transfer::backup_path() {
  local target="$1"
  if [ -e "$target" ]; then
    local backup="${target}.bak-$(codex_auth_transfer::timestamp)"
    codex_auth_transfer::log "Backing up existing path: $target -> $backup"
    mv "$target" "$backup"
  fi
}

codex_auth_transfer::enforce_permissions() {
  local path="$1"
  find "$path" -type d -exec chmod 700 {} +
  find "$path" -type f -exec chmod 600 {} +
}

codex_auth_transfer::do_export() {
  local os_hint="$1"
  local bundle_path
  bundle_path=$(codex_auth_transfer::normalize_bundle_path "$2")

  local tmpdir stage listfile
  tmpdir=$(codex_auth_transfer::mktemp_dir)
  stage="$tmpdir/stage"
  mkdir -p "$stage"
  listfile="$stage/.codex_auth_paths.txt"

  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

  codex_auth_transfer::stage_paths "$os_hint" "$stage" "$listfile"

  codex_auth_transfer::write_manifest "$stage"

  (cd "$stage" && tar -czf "$bundle_path" .)
  chmod 600 "$bundle_path" 2>/dev/null || true

  codex_auth_transfer::log "Bundle created at $bundle_path"
  codex_auth_transfer::log "Transfer it over a secure channel only."
}

codex_auth_transfer::read_list_file() {
  local tmpdir="$1"
  local listfile="$tmpdir/.codex_auth_paths.txt"
  if [ ! -f "$listfile" ]; then
    codex_auth_transfer::log "Path list missing; attempting to infer from archive contents..."
    (cd "$tmpdir" && find . -maxdepth 3 -type d \
      \( -path './.config/codex' -o -path './.local/share/codex' \
         -o -path './.codex' -o -path './.codex-external/*' \) \
      | sed 's|^./||') > "$listfile"
  fi
  if [ ! -s "$listfile" ]; then
    codex_auth_transfer::err "No credential paths found in bundle."
    return 1
  fi
  printf '%s\n' "$listfile"
}

codex_auth_transfer::do_import() {
  local os_hint="$1"
  local bundle_path
  bundle_path=$(codex_auth_transfer::normalize_bundle_path "$2")
  local force_flag="$3"

  if [ ! -f "$bundle_path" ]; then
    codex_auth_transfer::err "Bundle not found: $bundle_path"
    return 1
  fi

  local tmpdir
  tmpdir=$(codex_auth_transfer::mktemp_dir)
  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

  codex_auth_transfer::log "Extracting bundle $bundle_path ..."
  tar -xzf "$bundle_path" -C "$tmpdir"

  local listfile
  listfile=$(codex_auth_transfer::read_list_file "$tmpdir")

  codex_auth_transfer::log "Restoring credential directories:"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    codex_auth_transfer::log "  - $rel"
    local src="$tmpdir/$rel"
    local dest="$HOME/$rel"

    mkdir -p "$(dirname -- "$dest")"
    if [ -e "$dest" ]; then
      if [ "$force_flag" = "1" ]; then
        codex_auth_transfer::backup_path "$dest"
      else
        codex_auth_transfer::err "Destination already exists: $dest"
        codex_auth_transfer::err "Re-run with --force to backup and overwrite."
        return 1
      fi
    fi

    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --chmod=Du+rwx,Fu+rw "$src/" "$dest/"
    else
      cp -a "$src/." "$dest/"
    fi

    codex_auth_transfer::enforce_permissions "$dest"
  done < "$listfile"

  codex_auth_transfer::log "Credentials restored under $HOME."
  codex_auth_transfer::log "If Codex rejects the tokens, re-run login via secure channel."
}

codex_auth_transfer_main() {
  local os_hint="$1"
  shift || true

  local cmd=""
  local bundle=""
  local force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      export|import)
        cmd="$1"
        shift
        ;;
      -o|--output)
        bundle="$2"
        shift 2
        ;;
      -f|--file)
        bundle="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        codex_auth_transfer::usage
        return 0
        ;;
      *)
        codex_auth_transfer::err "Unknown option: $1"
        codex_auth_transfer::usage
        return 1
        ;;
    esac
  done

  if [ -z "$cmd" ]; then
    codex_auth_transfer::usage
    return 1
  fi

  if [ -z "$bundle" ]; then
    bundle="$DEFAULT_BUNDLE_NAME"
  fi

  case "$cmd" in
    export)
      codex_auth_transfer::do_export "$os_hint" "$bundle"
      ;;
    import)
      codex_auth_transfer::do_import "$os_hint" "$bundle" "$force"
      ;;
  esac
}
