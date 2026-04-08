# ACR Cold Archive Worker

Archives private Azure Container Registry images into `docker load` compatible `.tar.gz` blobs and uploads them to Azure Blob Storage Archive tier.

## Flow

1. Read one queue message
2. Authenticate with managed identity
3. Get ACR token with `az acr login --expose-token`
4. Export image to docker archive tar with `skopeo`
5. Compress with `pigz`
6. Upload `.tar.gz`
7. Upload sidecar manifest `.json`

## Queue Message Format

Required roles:

- ACR: `AcrPull` (or equivalent)
- Storage:
  - Queue: `Storage Queue Data Contributor`
  - Blob: `Storage Blob Data Contributor`

---

## Running Locally (File Mode)

For testing without a queue:

```bash
export STORAGE_ACCOUNT=...
export QUEUE_MESSAGE_FILE=examples/message.json

./archive_worker.sh
```

---

## ACA Job Configuration (High-Level)

- **Trigger**: Azure Queue (KEDA scaler)
- **Parallelism**: 1 per execution
- **Max executions**: controls concurrency
- **Container args**: none (script is entrypoint)
- **Volume**: Azure Files mounted at `/mnt/scratch`
- **Identity**: system or user-assigned

---

## Behavior Notes

### Message Claiming

- Worker claims 1 message using visibility timeout (default: 3600s)
- Message is deleted **only after successful upload**
- If worker crashes, message reappears

### Long-Running Jobs

- Ensure visibility timeout > worst-case runtime
- Future improvement: visibility renewal (heartbeat)

### Idempotency

- Blob names are deterministic
- Reprocessing will overwrite existing blobs

---

## Restore Workflow

```bash
docker load < hello-pacta--latest.tar.gz
```

---

## Design Decisions

- Uses `skopeo` to avoid Docker daemon
- Uses `docker-archive` format for compatibility
- Uses `pigz` for parallel compression
- Uses queue-per-image for clean scaling + retries

---

## Future Improvements

- Visibility timeout renewal for very large images
- Multi-arch manifest capture
- Retry/backoff tuning
- Metrics/logging integration

---

## Build

```bash
docker build -t acr-cold-archive:dev .
```

---

## Summary

This worker implements a **queue-driven, idempotent, daemonless archival pipeline** for ACR images, optimized for:

- reliability (visibility timeout + delete-on-success)
- compatibility (`docker load`)
- scalability (ACA Jobs + queue depth)
- simplicity (single-image per execution)
