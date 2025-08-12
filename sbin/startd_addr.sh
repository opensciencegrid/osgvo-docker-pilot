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


# wait for the master to come up
master_timeout=300
SECONDS=0
while [ ! -s "$CONDOR_LOGDIR/MasterLog" ]; do
    if [ $SECONDS -gt $master_timeout ]; then
        echo "Timeout: condor_master did not start within $master_timeout seconds." >&2
        exit 1
    fi
    sleep 5
done

# wait for the startd to log something
startd_timeout=120
SECONDS=0
while [ ! -s "$CONDOR_LOGDIR/StartLog" ]; do
    if [ $SECONDS -gt $startd_timeout ]; then
        echo "Timeout: condor_startd did not start within $startd_timeout seconds." >&2
        exit 1
    fi
    sleep 5
done

# now wait for the startd to be registered
startd_addr=$(condor_who -log $CONDOR_LOGDIR \
                         -wait:300 'IsReady && STARTD_State =?= "Ready"' \
                         -dae \
                | awk '/^Startd/ {print $4}')
ret=$?

if [[ $ret -ne 0 || -z "$startd_addr" ]]; then
    echo "Unable to determine startd addr" >&2
    exit 1
fi

echo "$startd_addr"
exit 0




