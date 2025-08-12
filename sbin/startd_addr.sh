#!/bin/bash

CONDOR_LOGDIR=/pilot/log

function condor_version_in_range {
    local minimum maximum
    minimum=${1:?minimum not provided to condor_version_in_range}
    maximum=${2:-99.99.99}

    local condor_version
    condor_version=$(condor_version | awk '/CondorVersion/ {print $2}')
    python3 -c '
import sys
minimum = [int(x) for x in sys.argv[1].split(".")]
maximum = [int(x) for x in sys.argv[2].split(".")]
version = [int(x) for x in sys.argv[3].split(".")]
sys.exit(0 if minimum <= version <= maximum else 1)
' "$minimum" "$maximum" "$condor_version"
}


# Condor 23.8 has a bug where condor_status -direct for startd ads still
# attempts to contact the collector.  Hopefully it will be fixed in 23.10;
# in the meantime, use -pool instead of -direct (which is a hack).
local direct
if condor_version_in_range 23.8.0 23.10.0; then
    direct="-pool"
else
    direct="-direct"
fi

# wait for the master to come up
master_timeout=60
SECONDS=0
while [ ! -s "$CONDOR_LOGDIR/MasterLog" ]; do
    if [ $SECONDS -gt $master_timeout ]; then
        echo "Timeout: condor_master did not start within $master_timeout seconds." >&2
        exit 1
    fi
    sleep 5
done

# now wait for the startd
startd_addr=$(condor_who -log $CONDOR_LOGDIR \
                         -wait:600 'IsReady && STARTD_State =?= "Ready"' \
                         -dae \
                | awk '/^Startd/ {print $6}')
ret=$?

if [ $ret -ne 0 || -z "$startd_addr" ]; then
    echo "Unable to determine startd addr" >&2
    exit 1
fi

echo "$startd_addr"
exit 0




