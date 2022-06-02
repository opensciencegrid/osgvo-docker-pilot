#!/bin/bash

set -xe

if [ `id -u` = 0 ]; then
    echo "Please do not run me as root!"
    exit 1
fi


#
# Taken from creation/web_base/condor_startup.sh in the gwms
# Set a variable read from a file
#
pstr='"'
set_var() {
    var_name=$1
    var_type=$2
    var_def=$3
    var_condor=$4
    var_req=$5
    var_exportcondor=$6
    var_user=$7

    if [ -z "$var_name" ]; then
        # empty line
        return 0
    fi

    var_val=`grep "^$var_name " $glidein_config | awk '{if (NF>1) ind=length($1)+1; v=substr($0, ind); print substr(v, index(v, $2))}'`
    if [ -z "$var_val" ]; then
        if [ "$var_req" == "Y" ]; then
            # needed var, exit with error
            #echo "Cannot extract $var_name from '$config_file'" 1>&2
            STR="Cannot extract $var_name from '$glidein_config'"
            "$error_gen" -error "condor_startup.sh" "Config" "$STR" "MissingAttribute" "$var_name"
            exit 1
        elif [ "$var_def" == "-" ]; then
            # no default, do not set
            return 0
        else
            eval var_val=$var_def
        fi
    fi
    if [ "$var_condor" == "+" ]; then
        var_condor=$var_name
    fi
    if [ "$var_type" == "S" ]; then
        var_val_str="${pstr}${var_val}${pstr}"
    else
        var_val_str="$var_val"
    fi

    # insert into condor_config
    echo "$var_condor=$var_val_str" >> $PILOT_CONFIG_FILE

    if [ "$var_exportcondor" == "Y" ]; then
        # register var_condor for export
        if [ -z "$glidein_variables" ]; then
           glidein_variables="$var_condor"
        else
           glidein_variables="$glidein_variables,$var_condor"
        fi
    fi

    if [ "$var_user" != "-" ]; then
        # - means do not export
        if [ "$var_user" == "+" ]; then
            var_user=$var_name
        elif [ "$var_user" == "@" ]; then
            var_user=$var_condor
        fi

        condor_env_entry="$var_user=$var_val"
        condor_env_entry=`echo "$condor_env_entry" | awk "{gsub(/\"/,\"\\\\\"\\\\\"\"); print}"`
        condor_env_entry=`echo "$condor_env_entry" | awk "{gsub(/'/,\"''\"); print}"`
        if [ -z "$job_env" ]; then
           job_env="'$condor_env_entry'"
        else
           job_env="$job_env '$condor_env_entry'"
        fi
    fi

    # define it for future use
    eval "$var_name='$var_val'"
    return 0
}


is_true () {
    case "${1:-0}" in
        # y(es), t(rue), 1, on; uppercase or lowercase
        [yY]*|[tT]*|1|[Oo][Nn]) return 0 ;;
        *) return 1 ;;
    esac
}

random_range () {
    LOW=$1
    HIGH=$2
    python3 -S -c "import random; print(random.randrange($LOW,$HIGH+1))"
}

# validation
set +x  # avoid printing $TOKEN to the console
if [[ ! -e /etc/condor/tokens.d/flock.opensciencegrid.org ]] &&
   [[ ! -e /etc/condor/tokens-orig.d/flock.opensciencegrid.org ]] &&
   [[ ! $TOKEN ]]; then
    { echo "Please provide /etc/condor/tokens-orig.d/flock.opensciencegrid.org"
      echo "via volume mount."
    } 1>&2
    exit 1
fi
set -x
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
if [ "x$ACCEPT_IDLE_MINUTES" = "x" ]; then
    export ACCEPT_IDLE_MINUTES=30
fi
if [ "x$ANNEX_NAME" = "x" ]; then
    export ANNEX_NAME="$GLIDEIN_ResourceName@$GLIDEIN_Site"
fi
if [ "x$ALLOW_CPUJOB_ON_GPUSLOT" = "x" ]; then
    export ALLOW_CPUJOB_ON_GPUSLOT="0"
fi

# make sure LOCAL_DIR is exported here - it is used
# later in advertisment/condorcron scripts
export LOCAL_DIR=$(mktemp -d /pilot/osgvo-pilot-XXXXXX)
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

set +x  # avoid printing $TOKEN to the console
if [[ $TOKEN ]]; then
  # token auth
  echo >&2 'Using TOKEN from environment'
  cat >"$LOCAL_DIR"/condor/tokens.d/flock.opensciencegrid.org <<<"$TOKEN"
  chmod 600 "$LOCAL_DIR"/condor/tokens.d/flock.opensciencegrid.org
  TOKEN='<used>'  # done with this var; reset it so an env dump won't print it
fi
set -x

# glorious hack
export _CONDOR_SEC_PASSWORD_FILE=$LOCAL_DIR/condor/tokens.d/flock.opensciencegrid.org
export _CONDOR_SEC_PASSWORD_DIRECTORY=$LOCAL_DIR/condor/passwords.d

# There's at least one site that makes `/pilot` a persistent volume; we want to remove
# the cruft from the prior run.
rm -rf /pilot/{log,rsyslog}

# Setup syslog server
mkdir -p /pilot/{log,log/log,rsyslog,rsyslog/pid,rsyslog/workdir,rsyslog/conf}
touch /pilot/log/{Master,Start,Proc,SharedPort,XferStats,log/Starter}Log /pilot/log/StarterLog{,.testing}

# Set some reasonable defaults for the token registry.
if [[ "x$REGISTRY_HOST" != "x" ]]; then
    REGISTRY_HOSTNAME="$REGISTRY_HOST"
elif [[ "$SYSLOG_HOST" == "syslog.osgdev.chtc.io" ]]; then
    REGISTRY_HOSTNAME="os-registry.osgdev.chtc.io"
else
    REGISTRY_HOSTNAME="os-registry.opensciencegrid.org"
fi

if ! nslookup "$SYSLOG_HOST" >/dev/null; then
    echo >&2 "*** SYSLOG_HOST $SYSLOG_HOST not found"
    SYSLOG_HOST=""
else
    # If hostcert generation fails, then we'll just skip the whole syslog thing.
    generate-hostcert "$_CONDOR_SEC_PASSWORD_FILE" "$REGISTRY_HOSTNAME" || SYSLOG_HOST=""
fi

if [[ "x$SYSLOG_HOST" != "x" ]]; then

    for NAME in Condor Glidein Supervisord
    do

    cat >> /pilot/rsyslog/conf/forward.conf << EOF
ruleset(name="forward${NAME}") {
  action(type="omfwd"
    queue.filename="fwdAll"
    queue.maxdiskspace="100m"
    queue.saveonshutdown="off"
    queue.type="LinkedList"
    action.resumeRetryCount="10"
    StreamDriverMode="1"
    StreamDriver="gtls"
    StreamDriverAuthMode="x509/name"
    Target="$SYSLOG_HOST" Port="6514" Protocol="tcp"
    template="${NAME}_SyslogProtocol23Format"
  )
}
EOF

    done

else

    cat > /pilot/rsyslog/conf/forward.conf << EOF
ruleset(name="forwardCondor") {}
ruleset(name="forwardGlidein") {}
ruleset(name="forwardSupervisord") {}
EOF

fi


######################
# POOL CONFIGURATION #
######################

# Default to the production OSPool
POOL=${POOL:=prod-ospool}

case ${POOL} in
    itb-ospool)
        default_cm1=cm-1.ospool-itb.osg-htc.org
        default_cm2=cm-2.ospool-itb.osg-htc.org
        default_syslog_host=syslog.osgdev.chtc.io
        ;;
    prod-ospool)
        default_cm1=cm-1.ospool.osg-htc.org
        default_cm2=cm-2.ospool.osg-htc.org
        default_syslog_host=syslog.osg.chtc.io
        ;;
    prod-path-facility)
        default_cm1=cm-1.facility.path-cc.io
        default_cm2=cm-2.facility.path-cc.io
        default_syslog_host=syslog.osg.chtc.io
        ;;
    *)
        echo "Unknown pool $POOL" >&2
        exit 1
        ;;
esac

# Allow users to override the pool configuration
if [[ -n $CONDOR_HOST ]]; then
    # if the user sets $CONDOR_HOST, we can't assume the POOL
    # so we unset it here to avoid confusion
    POOL=
else
    CONDOR_HOST=$default_cm1,$default_cm2
fi

# Configure remote peer if applicable
SYSLOG_HOST=${SYSLOG_HOST:-$default_syslog_host}

if [[ -n $CCB_RANGE_LOW && -n $CCB_RANGE_HIGH ]]; then
    # Choose a random CCB port if the user gives us a port range
    # e.g., cm.school.edu:10576
    CCB_SUFFIX=$(random_range "$CCB_RANGE_LOW" "$CCB_RANGE_HIGH")
elif [[ $POOL =~ (itb|prod)-ospool ]]; then
    # Choose a random OSPool collector for CCB
    # e.g., cm-1.ospool.osg-htc.org:9619?sock=collector3
    CCB_SUFFIX="9619?sock=collector$(random_range 1 5)"
elif [[ $POOL =~ (itb|prod)-path-facility ]]; then
    # Choose a random PATh facility collector for CCB
    # cm-1.facility.path-cc.io:9618?sock=collector9623
    CCB_SUFFIX="9618?sock=collector962$(random_range 0 4)"
fi

# Append the CCB suffix to each host in CONDOR_HOST, e.g.
# "cm.school.edu:10576", or
# "cm-1.ospool.osg-htc.org:9619?sock=collector6,cm-2.ospool.osg-htc.org:9619?sock=collector6"
if [[ -n $CCB_RANGE_LOW && -n $CCB_RANGE_HIGH ]] ||
       [[ $POOL =~ (itb|prod)-ospool ]] ||
       [[ $POOL == 'prod-path-facility' ]]; then
    CCB_ADDRESS=$(python3 -Sc "import re; \
print(','.join([cm + ':$CCB_SUFFIX' \
for cm in re.split(r'[\s,]+', '$CONDOR_HOST')]))")
fi

# https://whogohost.com/host/knowledgebase/308/Valid-Domain-Name-Characters.html rules
hostname_length=$(hostname | wc -c)
maxlen=$(( 63 - $hostname_length ))
if [[ $maxlen -lt 1 ]]; then
    sanitized_resourcename=
else
    sanitized_resourcename=$(
    <<<"$GLIDEIN_ResourceName" tr -cs 'a-zA-Z0-9.-' '[-*]' \
                             | sed -e 's|^[.-]*||' \
                                   -e 's|[.-]*$||' \
                             | cut -c 1-$maxlen \
    )
fi
NETWORK_HOSTNAME="${sanitized_resourcename}-$(hostname)"

# to avoid collisions when ~ is shared, write the config file to /tmp
export PILOT_CONFIG_FILE=$LOCAL_DIR/condor_config.pilot

cat >$PILOT_CONFIG_FILE <<EOF
CONDOR_HOST = ${CONDOR_HOST}

# unique local dir
LOCAL_DIR = $LOCAL_DIR

# mimic gwms so gwms scripts will work
EXECUTE = $LOCAL_DIR/execute

SEC_TOKEN_DIRECTORY = $LOCAL_DIR/condor/tokens.d

CCB_ADDRESS = $CCB_ADDRESS

# a more descriptive machine name
NETWORK_HOSTNAME = $NETWORK_HOSTNAME

# additional start expression requirements - this will be &&ed to the base one
START_EXTRA = $GLIDEIN_Start_Extra

GLIDEIN_Site = "$GLIDEIN_Site"
GLIDEIN_ResourceName = "$GLIDEIN_ResourceName"
OSG_SQUID_LOCATION = "$OSG_SQUID_LOCATION"

ACCEPT_JOBS_FOR_HOURS = $ACCEPT_JOBS_FOR_HOURS
ACCEPT_IDLE_MINUTES = $ACCEPT_IDLE_MINUTES

AnnexName = "$ANNEX_NAME"

STARTD_ATTRS = \$(STARTD_ATTRS) AnnexName ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES
MASTER_ATTRS = \$(MASTER_ATTRS) AnnexName ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES

# policy
use policy : Hold_If_Memory_Exceeded

STARTD_CRON_JOBLIST = $(STARTD_CRON_JOBLIST) base userenv

STARTD_CRON_base_EXECUTABLE = /usr/sbin/osgvo-advertise-base
STARTD_CRON_base_PERIOD = 4m
STARTD_CRON_base_MODE = periodic
STARTD_CRON_base_RECONFIG = true
STARTD_CRON_base_KILL = true
STARTD_CRON_base_ARGS =

STARTD_CRON_userenv_EXECUTABLE = $LOCAL_DIR/main/singularity_wrapper.sh
STARTD_CRON_userenv_PERIOD = 4m
STARTD_CRON_userenv_MODE = periodic
STARTD_CRON_userenv_RECONFIG = true
STARTD_CRON_userenv_KILL = true
STARTD_CRON_userenv_ARGS = /usr/sbin/osgvo-advertise-userenv $LOCAL_DIR/glidein_config main

EOF

if [[ $NUM_CPUS ]]; then
    echo "NUM_CPUS = $NUM_CPUS" >> "$PILOT_CONFIG_FILE"
fi
if [[ $MEMORY ]]; then
    echo "MEMORY = $MEMORY" >> "$PILOT_CONFIG_FILE"
fi

# ensure HTCondor knows about our squid
if [ "x$OSG_SQUID_LOCATION" != "x" ]; then
    export http_proxy="$OSG_SQUID_LOCATION"
fi

# some admins prefer to reserve gpu slots for gpu jobs, others
# want to run cpu jobs if there are no gpu jobs available
if [[ $ALLOW_CPUJOB_ON_GPUSLOT = "1" ]]; then
    echo "CPUJOB_ON_GPUSLOT = True" >> "$PILOT_CONFIG_FILE"
else
    echo "CPUJOB_ON_GPUSLOT = ifThenElse(MY.TotalGPUs > 0 && MY.GPUs > 0, TARGET.RequestGPUs > 0, True)" >> "$PILOT_CONFIG_FILE"
fi

cat >$LOCAL_DIR/user-job-wrapper.sh <<EOF
#!/bin/bash
set -e
export GLIDEIN_Site="$GLIDEIN_Site"
export GLIDEIN_ResourceName="$GLIDEIN_ResourceName"
export OSG_SITE_NAME="$GLIDEIN_ResourceName"
export OSG_SQUID_LOCATION="$OSG_SQUID_LOCATION"
export GWMS_DIR="$LOCAL_DIR"
exec $LOCAL_DIR/condor_job_wrapper.sh "\$@"
EOF
chmod 755 $LOCAL_DIR/user-job-wrapper.sh
echo "USER_JOB_WRAPPER = $LOCAL_DIR/user-job-wrapper.sh" >>$PILOT_CONFIG_FILE

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

cd $LOCAL_DIR

# gwms files in the correct location
cp -a /gwms/. $LOCAL_DIR/
cp -a /usr/sbin/osgvo-singularity-wrapper condor_job_wrapper.sh

# minimum env to get glideinwms scripts to work
export glidein_config=$LOCAL_DIR/glidein_config
export condor_vars_file=$LOCAL_DIR/main/condor_vars.lst

# set some defaults for the glideinwms based scripts
if [[ -z $OSG_DEFAULT_CONTAINER_DISTRIBUTION ]]; then
    OSG_DEFAULT_CONTAINER_DISTRIBUTION="30%__opensciencegrid/osgvo-el7:latest 70%__opensciencegrid/osgvo-el8:latest"
fi
cat >$glidein_config <<EOF
ADD_CONFIG_LINE_SOURCE $PWD/add_config_line.source
CONDOR_VARS_FILE $condor_vars_file
ERROR_GEN_PATH $PWD/error_gen.sh
GLIDEIN_SINGULARITY_REQUIRE OPTIONAL
GLIDEIN_Singularity_Use PREFERRED
OSG_DEFAULT_CONTAINER_DISTRIBUTION $OSG_DEFAULT_CONTAINER_DISTRIBUTION
SINGULARITY_IMAGE_RESTRICTIONS None
GWMS_SINGULARITY_PATH /usr/bin/singularity
GLIDEIN_WORK_DIR $PWD/main
GLIDECLIENT_WORK_DIR $PWD/client
GLIDECLIENT_GROUP_WORK_DIR $PWD/client_group_main
EOF
touch $condor_vars_file

# test and add the stash plugin
export STASH_PLUGIN_PATH=/usr/libexec/condor/stash_plugin
if timeout 60s "$STASH_PLUGIN_PATH" -d /osgconnect/public/dweitzel/stashcp/test.file /tmp/stashcp-test.file >/dev/null 2>/tmp/stashcp-debug.txt; then
    rm -f /tmp/stashcp-test.file
    echo "FILETRANSFER_PLUGINS = \$(FILETRANSFER_PLUGINS),$STASH_PLUGIN_PATH" >> "$PILOT_CONFIG_FILE"
else
    cat >&2 /tmp/stashcp-debug.txt
    echo >&2 "stash_plugin test failed; 'stash' filetransfer plugin unavailable"
fi
rm -f /tmp/stashcp-debug.txt

unset SINGULARITY_BIND
export GLIDEIN_SINGULARITY_BINARY_OVERRIDE=/usr/bin/singularity
/usr/sbin/osgvo-default-image $glidein_config
./main/singularity_setup.sh $glidein_config
./client_group_main/singularity-extras $glidein_config

# run the osgvo userenv advertise script
cp /usr/sbin/osgvo-advertise-userenv .
$PWD/main/singularity_wrapper.sh ./osgvo-advertise-userenv glidein_config osgvo-docker-pilot

# last step - interpret the condor_vars
set +x
while read line
do
    set_var $line
done <$condor_vars_file
set -x

cat >>$PILOT_CONFIG_FILE <<EOF
MASTER_ATTRS = \$(MASTER_ATTRS), $glidein_variables
STARTD_ATTRS = \$(STARTD_ATTRS), $glidein_variables
STARTER_JOB_ENVIRONMENT = "$job_env"
EOF


