FROM docker.io/lldap/lldap:stable

LABEL org.opencontainers.image.title="lldap on OpenShift" \
      org.opencontainers.image.description="Lightweight LDAP authentication service for OpenShift namespaces" \
      org.opencontainers.image.source="https://github.com/ryannix123/lldap-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>"

# Replace the upstream entrypoint with a patched version that removes
# chown and gosu calls — both fail under OpenShift's restricted SCC.
# OpenShift assigns an arbitrary UID at runtime with GID 0; permissions
# on /app are pre-set here at build time so no runtime chown is needed.
USER root
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh && \
    chown -R 1000:0 /app && \
    chmod -R g=u /app

USER 1000

EXPOSE 3890 6360 17170