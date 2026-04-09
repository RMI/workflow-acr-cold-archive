# ACR Cold Archive Worker

Archives private Azure Container Registry (ACR) images into `docker load`-compatible `.tar.gz` files and uploads them to Azure Blob Storage Archive tier.

This project is designed to run as an **Azure Container Apps Job** triggered by **Azure Queue Storage** backlog. Each execution processes exactly one image.

## Assumptions

This repo assumes all of the following already exist:

* An **Azure Container Apps managed environment** in the target resource group.
* A **storage account** that will be used for:

  * the queue of work items,
  * the blob container that stores archives and manifests,
  * the Azure Files share used as scratch space.
* An **Azure Queue Storage queue** for work items.
* An **Azure Blob container** for archive output.
* An **Azure Files share** mounted into the ACA Job as scratch storage.
* A source **Azure Container Registry** containing the images to archive.
* A deployable worker image published to a registry that ACA can pull from.

This worker also assumes:

* Queue messages are JSON with explicit destination naming.
* Each message includes a fully qualified image reference with an explicit tag.
* The output artifact must remain `docker load` compatible.
* Scratch storage is required because the current implementation writes a temporary uncompressed `docker-archive` tar before gzip compression.

## Current Design

For each queue message, the worker:

1. Logs into Azure using managed identity.
2. Claims exactly one queue message using a visibility timeout.
3. Reads the source image reference and output blob name from the message.
4. Authenticates to ACR using `az acr login --expose-token`.
5. Inspects the image with `skopeo` to capture digest metadata.
6. Copies the image to `docker-archive` format.
7. Compresses the archive with `pigz`.
8. Uploads the `.tar.gz` to Blob Storage.
9. Uploads a sidecar manifest JSON.
10. Deletes the queue message only after successful uploads.

If the worker crashes before deleting the queue message, Azure Queue Storage makes the message visible again after the visibility timeout expires.

## Queue Message Format

```json
{
  "image": "transitionmonitordockerregistry.azurecr.io/hello-pacta:latest",
  "blobContainer": "images",
  "blobBaseName": "hello-pacta--latest.tar.gz"
}
```

Notes:

* `image` must include an explicit tag.
* `blobBaseName` intentionally uses `--` instead of `:`.
* This message produces:

  * `images/hello-pacta--latest.tar.gz`
  * `images/hello-pacta--latest.tar.gz.json`

## Manifest Format

Example sidecar manifest:

```json
{
  "image": "transitionmonitordockerregistry.azurecr.io/hello-pacta:latest",
  "archiveBlob": "images/hello-pacta--latest.tar.gz",
  "createdAtUtc": "2026-04-08T12:34:56Z",
  "mediaType": "docker-archive+gzip",
  "compression": {
    "format": "gzip",
    "level": 1
  },
  "source": {
    "registry": "transitionmonitordockerregistry.azurecr.io",
    "repository": "hello-pacta",
    "tag": "latest",
    "digest": "sha256:..."
  }
}
```

## Required Environment Variables

### Core

```bash
STORAGE_ACCOUNT=<storage-account-name>
SCRATCH_DIR=/mnt/scratch
PIGZ_LEVEL=1
AZURE_STORAGE_AUTH_MODE=login
```

### Queue Mode

```bash
QUEUE_ACCOUNT=<storage-account-name>
QUEUE_NAME=<queue-name>
QUEUE_VISIBILITY_TIMEOUT_SECONDS=3600
```

### Optional

```bash
AZURE_CLIENT_ID=<user-assigned-managed-identity-client-id>
```

If `AZURE_CLIENT_ID` is omitted, the worker uses the job's system-assigned managed identity.

## Azure Permissions and Authentication

This project supports two authentication models for ACR:

### Option 1: Managed Identity (recommended default)

* Assign the ACA Job identity:

  * `AcrPull` on the source ACR
* The worker uses:

  ```bash
  az acr login --expose-token
  ```

### Option 2: ACR Token (your current setup)

If you are using an ACR **token + password**, you do not need RBAC on the registry.

Instead, pass credentials to the worker and use them with `skopeo`.

Required environment variables:

```bash
ACR_USERNAME=<token-name>
ACR_PASSWORD=<token-password>
```

And the worker should use:

```bash
--src-creds "$ACR_USERNAME:$ACR_PASSWORD"
```

Notes:

* This bypasses `az acr login --expose-token`
* Useful when you want scoped access without granting RBAC
* Recommended for tightly controlled, read-only access

### Storage Access (always via Managed Identity)

Regardless of ACR auth method, storage access still uses managed identity:

Required roles on the storage account:

* `Storage Queue Data Contributor`
* `Storage Blob Data Contributor`

---

## Important Limitation: Azure Files Mounts

Azure Container Apps supports mounting Azure Files into the environment, but **the storage registration currently requires a storage account key**. Microsoft explicitly states that Container Apps **does not support identity-based access to Azure file shares** for this mount path. If key access is disabled on your storage account, the Azure Files mount cannot be configured the normal ACA way.

That means your current storage settings create a blocker for the scratch mount approach.

## Startup Instructions

### 1. Build and publish the worker image

Example:

```bash
docker build -t ghcr.io/rmi/workflow-acr-cold-archive:pr-2 .
docker push ghcr.io/rmi/workflow-acr-cold-archive:pr-2
```

### 2. Create the storage resources if they do not already exist

You need:

* queue: `docker-transfer`
* blob container: `images`
* Azure Files share: `transfer-scratch`

### 3. Deploy the ACA Job

The deployment template needs these values:

* `containerAppsEnvironmentResourceId`
* `image`
* `storageAccountName`
* `queueName`
* `fileShareName`
* image registry settings if the worker image is private

Your current values are:

* environment: `pacta-test`
* image: `ghcr.io/rmi/workflow-acr-cold-archive:pr-2`
* storage account: `pactadockerimages`
* queue: `docker-transfer`
* fileshare: `transfer-scratch`

### 4. Assign managed identity permissions

After the ACA Job exists, grant its identity access to:

* source ACR: `AcrPull`
* storage account: `Storage Queue Data Contributor`
* storage account: `Storage Blob Data Contributor`

### 5. Enqueue a test message

Example:

```json
{
  "image": "transitionmonitordockerregistry.azurecr.io/hello-pacta:latest",
  "blobContainer": "images",
  "blobBaseName": "hello-pacta--latest.tar.gz"
}
```

### 6. Watch job executions and logs

Confirm that:

* one execution claims one message,
* the worker uploads `.tar.gz`,
* the worker uploads `.json`,
* the queue message is deleted only after success.

## Local Testing

Local file-mode testing is still supported with:

```bash
export STORAGE_ACCOUNT=<storage-account-name>
export QUEUE_MESSAGE_FILE=examples/message.json
./archive_worker.sh
```

But cloud-first testing is the preferred path for this project.

## Restore Workflow

```bash
docker load < hello-pacta--latest.tar.gz
```

## Recommended Identity Choice

For this job, start with a **system-assigned managed identity** on the ACA Job.

Reasons:

* It is the fastest path to get running.
* ACA Jobs support system-assigned and user-assigned identities.
* The same identity can be used for queue scaling and for the worker's Azure authentication.
* You do not need to create a separate identity resource unless you want to reuse the identity across multiple jobs or apps.

Use a user-assigned identity later only if you want shared lifecycle or reuse across multiple resources.

## Known Next Step

Because your storage account currently has **key access disabled**, you will need to resolve scratch storage before the ACA deployment can mount Azure Files. The simplest options are:

1. use a different storage account for the Azure Files scratch share where key-based mount is allowed, or
2. use another execution platform for the scratch-heavy step.

Given ACA's current storage mount behavior, option 1 is the cleanest path if you want to keep ACA Jobs.

## Deploy

```bash
az deployment group create \
  --resource-group RMI-SP-PACTA-WEU-PAT-DEV \
  --template-file aca-job-deploy.bicep \
  --parameters \
    containerAppsEnvironmentResourceId='/subscriptions/feef729b-4584-44af-a0f9-4827075512f9/resourceGroups/RMI-SP-PACTA-WEU-PAT-DEV/providers/Microsoft.App/managedEnvironments/pacta-test' \
    image='ghcr.io/rmi/workflow-acr-cold-archive:pr-2' \
    useSystemAssignedIdentity=false \
    userAssignedIdentityResourceId='/subscriptions/feef729b-4584-44af-a0f9-4827075512f9/resourceGroups/RMI-SP-PACTA-WEU-PAT-DEV/providers/Microsoft.ManagedIdentity/userAssignedIdentities/docker-transfer' \
    storageAccountName='pactadockerimages' \
    fileShareName='docker-transfer-scratch' \
    storageAccountKey="$STORAGE_KEY" \
    queueName='docker-transfer'
```

### Queueing

```bash
./prepare_acr_queue_messages.sh \
  --acr-name transitionmonitordockerregistry \
  --storage-account pactadockerimages \
  --queue-name docker-transfer \
  --blob-container images \
  --output-file messages.jsonl
```
