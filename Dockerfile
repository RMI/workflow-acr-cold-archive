FROM mcr.microsoft.com/azure-cli:2.70.0

RUN tdnf install -y \
        skopeo \
        pigz \
        jq \
        awk \
    && tdnf clean all

WORKDIR /app

COPY archive_worker.sh /app/archive_worker.sh

RUN chmod +x /app/archive_worker.sh

ENTRYPOINT ["/app/archive_worker.sh"]
