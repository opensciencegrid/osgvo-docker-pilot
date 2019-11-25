#!/bin/bash

if [ `id -u` = 0 ]; then
    echo "Please do not run me as root!"
    exit 1
fi

# validation
if [ "x$TOKEN" = "x" ]; then
    echo "Please specify TOKEN as an environment variable" 1>&2
    exit 1
fi
if [ "x$GLIDEIN_Site" = "x" ]; then
    echo "Please specify GLIDEIN_Site as an environment variable" 1>&2
    exit 1
fi
if [ "x$GLIDEIN_ResourceName" = "x" ]; then
    echo "Please specify GLIDEIN_ResourceName as an environment variable" 1>&2
    exit 1
fi

# token auth
mkdir -p ~/.condor/tokens.d
echo "$TOKEN" >~/.condor/tokens.d/flock.opensciencegrid.org
chmod 600 ~/.condor/tokens.d/flock.opensciencegrid.org

# extra HTCondor config
# pick one ccb port and stick with it for the lifetime of the glidein
CCB_PORT=$(python -S -c "import random; print random.randrange(9700,9899)")
LOCAL_DIR="/tmp/osgvo-pilot-$RANDOM"
NETWORK_HOSTNAME="$(echo $GLIDEIN_ResourceName | sed 's/_/-/g')-$(hostname)"
cat >~/.condor/user_config <<EOF
# unique local dir
LOCAL_DIR = $LOCAL_DIR

# random, but static port for the lifetime of the glidein
CCB_ADDRESS = \$(CONDOR_HOST):$CCB_PORT

# a more descriptive machine name
NETWORK_HOSTNAME = $NETWORK_HOSTNAME

GLIDEIN_Site = "$GLIDEIN_Site"
GLIDEIN_ResourceName = "$GLIDEIN_ResourceName"
OSG_SQUID_LOCATION = "$OSG_SQUID_LOCATION"

EOF

mkdir -p `condor_config_val EXECUTE`
mkdir -p `condor_config_val LOG`
mkdir -p `condor_config_val LOCK`
mkdir -p `condor_config_val RUN`
mkdir -p `condor_config_val SPOOL`
mkdir -p `condor_config_val SEC_CREDENTIAL_DIRECTORY`
chmod 600 `condor_config_val SEC_CREDENTIAL_DIRECTORY`

tail -F `condor_config_val LOG`/MasterLog `condor_config_val LOG`/StartLog &

condor_master -f

rm -rf $LOCAL_DIR

