#!/usr/bin/env bash
set -Eeuo pipefail

# Discover all ACR repos/tags and prepare queue messages for the cold-archive worker.
#
# Requirements:
#   - az CLI logged in
#   - jq
#
# Example dry run:
#   ./prepare_acr_queue_messages.sh \
#     --acr-name transitionmonitordockerregistry \
#     --storage-account pactadockerimages \
#     --queue-name docker-transfer \
#     --blob-container images \
#     --output-file messages.jsonl
#
# Example enqueue:
#   ./prepare_acr_queue_messages.sh \
#     --acr-name transitionmonitordockerregistry \
#     --storage-account pactadockerimages \
#     --queue-name docker-transfer \
#     --blob-container images \
#     --enqueue
#
# Optional ACR token auth:
#   export ACR_USERNAME='...'
#   export ACR_PASSWORD='...'
#
# Optional filters:
#   --repo-prefix hello-
#   --exclude-tag latest
#   --include-untagged false

VERBOSE="${VERBOSE:-1}"
ENQUEUE=0
OUTPUT_FILE=""
BLOB_CONTAINER="images"
INCLUDE_UNTAGGED=0
REPO_PREFIX=""
EXCLUDE_TAGS=()

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

vlog() {
  if [[ "${VERBOSE}" == "1" ]]; then
    log "$*"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

usage() {
  cat <<'EOF'
Usage:
  prepare_acr_queue_messages.sh
    --acr-name NAME
    --storage-account NAME
    --queue-name NAME
    [--blob-container NAME]
    [--output-file PATH]
    [--enqueue]
    [--repo-prefix PREFIX]
    [--exclude-tag TAG]...
    [--include-untagged true|false]

Notes:
  - Without --enqueue, this writes JSONL output only.
  - With --enqueue, this pushes each message to Azure Queue Storage.
  - Queue message format:
      {"image":"<login-server>/<repo>:<tag>","blobContainer":"images","blobBaseName":"repo--tag.tar.gz"}
EOF
}

# Parse args
ACR_NAME=""
STORAGE_ACCOUNT=""
QUEUE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --acr-name)
      ACR_NAME="${2:-}"; shift 2 ;;
    --storage-account)
      STORAGE_ACCOUNT="${2:-}"; shift 2 ;;
    --queue-name)
      QUEUE_NAME="${2:-}"; shift 2 ;;
    --blob-container)
      BLOB_CONTAINER="${2:-}"; shift 2 ;;
    --output-file)
      OUTPUT_FILE="${2:-}"; shift 2 ;;
    --enqueue)
      ENQUEUE=1; shift ;;
    --repo-prefix)
      REPO_PREFIX="${2:-}"; shift 2 ;;
    --exclude-tag)
      EXCLUDE_TAGS+=("${2:-}"); shift 2 ;;
    --include-untagged)
      case "${2:-}" in
        true|TRUE|1) INCLUDE_UNTAGGED=1 ;;
        false|FALSE|0) INCLUDE_UNTAGGED=0 ;;
        *) die "invalid value for --include-untagged: ${2:-}" ;;
      esac
      shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[[ -n "${ACR_NAME}" ]] || die "--acr-name is required"
[[ -n "${STORAGE_ACCOUNT}" ]] || die "--storage-account is required"
[[ -n "${QUEUE_NAME}" ]] || die "--queue-name is required"

require_cmd az
require_cmd jq

if [[ -n "${OUTPUT_FILE}" ]]; then
  : > "${OUTPUT_FILE}"
  vlog "Initialized output file ${OUTPUT_FILE}"
fi

LOGIN_SERVER="${ACR_NAME}.azurecr.io"

acr_args=(--name "${ACR_NAME}")
# Azure CLI supports --username/--password for az acr repository commands. :contentReference[oaicite:1]{index=1}
if [[ -n "${ACR_USERNAME:-}" && -n "${ACR_PASSWORD:-}" ]]; then
  acr_args+=(--username "${ACR_USERNAME}" --password "${ACR_PASSWORD}")
  log "Using explicit ACR credentials for repository enumeration"
else
  log "Using current az login context for repository enumeration"
fi

sanitize_blob_basename() {
  local repo="$1"
  local tag="$2"

  # Keep slash out of blob basename and use -- instead of :
  local safe_repo safe_tag
  safe_repo="${repo//\//__}"
  safe_tag="${tag//:/--}"

  printf '%s--%s.tar.gz' "${safe_repo}" "${safe_tag}"
}

should_exclude_tag() {
  local tag="$1"
  local excluded
  for excluded in "${EXCLUDE_TAGS[@]:-}"; do
    if [[ "${tag}" == "${excluded}" ]]; then
      return 0
    fi
  done
  return 1
}

enqueue_message() {
  local json="$1"

  # az storage message put adds a message to the queue. The command group supports
  # auth parameters including --auth-mode. :contentReference[oaicite:2]{index=2}
  az storage message put \
    --auth-mode login \
    --account-name "${STORAGE_ACCOUNT}" \
    --queue-name "${QUEUE_NAME}" \
    --content "${json}" \
    --time-to-live -1 \
    --output none
}

log "Listing repositories from ${ACR_NAME}"
repos_json="$(az acr repository list "${acr_args[@]}" --output json)"
repo_count="$(jq 'length' <<<"${repos_json}")"
log "Found ${repo_count} repositories"

count_messages=0
count_repos=0

while IFS= read -r repo; do
  [[ -n "${repo}" ]] || continue

  if [[ -n "${REPO_PREFIX}" && "${repo}" != "${REPO_PREFIX}"* ]]; then
    vlog "Skipping repo ${repo} due to prefix filter"
    continue
  fi

  count_repos=$((count_repos + 1))
  log "Enumerating tags for repo ${repo}"

  # show-tags is the documented command for tags; --detail is supported if you want richer output. :contentReference[oaicite:3]{index=3}
  tags_json="$(az acr repository show-tags "${acr_args[@]}" --repository "${repo}" --output json)"
  tag_count="$(jq 'length' <<<"${tags_json}")"
  vlog "Repo ${repo} returned ${tag_count} tags"

  if [[ "${tag_count}" -eq 0 && "${INCLUDE_UNTAGGED}" -eq 1 ]]; then
    vlog "Repo ${repo} has no tags; skipping because worker expects explicit tag"
  fi

  while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue

    if should_exclude_tag "${tag}"; then
      vlog "Skipping ${repo}:${tag} due to exclude filter"
      continue
    fi

    image_ref="${LOGIN_SERVER}/${repo}:${tag}"
    blob_base_name="$(sanitize_blob_basename "${repo}" "${tag}")"

    message_json="$(
      jq -cn \
        --arg image "${image_ref}" \
        --arg blobContainer "${BLOB_CONTAINER}" \
        --arg blobBaseName "${blob_base_name}" \
        '{
          image: $image,
          blobContainer: $blobContainer,
          blobBaseName: $blobBaseName
        }'
    )"

    if [[ -n "${OUTPUT_FILE}" ]]; then
      printf '%s\n' "${message_json}" >> "${OUTPUT_FILE}"
    fi

    if [[ "${ENQUEUE}" -eq 1 ]]; then
      log "Enqueueing ${image_ref} -> ${BLOB_CONTAINER}/${blob_base_name}"
      enqueue_message "${message_json}"
    else
      vlog "Prepared ${image_ref} -> ${BLOB_CONTAINER}/${blob_base_name}"
    fi

    count_messages=$((count_messages + 1))
  done < <(jq -r '.[]' <<<"${tags_json}")

done < <(jq -r '.[]' <<<"${repos_json}")

log "Completed repository scan"
log "Processed repositories: ${count_repos}"
log "Prepared messages: ${count_messages}"

if [[ -n "${OUTPUT_FILE}" ]]; then
  log "Wrote JSONL messages to ${OUTPUT_FILE}"
fi
