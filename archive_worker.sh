#!/usr/bin/env bash
set -Eeuo pipefail

: "${QUEUE_MESSAGE_FILE:=/tmp/message.json}"
: "${SCRATCH_DIR:=/mnt/scratch}"
: "${PIGZ_LEVEL:=1}"
: "${AZURE_STORAGE_AUTH_MODE:=login}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 127
  }
}

require_cmd az
require_cmd skopeo
require_cmd pigz
require_cmd jq
require_cmd date

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

read_message() {
  IMAGE_REF="$(jq -r '.image' "$QUEUE_MESSAGE_FILE")"
  BLOB_CONTAINER="$(jq -r '.blobContainer' "$QUEUE_MESSAGE_FILE")"
  BLOB_BASENAME="$(jq -r '.blobBaseName' "$QUEUE_MESSAGE_FILE")"

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

cleanup() {
  rm -f "$TAR_PATH" "$GZ_PATH" "$MANIFEST_PATH" "${SCRATCH_DIR}/inspect.json"
}

main() {
  mkdir -p "$SCRATCH_DIR"

  login_azure
  read_message
  parse_image_ref
  get_acr_registry_name
  TOKEN="$(get_acr_token)"
  inspect_digest
  make_paths
  copy_and_compress
  write_manifest
  upload_outputs
  cleanup

  log "Completed ${IMAGE_REF}"
}

main "$@"
