FROM ruby:3.4.7-alpine@sha256:d279decff1a40535597120bf9546b6c01a5d00298b9a87628f28cf0efd07b02c

ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/icefoganalytics/local-development-gateway" \
      org.opencontainers.image.title="Local Development Gateway Database Router" \
      org.opencontainers.image.version="0.4.0" \
      org.opencontainers.image.revision="$REVISION"

WORKDIR /app
COPY lib/ ./lib/
COPY bin/database-router ./bin/database-router
CMD ["ruby", "-I/app/lib", "/app/bin/database-router"]
