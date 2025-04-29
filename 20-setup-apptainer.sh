# Configure apptainer based on environment variables
# Currently, just set the registry mirror
# Note that this only works in apptainer >=1.3, <1.4

if [ `id -u` = 0 ]; then
    echo "Please do not run me as root!"
    exit 1
fi

APPTAINER_CONF_PATH="/etc/containers/registries.conf.d/registry-mirror.conf"

if [ -n "$APPTAINER_REGISTRY_MIRROR" ]; then
    cat << EOF >> $APPTAINER_CONF_PATH 
[[registry]]
location="docker.io"
[[registry.mirror]]
location="$APPTAINER_REGISTRY_MIRROR"
EOF
fi
