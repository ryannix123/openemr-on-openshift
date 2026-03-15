#!/bin/bash
# openshift-entrypoint-jvb.sh
# Replaces s6-overlay for jitsi/jvb on CentOS Stream 10.
# Includes OpenShift arbitrary-UID NSS fix for Java getpwuid() resolution.
# Runs cont-init.d scripts, then execs JVB jar directly.
set -e

# OpenShift NSS fix: append injected UID to /tmp/passwd so Java resolves it
CURR_UID=$(id -u)
CURR_GID=$(id -g)
grep -v "^jvb:" /etc/passwd.template > /tmp/passwd 2>/dev/null || cp /etc/passwd /tmp/passwd
echo "jvb:x:${CURR_UID}:${CURR_GID}:Jitsi Videobridge:/home/jvb:/sbin/nologin" >> /tmp/passwd
export NSS_WRAPPER_PASSWD=/tmp/passwd
export NSS_WRAPPER_GROUP=/etc/group
export HOME=/home/jvb

echo "[entrypoint] Running cont-init.d config scripts..."
for script in $(ls /etc/cont-init.d/ | sort); do
    path="/etc/cont-init.d/${script}"
    if [ -x "${path}" ]; then
        echo "[entrypoint] ${script}"
        "${path}" || { echo "[entrypoint] ERROR: ${script} failed"; exit 1; }
    fi
done
echo "[entrypoint] Config complete. Starting JVB..."

# Find the JVB launch script or jar
if [ -x /usr/share/jitsi-videobridge/jvb.sh ]; then
    exec /usr/share/jitsi-videobridge/jvb.sh
elif [ -f /usr/share/jitsi-videobridge/jitsi-videobridge.jar ]; then
    exec java ${JAVA_SYS_PROPS} \
        -cp '/usr/share/jitsi-videobridge/*' \
        org.jitsi.videobridge.Main
else
    exec $(find /usr/share/jitsi-videobridge -name '*.sh' | head -1)
fi
