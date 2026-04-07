#!/usr/bin/env bash
# Patched entrypoint for OpenShift compatibility.
# Removes chown/gosu calls that fail under restricted SCC —
# OpenShift assigns the UID at runtime and handles PVC ownership.
set -euo pipefail

CONFIG_FILE=/data/lldap_config.toml

if [[ ( ! -w "/data" ) ]] || [[ ( ! -d "/data" ) ]]; then
  echo "[entrypoint] The /data folder doesn't exist or cannot be written to. Make sure to mount"
  echo "  a volume or folder to /data to persist data across restarts, and that the current user can"
  echo "  write to it."
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[entrypoint] Copying the default config to $CONFIG_FILE"
  echo "[entrypoint] Edit this file to configure LLDAP."
  cp /app/lldap_config.docker_template.toml $CONFIG_FILE
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "[entrypoint] Config file is not readable. Check the permissions"
  exit 1
fi

echo "> Starting lldap.."
exec /app/lldap "$@"
