FROM scratch

ARG TARGETARCH

LABEL org.opencontainers.image.title="zq" \
      org.opencontainers.image.description="A drop-in jq replacement — 31x faster JSON processing" \
      org.opencontainers.image.url="https://github.com/Enriquefft/zq" \
      org.opencontainers.image.source="https://github.com/Enriquefft/zq" \
      org.opencontainers.image.licenses="MIT"

COPY --chmod=755 zq-${TARGETARCH} /usr/local/bin/zq

USER 65534:65534

ENTRYPOINT ["/usr/local/bin/zq"]
