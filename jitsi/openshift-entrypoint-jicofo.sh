#!/bin/bash
# openshift-entrypoint-jicofo.sh
# Replaces s6-overlay for jitsi/jicofo on CentOS Stream 10.
# Includes OpenShift arbitrary-UID NSS fix for Java getpwuid() resolution.
# Runs cont-init.d scripts, then execs jicofo jar directly.
set -e

# OpenShift NSS fix: append injected UID to /tmp/passwd so Java resolves it
CURR_UID=$(id -u)
CURR_GID=$(id -g)
grep -v "^jicofo:" /etc/passwd.template > /tmp/passwd 2>/dev/null || cp /etc/passwd /tmp/passwd
echo "jicofo:x:${CURR_UID}:${CURR_GID}:Jicofo:/home/jicofo:/sbin/nologin" >> /tmp/passwd
export NSS_WRAPPER_PASSWD=/tmp/passwd
export NSS_WRAPPER_GROUP=/etc/group
export HOME=/home/jicofo

echo "[entrypoint] Running cont-init.d config scripts..."
for script in $(ls /etc/cont-init.d/ | sort); do
    path="/etc/cont-init.d/${script}"
    if [ -x "${path}" ]; then
        echo "[entrypoint] ${script}"
        "${path}" || { echo "[entrypoint] ERROR: ${script} failed"; exit 1; }
    fi
done
echo "[entrypoint] Config complete. Starting jicofo..."

# Find the jicofo launch script or jar
if [ -x /usr/share/jicofo/jicofo.sh ]; then
    exec /usr/share/jicofo/jicofo.sh
elif [ -f /usr/share/jicofo/jicofo.jar ]; then
    exec java ${JAVA_SYS_PROPS} \
        -cp '/usr/share/jicofo/*' \
        org.jitsi.jicofo.Main
else
    # Fallback: find any launch script
    exec $(find /usr/share/jicofo -name '*.sh' | head -1)
fi
