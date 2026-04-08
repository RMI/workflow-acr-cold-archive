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

## Queue message

```json
{
  "image": "transitionmonitordockerregistry.azurecr.io/hello-pacta:latest",
  "blobContainer": "images",
  "blobBaseName": "hello-pacta--latest.tar.gz"
}

## Required env vars
`STORAGE_ACCOUNT`
`SCRATCH_DIR` default /mnt/scratch
`PIGZ_LEVEL` default 1
`AZURE_CLIENT_ID` optional for user-assigned identity
