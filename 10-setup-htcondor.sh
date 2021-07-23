#!/bin/bash

set -xe

if [ `id -u` = 0 ]; then
    echo "Please do not run me as root!"
    exit 1
fi

# validation
if [[ ! -e /etc/condor/tokens.d/flock.opensciencegrid.org ]] &&
   [[ ! -e /etc/condor/tokens-orig.d/flock.opensciencegrid.org ]] &&
   [[ ! $TOKEN ]]; then
    { echo "Please provide /etc/condor/tokens-orig.d/flock.opensciencegrid.org"
      echo "via volume mount."
    } 1>&2
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
if [ "x$GLIDEIN_Start_Extra" = "x" ]; then
    export GLIDEIN_Start_Extra="True"
fi
if [ "x$ACCEPT_JOBS_FOR_HOURS" = "x" ]; then
    export ACCEPT_JOBS_FOR_HOURS=336
fi
if [ "x$ANNEX_NAME" = "x" ]; then
    export ANNEX_NAME="$GLIDEIN_ResourceName@$GLIDEIN_Site"
fi

LOCAL_DIR=$(mktemp -d /pilot/osgvo-pilot-XXXXXX)
mkdir -p "$LOCAL_DIR"/condor/tokens.d
mkdir -p "$LOCAL_DIR"/condor/passwords.d
chmod 700 "$LOCAL_DIR"/condor/passwords.d

shopt -s nullglob
tokens=( /etc/condor/tokens-orig.d/* )
passwords=( /etc/condor/passwords-orig.d/* )
shopt -u nullglob

if [[ $tokens ]]; then
  cp /etc/condor/tokens-orig.d/* "$LOCAL_DIR"/condor/tokens.d/
  chmod 600 "$LOCAL_DIR"/condor/tokens.d/*
fi
if [[ $passwords ]]; then
  cp /etc/condor/passwords-orig.d/* "$LOCAL_DIR"/condor/passwords.d/
  chmod 600 "$LOCAL_DIR"/condor/passwords.d/*
fi

if [[ $TOKEN ]]; then
  # token auth
  echo "$TOKEN" >"$LOCAL_DIR"/condor/tokens.d/flock.opensciencegrid.org
  chmod 600 "$LOCAL_DIR"/condor/tokens.d/flock.opensciencegrid.org
fi

# glorious hack
export _CONDOR_SEC_PASSWORD_FILE=$LOCAL_DIR/condor/tokens.d/flock.opensciencegrid.org
export _CONDOR_SEC_PASSWORD_DIRECTORY=$LOCAL_DIR/condor/passwords.d

# extra HTCondor config
# pick one ccb port and stick with it for the lifetime of the glidein
CCB_PORT=$(python -S -c "import random; print random.randrange(9700,9899)")
NETWORK_HOSTNAME="$(echo $GLIDEIN_ResourceName | sed 's/_/-/g')-$(hostname)"

# to avoid collisions when ~ is shared, write the config file to /tmp
export PILOT_CONFIG_FILE=$LOCAL_DIR/condor_config.pilot

cat >$PILOT_CONFIG_FILE <<EOF
# unique local dir
LOCAL_DIR = $LOCAL_DIR

SEC_TOKEN_DIRECTORY = $LOCAL_DIR/condor/tokens.d

# random, but static port for the lifetime of the glidein
CCB_ADDRESS = \$(CONDOR_HOST):$CCB_PORT

# a more descriptive machine name
NETWORK_HOSTNAME = $NETWORK_HOSTNAME

# additional start expression requirements - this will be &&ed to the base one
START_EXTRA = $GLIDEIN_Start_Extra

GLIDEIN_Site = "$GLIDEIN_Site"
GLIDEIN_ResourceName = "$GLIDEIN_ResourceName"
OSG_SQUID_LOCATION = "$OSG_SQUID_LOCATION"

ACCEPT_JOBS_FOR_HOURS = $ACCEPT_JOBS_FOR_HOURS

AnnexName = "$ANNEX_NAME"

STARTD_ATTRS = \$(STARTD_ATTRS) AnnexName ACCEPT_JOBS_FOR_HOURS
MASTER_ATTRS = \$(MASTER_ATTRS) AnnexName ACCEPT_JOBS_FOR_HOURS
EOF

# ensure HTCondor knows about our squid
if [ "x$OSG_SQUID_LOCATION" != "x" ]; then
    export http_proxy="$OSG_SQUID_LOCATION"
fi

cat >$LOCAL_DIR/user-job-wrapper.sh <<EOF
#!/bin/bash
set -e
export GLIDEIN_Site="$GLIDEIN_Site"
export GLIDEIN_ResourceName="$GLIDEIN_ResourceName"
export OSG_SITE_NAME="$GLIDEIN_ResourceName"
export OSG_SQUID_LOCATION="$OSG_SQUID_LOCATION"
exec /usr/sbin/osgvo-user-job-wrapper "\$@"
EOF
chmod 755 $LOCAL_DIR/user-job-wrapper.sh
export _CONDOR_USER_JOB_WRAPPER=$LOCAL_DIR/user-job-wrapper.sh

mkdir -p `condor_config_val EXECUTE`
mkdir -p `condor_config_val LOG`
mkdir -p `condor_config_val LOCK`
mkdir -p `condor_config_val RUN`
mkdir -p `condor_config_val SPOOL`
mkdir -p `condor_config_val SEC_CREDENTIAL_DIRECTORY`
chmod 600 `condor_config_val SEC_CREDENTIAL_DIRECTORY`

echo
echo "Will use the following token(s):"
condor_token_list
echo
