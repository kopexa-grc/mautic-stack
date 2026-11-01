# syntax=docker/dockerfile:1
#
# Mautic on the hardened kopexa php-apache base image.
#
#   runtime: no shell, no package manager, uid 65532, port 8080,
#            read-only root filesystem (writable: /tmp, /app/var, /app/config,
#            /app/docroot/media/{files,images})
#
ARG BASE_IMAGE=ghcr.io/kopexa-grc/php-apache
ARG PHP_VERSION=8.4

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${PHP_VERSION}-dev AS build

# renovate: datasource=packagist depName=mautic/recommended-project
ARG MAUTIC_VERSION=7.2.2

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    COMPOSER_PROCESS_TIMEOUT=1800 \
    COMPOSER_MEMORY_LIMIT=-1 \
    PHP_MEMORY_LIMIT=-1

WORKDIR /build
# ext-imap: removed from PHP 8.4 core and built on the unmaintained c-client
# library; it is only needed for IMAP bounce processing (use provider
# webhooks instead). See docs/limitations.md.
RUN composer create-project --no-progress --no-dev \
      --ignore-platform-req=ext-imap \
      "mautic/recommended-project:${MAUTIC_VERSION}" mautic

WORKDIR /build/mautic
# Writable directories are moved out of the tree at the end: COPY --chown only
# applies to directories it creates, not to ones that already exist.
RUN npm ci --no-audit --no-fund \
 && php bin/console mautic:assets:generate \
 && find node_modules -mindepth 1 -maxdepth 1 \
      -not \( -name jquery -o -name vimeo-froogaloop2 \) -exec rm -rf {} + \
 && rm -rf var/* vendor/twbs/bootstrap-sass/test \
 && mkdir -p config var/cache var/logs var/tmp var/spool \
             docroot/media/files docroot/media/images \
 && mkdir -p /build/writable/media \
 && mv config var /build/writable/ \
 && mv docroot/media/files docroot/media/images /build/writable/media/

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${PHP_VERSION}

ARG MAUTIC_VERSION=7.2.2
LABEL org.opencontainers.image.title="mautic" \
      org.opencontainers.image.description="Mautic ${MAUTIC_VERSION} on a hardened, non-root php-apache base" \
      org.opencontainers.image.source="https://github.com/kopexa-grc/mautic-stack" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${MAUTIC_VERSION}" \
      org.opencontainers.image.vendor="Kopexa"

# Code is owned by root and read-only for the runtime user …
COPY --from=build --chown=0:0 /build/mautic /app
# … except the directories Mautic writes to.
COPY --from=build --chown=65532:65532 /build/writable/config /app/config
COPY --from=build --chown=65532:65532 /build/writable/var /app/var
COPY --from=build --chown=65532:65532 /build/writable/media/files /app/docroot/media/files
COPY --from=build --chown=65532:65532 /build/writable/media/images /app/docroot/media/images
COPY rootfs/ /

ENV APACHE_DOCUMENT_ROOT=/app/docroot \
    APACHE_ALLOW_OVERRIDE=All \
    APACHE_DOCROOT_OPTIONS="-Indexes +FollowSymLinks" \
    PHP_MEMORY_LIMIT=512M \
    PHP_MAX_EXECUTION_TIME=300 \
    PHP_UPLOAD_MAX_FILESIZE=64M \
    PHP_POST_MAX_SIZE=64M \
    PHP_OPCACHE_MEMORY=256

USER 65532:65532
WORKDIR /app
EXPOSE 8080
VOLUME ["/app/config", "/app/docroot/media/files", "/app/docroot/media/images"]
ENTRYPOINT ["/usr/bin/php", "/usr/local/lib/mautic/entrypoint.php"]
CMD ["web"]
