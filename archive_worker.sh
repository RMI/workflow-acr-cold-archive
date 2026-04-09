#!/usr/bin/env bash
set -Eeuo pipefail

: "${SCRATCH_DIR:=/mnt/scratch}"
: "${PIGZ_LEVEL:=1}"
: "${AZURE_STORAGE_AUTH_MODE:=login}"
: "${QUEUE_VISIBILITY_TIMEOUT_SECONDS:=3600}"
: "${QUEUE_MESSAGE_FILE:=}"
: "${VERBOSE:=1}"

START_EPOCH="$(date +%s)"
LAST_STEP_EPOCH="$START_EPOCH"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 127
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env var: $name" >&2
    exit 2
  fi
}

require_cmd az
require_cmd skopeo
require_cmd pigz
require_cmd jq
require_cmd date
require_cmd base64
require_cmd wc
require_cmd du

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

vlog() {
  if [[ "$VERBOSE" == "1" ]]; then
    log "$*"
  fi
}

step() {
  local now elapsed total
  now="$(date +%s)"
  elapsed="$((now - LAST_STEP_EPOCH))"
  total="$((now - START_EPOCH))"
  LAST_STEP_EPOCH="$now"
  log "STEP: $* | elapsed=${elapsed}s total=${total}s"
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  log "ERROR: exit_code=${exit_code} line=${line_no}"
  if [[ -n "${MESSAGE_ID:-}" && -n "${QUEUE_NAME:-}" ]]; then
  log "Queue message will remain undeleted and become visible again after timeout if not already expired"
  fi
}
trap 'on_error $? $LINENO' ERR

run_cmd() {
  vlog "CMD: $*"
  "$@"
}

login_azure() {
  step "Logging into Azure"
  export APPSETTING_WEBSITE_SITE_NAME=DUMMY
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    log "Using user-assigned managed identity client_id=${AZURE_CLIENT_ID}"
    run_cmd az login --identity --client-id "$AZURE_CLIENT_ID" >/dev/null
  else
    log "Using system-assigned managed identity"
    run_cmd az login --identity >/dev/null
  fi
}

queue_mode_enabled() {
  [[ -n "${QUEUE_ACCOUNT:-}" && -n "${QUEUE_NAME:-}" ]]
}

read_message_from_file() {
  if [[ -z "$QUEUE_MESSAGE_FILE" ]]; then
    echo "QUEUE_MESSAGE_FILE must be set when not using queue mode" >&2
    exit 2
  fi
  step "Reading message from file"
  MESSAGE_ID="local-file"
  MESSAGE_JSON="$(cat "$QUEUE_MESSAGE_FILE")"
  vlog "Loaded local message file ${QUEUE_MESSAGE_FILE}"
}

read_message_from_queue() {
  require_env QUEUE_ACCOUNT
  require_env QUEUE_NAME

  step "Claiming one queue message"
  log "Queue account=${QUEUE_ACCOUNT} queue=${QUEUE_NAME} visibility_timeout=${QUEUE_VISIBILITY_TIMEOUT_SECONDS}s"

  local raw
  raw="$(az storage message get \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$QUEUE_ACCOUNT" \
    --queue-name "$QUEUE_NAME" \
    --visibility-timeout "$QUEUE_VISIBILITY_TIMEOUT_SECONDS" \
    --num-messages 1 \
    --output json)"

  if [[ "$(jq 'length' <<<"$raw")" -eq 0 ]]; then
    log "No queue messages available"
    exit 0
  fi

  MESSAGE_ID="$(jq -r '.[0].id' <<<"$raw")"
  POP_RECEIPT="$(jq -r '.[0].popReceipt' <<<"$raw")"
  MESSAGE_TEXT_B64="$(jq -r '.[0].content' <<<"$raw")"
  MESSAGE_JSON="$(printf '%s' "$MESSAGE_TEXT_B64" | base64 --decode)"

  log "Claimed queue message id=${MESSAGE_ID}"
  vlog "Decoded message payload: ${MESSAGE_JSON}"
}

read_message() {
  if queue_mode_enabled; then
    read_message_from_queue
  else
    read_message_from_file
  fi

  IMAGE_REF="$(jq -r '.image' <<<"$MESSAGE_JSON")"
  BLOB_CONTAINER="$(jq -r '.blobContainer' <<<"$MESSAGE_JSON")"
  BLOB_BASENAME="$(jq -r '.blobBaseName' <<<"$MESSAGE_JSON")"

  if [[ -z "$IMAGE_REF" || "$IMAGE_REF" == "null" ]]; then
    echo "queue message missing .image" >&2
  exit 2
  fi
  if [[ -z "$BLOB_CONTAINER" || "$BLOB_CONTAINER" == "null" ]]; then
    echo "queue message missing .blobContainer" >&2
  exit 2
  fi
  if [[ -z "$BLOB_BASENAME" || "$BLOB_BASENAME" == "null" ]]; then
    echo "queue message missing .blobBaseName" >&2
  exit 2
  fi

  log "Resolved work item image=${IMAGE_REF} blob_container=${BLOB_CONTAINER} blob_name=${BLOB_BASENAME}"
}

parse_image_ref() {
  step "Parsing image reference"
  LOGIN_SERVER="${IMAGE_REF%%/*}"
  REMAINDER="${IMAGE_REF#*/}"
  REPOSITORY="${REMAINDER%:*}"
  TAG="${REMAINDER##*:}"

  if [[ "$IMAGE_REF" != *":"* ]]; then
    echo "image must include explicit tag: $IMAGE_REF" >&2
    exit 2
  fi

  log "Parsed image login_server=${LOGIN_SERVER} repository=${REPOSITORY} tag=${TAG}"
}

get_acr_registry_name() {
  ACR_NAME="${LOGIN_SERVER%%.azurecr.io}"
  vlog "Derived ACR name ${ACR_NAME} from login server ${LOGIN_SERVER}"
}

resolve_registry_creds() {
  step "Resolving registry credentials"
  if [[ -n "${ACR_USERNAME:-}" && -n "${ACR_PASSWORD:-}" ]]; then
    CREDS="${ACR_USERNAME}:${ACR_PASSWORD}"
    log "Using explicit ACR token credentials for registry access"
  else
  log "Using Azure-managed auth to obtain ACR access token"
  TOKEN="$(az acr login \
  --name "$ACR_NAME" \
  --expose-token \
  --output tsv \
  --query accessToken)"
  CREDS="00000000-0000-0000-0000-000000000000:${TOKEN}"
  fi
}

inspect_digest() {
  step "Inspecting image metadata"
  run_cmd skopeo inspect \
    --creds "$CREDS" \
    "docker://${IMAGE_REF}" > "${SCRATCH_DIR}/inspect.json"

  DIGEST="$(jq -r '.Digest' "${SCRATCH_DIR}/inspect.json")"
  IMAGE_SIZE_BYTES="$(jq -r '.LayersData // [] | map(.Size // 0) | add // 0' "${SCRATCH_DIR}/inspect.json")"
  log "Resolved image digest=${DIGEST} approx_layer_bytes=${IMAGE_SIZE_BYTES}"
}

make_paths() {
  step "Preparing scratch paths"
  mkdir -p "$SCRATCH_DIR"
  TAR_PATH="${SCRATCH_DIR}/image.tar"
  GZ_PATH="${SCRATCH_DIR}/${BLOB_BASENAME}"
  MANIFEST_PATH="${SCRATCH_DIR}/${BLOB_BASENAME}.json"
  log "Scratch directory=${SCRATCH_DIR}"
  vlog "Tar path=${TAR_PATH}"
  vlog "Archive path=${GZ_PATH}"
  vlog "Manifest path=${MANIFEST_PATH}"
}

log_file_stats() {
  local path="$1"
  if [[ -f "$path" ]]; then
    log "File stats path=${path} bytes=$(wc -c < "$path") disk=$(du -h "$path" | awk '{print $1}')"
  fi
}

copy_and_compress() {
  rm -f "$TAR_PATH" "$GZ_PATH" "$MANIFEST_PATH"

  step "Copying image to docker archive"
  run_cmd skopeo copy \
  --src-creds "$CREDS" \
    "docker://${IMAGE_REF}" \
    "docker-archive:${TAR_PATH}:${IMAGE_REF}"
log_file_stats "$TAR_PATH"

  step "Compressing archive with pigz"
  run_cmd pigz -"${PIGZ_LEVEL}" -c "$TAR_PATH" > "$GZ_PATH"
  log_file_stats "$GZ_PATH"

  if [[ -f "$TAR_PATH" && -f "$GZ_PATH" ]]; then
    local tar_bytes gz_bytes
    tar_bytes="$(wc -c < "$TAR_PATH")"
    gz_bytes="$(wc -c < "$GZ_PATH")"
    if [[ "$tar_bytes" -gt 0 ]]; then
      log "Compression ratio original=${tar_bytes} compressed=${gz_bytes} percent=$(( gz_bytes * 100 / tar_bytes ))%"
    fi
  fi

  rm -f "$TAR_PATH"
  vlog "Removed temporary tar ${TAR_PATH}"
}

write_manifest() {
  step "Writing manifest"
  CREATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ARCHIVE_BLOB="${BLOB_CONTAINER}/${BLOB_BASENAME}"

  jq -n \
    --arg image "$IMAGE_REF" \
    --arg archiveBlob "$ARCHIVE_BLOB" \
    --arg createdAtUtc "$CREATED_AT" \
    --arg registry "$LOGIN_SERVER" \
    --arg repository "$REPOSITORY" \
    --arg tag "$TAG" \
    --arg digest "$DIGEST" \
    --argjson level "$PIGZ_LEVEL" \
    '{
      image: $image,
      archiveBlob: $archiveBlob,
      createdAtUtc: $createdAtUtc,
      mediaType: "docker-archive+gzip",
      compression: {
        format: "gzip",
        level: $level
      },
      source: {
        registry: $registry,
        repository: $repository,
        tag: $tag,
        digest: $digest
      }
    }' > "$MANIFEST_PATH"

  log_file_stats "$MANIFEST_PATH"
  vlog "Manifest contents: $(cat "$MANIFEST_PATH")"
}

upload_outputs() {
  require_env STORAGE_ACCOUNT

  step "Uploading archive blob"
  log "Uploading to account=${STORAGE_ACCOUNT} container=${BLOB_CONTAINER} name=${BLOB_BASENAME}"
  run_cmd az storage blob upload \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$BLOB_CONTAINER" \
    --name "$BLOB_BASENAME" \
    --file "$GZ_PATH" \
    --overwrite true \
    --tier Archive >/dev/null

  step "Uploading manifest blob"
  run_cmd az storage blob upload \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$BLOB_CONTAINER" \
    --name "${BLOB_BASENAME}.json" \
    --file "$MANIFEST_PATH" \
    --overwrite true >/dev/null
}

delete_claimed_message() {
  if ! queue_mode_enabled; then
    return 0
  fi

  step "Deleting processed queue message"
  log "Deleting queue message id=${MESSAGE_ID} from queue=${QUEUE_NAME}"
  run_cmd az storage message delete \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$QUEUE_ACCOUNT" \
    --queue-name "$QUEUE_NAME" \
    --id "$MESSAGE_ID" \
    --pop-receipt "$POP_RECEIPT" >/dev/null
}

cleanup() {
  step "Cleaning scratch files"
  rm -f "$TAR_PATH" "$GZ_PATH" "$MANIFEST_PATH" "${SCRATCH_DIR}/inspect.json"
}

print_startup_summary() {
  log "Startup summary"
  log "  queue_mode=$(queue_mode_enabled && echo yes || echo no)"
  log "  scratch_dir=${SCRATCH_DIR}"
  log "  pigz_level=${PIGZ_LEVEL}"
  log "  storage_auth_mode=${AZURE_STORAGE_AUTH_MODE}"
  log "  queue_account=${QUEUE_ACCOUNT:-}"
  log "  queue_name=${QUEUE_NAME:-}"
  log "  queue_visibility_timeout_seconds=${QUEUE_VISIBILITY_TIMEOUT_SECONDS}"
  log "  storage_account=${STORAGE_ACCOUNT:-}"
  log "  queue_message_file=${QUEUE_MESSAGE_FILE:-}"
  log "  azure_client_id=${AZURE_CLIENT_ID:-system-assigned}"
  log "  acr_auth_mode=$([[ -n "${ACR_USERNAME:-}" && -n "${ACR_PASSWORD:-}" ]] && echo explicit-creds || echo azure-token)"
}

main() {
  print_startup_summary
  login_azure
  read_message
  parse_image_ref
  get_acr_registry_name
  make_paths
  resolve_registry_creds
  inspect_digest
  copy_and_compress
  write_manifest
  upload_outputs
  delete_claimed_message
  cleanup
  step "Completed successfully"
  log "Finished image=${IMAGE_REF} total_runtime=$(( $(date +%s) - START_EPOCH ))s"
}

main "$@"
