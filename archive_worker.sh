#!/usr/bin/env bash
set -Eeuo pipefail

: "${SCRATCH_DIR:=/mnt/scratch}"
: "${PIGZ_LEVEL:=1}"
: "${AZURE_STORAGE_AUTH_MODE:=login}"
: "${QUEUE_VISIBILITY_TIMEOUT_SECONDS:=3600}"
: "${QUEUE_MESSAGE_FILE:=}"

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

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

login_azure() {
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    log "Logging into Azure with user-assigned managed identity"
    az login --identity --username "$AZURE_CLIENT_ID" >/dev/null
  else
    log "Logging into Azure with system-assigned managed identity"
    az login --identity >/dev/null
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
  RECEIPT_HANDLE=""
  MESSAGE_ID="local-file"
  MESSAGE_JSON="$(cat "$QUEUE_MESSAGE_FILE")"
}

read_message_from_queue() {
  require_env QUEUE_ACCOUNT
  require_env QUEUE_NAME

  log "Claiming one message from queue ${QUEUE_NAME} with ${QUEUE_VISIBILITY_TIMEOUT_SECONDS}s visibility timeout"

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
}

parse_image_ref() {
  LOGIN_SERVER="${IMAGE_REF%%/*}"
  REMAINDER="${IMAGE_REF#*/}"
  REPOSITORY="${REMAINDER%:*}"
  TAG="${REMAINDER##*:}"

  if [[ "$IMAGE_REF" != *":"* ]]; then
    echo "image must include explicit tag: $IMAGE_REF" >&2
    exit 2
  fi
}

get_acr_registry_name() {
  ACR_NAME="${LOGIN_SERVER%%.azurecr.io}"
}

get_acr_token() {
  az acr login \
    --name "$ACR_NAME" \
    --expose-token \
    --output tsv \
    --query accessToken
}

inspect_digest() {
  skopeo inspect \
    --creds "00000000-0000-0000-0000-000000000000:${TOKEN}" \
    "docker://${IMAGE_REF}" > "${SCRATCH_DIR}/inspect.json"

  DIGEST="$(jq -r '.Digest' "${SCRATCH_DIR}/inspect.json")"
}

make_paths() {
  mkdir -p "$SCRATCH_DIR"
  TAR_PATH="${SCRATCH_DIR}/image.tar"
  GZ_PATH="${SCRATCH_DIR}/${BLOB_BASENAME}"
  MANIFEST_PATH="${SCRATCH_DIR}/${BLOB_BASENAME}.json"
}

copy_and_compress() {
  rm -f "$TAR_PATH" "$GZ_PATH" "$MANIFEST_PATH"

  log "Copying ${IMAGE_REF} to docker archive"
  skopeo copy \
    --src-creds "00000000-0000-0000-0000-000000000000:${TOKEN}" \
    "docker://${IMAGE_REF}" \
    "docker-archive:${TAR_PATH}:${IMAGE_REF}"

  log "Compressing archive"
  pigz -"${PIGZ_LEVEL}" -c "$TAR_PATH" > "$GZ_PATH"
  rm -f "$TAR_PATH"
}

write_manifest() {
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
}

upload_outputs() {
  require_env STORAGE_ACCOUNT

  log "Uploading archive blob"
  az storage blob upload \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$BLOB_CONTAINER" \
    --name "$BLOB_BASENAME" \
    --file "$GZ_PATH" \
    --overwrite true \
    --tier Archive

  log "Uploading manifest blob"
  az storage blob upload \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$BLOB_CONTAINER" \
    --name "${BLOB_BASENAME}.json" \
    --file "$MANIFEST_PATH" \
    --overwrite true
}

delete_claimed_message() {
  if ! queue_mode_enabled; then
    return 0
  fi

  log "Deleting processed queue message ${MESSAGE_ID}"
  az storage message delete \
    --auth-mode "$AZURE_STORAGE_AUTH_MODE" \
    --account-name "$QUEUE_ACCOUNT" \
    --queue-name "$QUEUE_NAME" \
    --id "$MESSAGE_ID" \
    --pop-receipt "$POP_RECEIPT" >/dev/null
}

cleanup() {
  rm -f "$TAR_PATH" "$GZ_PATH" "$MANIFEST_PATH" "${SCRATCH_DIR}/inspect.json"
}

main() {
  login_azure
  read_message
  parse_image_ref
  get_acr_registry_name
  TOKEN="$(get_acr_token)"
  make_paths
  inspect_digest
  copy_and_compress
  write_manifest
  upload_outputs
  delete_claimed_message
  cleanup

  log "Completed ${IMAGE_REF}"
}

main "$@"
