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
    elif [[ ! $var_name =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        printf "Skipping invalid variable name '%s'\n" "$var_name" 1>&2
        if [[ $var_req == Y ]]; then
            # probably never happens but just in case...
            printf "Variable named '%s' was required; exiting\n" "$var_name" 1>&2
            exit 1
        fi
        return 0
    fi

    var_name_len=${#var_name}
    var_val=$(grep "^${var_name} " $glidein_config | tail -n 1 | cut -c $((var_name_len + 2))- )
    if [ -z "$var_val" ]; then
        if [ "$var_req" == "Y" ]; then
            # needed var, exit with error
            printf "Cannot extract required variable %s from glidein config '%s'\n" "$var_name" "$glidein_config" 1>&2
            exit 1
        elif [ "$var_def" == "-" ]; then
            # no default, do not set
            return 0
        else
            # Adding extra quoting here caused startd disconnection issues for some reason
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

    # define it for future use; make sure it's properly quoted
    local statement="$(printf "%q=%q" "$var_name" "$var_val")"
    echo "setting var: $statement"
    eval "$statement"
    return 0
}

# explicitly true:
# y(es), t(rue), 1, on; uppercase or lowercase
is_true () {
    case "${1^^}" in         # bash-ism to uppercase the var
        Y|YES) return 0 ;;
        T|TRUE) return 0 ;;
        ON) return 0 ;;
        1) return 0 ;;
    esac
    return 1
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
if [ "x$OSG_PROJECT_NAME" != "x" ]; then
    export OSG_PROJECT_RESTRICTION="ProjectName == \"$OSG_PROJECT_NAME\""
fi
if [ "x$GLIDEIN_Start_Extra" != "x" ]; then
    if (echo "$GLIDEIN_Start_Extra" | grep -i ProjectName) >/dev/null 2>&1; then
        echo "Using GLIDEIN_Start_Extra for limiting on ProjectName is discouraged. Please use OSG_PROJECT_NAME to restrict the pilot." 1>&2
    fi
else
    export GLIDEIN_Start_Extra="True"
fi
if ! [[ "$ACCEPT_JOBS_FOR_HOURS" =~ ^[0-9]+$ ]]; then
    echo "ACCEPT_JOBS_FOR_HOURS has to be a positive integer" 1>&2
    exit 1
else
    if [ $ACCEPT_JOBS_FOR_HOURS -le 0 ]; then
        echo "ACCEPT_JOBS_FOR_HOURS has to be a positive integer" 1>&2
        exit 1
    fi
fi
if ! [[ "$RETIREMENT_HOURS" =~ ^[0-9]+$ ]]; then
    echo "RETIREMENT_HOURS has to be a positive integer" 1>&2
    exit 1
else
    if [ $RETIREMENT_HOURS -le 0 ]; then
        echo "RETIREMENT_HOURS has to be a positive integer" 1>&2
        exit 1
    fi
fi
if [ "x$GARBAGE_COLLECTION" = "x" ]; then
    # garbage collection is opt-out
    export GARBAGE_COLLECTION=1
fi

#
# Set pool defaults
#

# Default to the production OSPool unless $ITB is set
if is_true "$ITB"; then
    if [[ $POOL == ospool ]]; then
        POOL=itb-ospool
    fi
    glidein_group=itb
    glidein_group_dir=client_group_itb
    script_exec_prefix=/usr/sbin/itb-
    script_lib_prefix=/gwms/client_group_itb/itb-
else
    if [[ $POOL == ospool ]]; then
        POOL=prod-ospool
    fi
    glidein_group=main
    glidein_group_dir=client_group_main
    script_exec_prefix=/usr/sbin/
    script_lib_prefix=/gwms/client_group_main/
fi


itb_sites_start_clause=''
case ${POOL} in
    itb-ospool)
        default_cm1=cm-1.ospool-itb.osg-htc.org
        default_cm2=cm-2.ospool-itb.osg-htc.org
        default_ccb1=ccb-1.ospool-itb.osg-htc.org
        default_ccb2=ccb-2.ospool-itb.osg-htc.org
        default_syslog_host=syslog.osgdev.chtc.io
        GLIDECLIENT_Group=itb-container
        itb_sites_start_clause=' && (TARGET.ITB_Sites =?= True)'
        ;;
    prod-ospool)
        default_cm1=cm-1.ospool.osg-htc.org
        default_cm2=cm-2.ospool.osg-htc.org
        default_ccb1=ccb-1.ospool.osg-htc.org
        default_ccb2=ccb-2.ospool.osg-htc.org
        default_syslog_host=syslog.osg.chtc.io
        GLIDECLIENT_Group=main-container
        itb_sites_start_clause=' && (TARGET.ITB_Sites =!= True)'
        ;;
    prod-path-facility)
        default_cm1=cm-1.facility.path-cc.io
        default_cm2=
        default_syslog_host=syslog.osg.chtc.io
        GLIDECLIENT_Group=path-container
        ;;
    dev-path-facility)
        default_cm1=htcondor-cm-path.osgdev.chtc.io
        default_cm2=htcondor-cm-path.osg-dev.river.chtc.io
        default_syslog_host=syslog.osgdev.chtc.io
        GLIDECLIENT_Group=path-container
        ;;
    *.*)
        ENABLE_REMOTE_SYSLOG=false
        default_cm1=$POOL
        default_cm2=
        ;;
    '')
        echo "POOL is blank" >&2
        exit 1
        ;;
    *)
        echo "Unknown pool $POOL" >&2
        exit 1
        ;;
esac

# make sure LOCAL_DIR is exported here - it is used
# later in advertisment/condorcron scripts
export LOCAL_DIR=$(mktemp -d /pilot/osgvo-pilot-XXXXXX)
if [[ ! $LOCAL_DIR || ! -d $LOCAL_DIR ]]; then
    echo "Creating LOCAL_DIR under /pilot failed" >&2
    exit 1
fi

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

# Pick server to forward syslogs to
SYSLOG_HOST=${SYSLOG_HOST:-$default_syslog_host}

# Set some reasonable defaults for the token registry.
if [[ "x$REGISTRY_HOST" != "x" ]]; then
    REGISTRY_HOSTNAME="$REGISTRY_HOST"
elif [[ "$SYSLOG_HOST" == "syslog.osgdev.chtc.io" ]]; then
    REGISTRY_HOSTNAME="os-registry.osgdev.chtc.io"
else
    REGISTRY_HOSTNAME="os-registry.opensciencegrid.org"
fi

if ! is_true "$ENABLE_REMOTE_SYSLOG"; then
    SYSLOG_HOST=
    REGISTRY_HOSTNAME=
    REGISTRY_HOST=
else
    if ! nslookup "$SYSLOG_HOST" >/dev/null; then
        echo >&2 "*** SYSLOG_HOST $SYSLOG_HOST not found"
        SYSLOG_HOST=""
    else
        # If hostcert generation fails, then we'll just skip the whole syslog thing.
        /usr/local/sbin/generate-hostcert "$_CONDOR_SEC_PASSWORD_FILE" "$REGISTRY_HOSTNAME" || SYSLOG_HOST=""
    fi
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


# Allow users to override the pool configuration
if [[ -n $CONDOR_HOST ]]; then
    # if the user sets $CONDOR_HOST, we can't assume the POOL
    # so we unset it here to avoid confusion
    POOL=
else
    CONDOR_HOST=$default_cm1
    if [[ $default_cm2 ]]; then
        CONDOR_HOST=${CONDOR_HOST},${default_cm2}
    fi
fi

# default COLLECTOR_HOST
COLLECTOR_HOST=$CONDOR_HOST

if [[ -n $CCB_RANGE_LOW && -n $CCB_RANGE_HIGH ]]; then
    # Choose a random CCB port if the user gives us a port range
    # e.g., cm.school.edu:10576
    CCB_SUFFIX=$(random_range "$CCB_RANGE_LOW" "$CCB_RANGE_HIGH")
elif [[ $POOL =~ (itb|prod)-ospool ]]; then
    # Choose a random OSPool collector for CCB and CM
    # e.g., ccb-1.ospool.osg-htc.org?sock=collector3
    CCB_SUFFIX="?sock=collector$(random_range 1 10)"
elif [[ $POOL =~ (dev|prod)-path-facility ]]; then
    # Choose a random PATh facility collector for CCB
    # cm-1.facility.path-cc.io:9618?sock=collector9623
    CCB_SUFFIX="9618?sock=collector962$(random_range 0 4)"
fi

if [[ $POOL =~ (itb|prod)-ospool ]]; then
    # OSPools - specific CCB servers. Append the CCB suffix to each ccb host
    COLLECTOR_HOST=$default_cm1$CCB_SUFFIX,$default_cm2$CCB_SUFFIX
    CCB_ADDRESS=$default_ccb1$CCB_SUFFIX,$default_ccb2$CCB_SUFFIX
elif [[ -n $CCB_RANGE_LOW && -n $CCB_RANGE_HIGH ]] ||
         [[ $POOL =~ (dev|prod)-path-facility ]]; then
    # PATh facilty, or anything else: Append the CCB suffix to each host in CONDOR_HOST, e.g.
    # "cm.school.edu:10576", or
    # "cm-1.ospool.osg-htc.org:9619?sock=collector6,cm-2.ospool.osg-htc.org:9619?sock=collector6"
    CCB_ADDRESS=$(python3 -Sc "import re; \
print(','.join([cm + ':$CCB_SUFFIX' \
for cm in re.split(r'[\s,]+', '$CONDOR_HOST')]))")
fi


# max length of a domain name is 255; max length of an individual component is 63
sanitized_resourcename=$(
<<<"$GLIDEIN_ResourceName" tr -cs 'a-zA-Z0-9.-' '[-*]' \
                         | sed -e 's|^[.-]*||' \
                               -e 's|[.-]*$||' \
                         | cut -c 1-63 \
)
if is_true "$GLIDEIN_RANDOMIZE_NAME"; then
    random_component=$(python3 -Sc "import secrets; print(secrets.token_hex(5))")  # 10 hex characters
    NETWORK_HOSTNAME="${sanitized_resourcename}.${random_component}.$(hostname)"
else
    NETWORK_HOSTNAME="${sanitized_resourcename}.$(hostname)"
fi

osgvo_advertise_base=${script_exec_prefix}osgvo-advertise-base
osgvo_advertise_userenv=${script_exec_prefix}osgvo-advertise-userenv
osgvo_additional_htcondor_config=${script_exec_prefix}osgvo-additional-htcondor-config
osgvo_singularity_wrapper=${script_exec_prefix}osgvo-singularity-wrapper
simple_job_wrapper=${script_exec_prefix}simple-job-wrapper
prepare_hook=${script_lib_prefix}prepare-hook
default_image_executable=${script_exec_prefix}osgvo-default-image
singularity_extras_lib=${script_lib_prefix}singularity-extras
ospool_lib=${script_lib_prefix}ospool-lib
pelican_setup=${script_lib_prefix}pelican-setup

cat <<EOF
This pilot will accept new jobs for $ACCEPT_JOBS_FOR_HOURS hours, and
then let running jobs finish for $RETIREMENT_HOURS hours. To control
this behavior, you may set the ACCEPT_JOBS_FOR_HOURS and
RETIREMENT_HOURS environment variables.
EOF

# use GLIDEIN_ToRetire - this is for aligning with GWMS glideins
NOW=$(date +'%s')
GLIDEIN_ToRetire=$(($NOW + $ACCEPT_JOBS_FOR_HOURS * 60 * 60))

# Give the instance 24 hours to finish up before exiting
GLIDEIN_ToDie=$(($GLIDEIN_ToRetire + $RETIREMENT_HOURS * 60 * 60))

# local dir to mimic gmws - expected by some of our glidein scripts
mkdir -p $LOCAL_DIR/condor_config.d

# to avoid collisions when ~ is shared, write the config file to /tmp
export PILOT_CONFIG_FILE=$LOCAL_DIR/condor_config.pilot

cat >$PILOT_CONFIG_FILE <<EOF
CONDOR_HOST = ${CONDOR_HOST}

# unique local dir
LOCAL_DIR = $LOCAL_DIR

# mimic gwms so gwms scripts will work
EXECUTE = $LOCAL_DIR/execute
LOCAL_CONFIG_DIR = $LOCAL_DIR/condor_config.d

SEC_TOKEN_DIRECTORY = $LOCAL_DIR/condor/tokens.d

COLLECTOR_HOST = $COLLECTOR_HOST
${CCB_ADDRESS:+"CCB_ADDRESS = $CCB_ADDRESS"}

# Let the OS pick a random shared port port so we don't collide with anything else
SHARED_PORT_PORT = 0

# a more descriptive machine name
NETWORK_HOSTNAME = $NETWORK_HOSTNAME

# restrict which project this pilot can serve
OSG_PROJECT_RESTRICTION = $OSG_PROJECT_RESTRICTION

# additional start expression requirements - this will be &&ed to the base one
START_EXTRA = $GLIDEIN_Start_Extra $itb_sites_start_clause

GLIDEIN_Site = "$GLIDEIN_Site"
GLIDEIN_ResourceName = "$GLIDEIN_ResourceName"
GLIDECLIENT_Group = "$GLIDECLIENT_Group"
OSG_SQUID_LOCATION = "$OSG_SQUID_LOCATION"

ACCEPT_JOBS_FOR_HOURS = $ACCEPT_JOBS_FOR_HOURS
ACCEPT_IDLE_MINUTES = $ACCEPT_IDLE_MINUTES

GLIDEIN_ToRetire = $GLIDEIN_ToRetire
GLIDEIN_ToDie = $GLIDEIN_ToDie

STARTD_ATTRS = \$(STARTD_ATTRS) ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES GLIDEIN_ToRetire GLIDEIN_ToDie
MASTER_ATTRS = \$(MASTER_ATTRS) ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES GLIDEIN_ToRetire GLIDEIN_ToDie

STARTD_CRON_JOBLIST = \$(STARTD_CRON_JOBLIST) base userenv
STARTD_CRON_base_EXECUTABLE = ${osgvo_advertise_base}
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
STARTD_CRON_userenv_ARGS = ${osgvo_advertise_userenv} $LOCAL_DIR/glidein_config main

EOF

if [[ $NUM_CPUS ]]; then
    echo "NUM_CPUS = $NUM_CPUS" >> "$PILOT_CONFIG_FILE"
fi
if [[ $MEMORY ]]; then
    echo "MEMORY = $MEMORY" >> "$PILOT_CONFIG_FILE"
fi
if is_true "$ITB"; then
    echo "Is_ITB_Site = True" >> "$PILOT_CONFIG_FILE"
fi

# ensure HTCondor knows about our squid
if [ "x$OSG_SQUID_LOCATION" != "x" ]; then
    export http_proxy="$OSG_SQUID_LOCATION"
fi

cat >$LOCAL_DIR/user-job-wrapper.sh <<EOF
#!/bin/bash
set -e
export GLIDEIN_Site="$GLIDEIN_Site"
export GLIDEIN_ResourceName="$GLIDEIN_ResourceName"
export GLIDECLIENT_Group="$GLIDECLIENT_Group"
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
chmod 700 `condor_config_val SEC_CREDENTIAL_DIRECTORY`

echo
echo "Will use the following token(s):"
condor_token_list
echo

cd $LOCAL_DIR

# gwms files in the correct location
cp -a /gwms/. $LOCAL_DIR/
cp -a ${simple_job_wrapper} condor_job_wrapper.sh

# minimum env to get glideinwms scripts to work
export glidein_config=$LOCAL_DIR/glidein_config
export condor_vars_file=$LOCAL_DIR/main/condor_vars.lst

# set some defaults for the glideinwms based scripts
if [[ -z $OSG_DEFAULT_CONTAINER_DISTRIBUTION ]]; then
    OSG_DEFAULT_CONTAINER_DISTRIBUTION="10%__htc/rocky:8 90%__htc/rocky:9"
fi
# The glidein scripts expect a 1 or a 0
if is_true "$SINGULARITY_DISABLE_PID_NAMESPACES"; then
    SINGULARITY_DISABLE_PID_NAMESPACES=1
else
    SINGULARITY_DISABLE_PID_NAMESPACES=0
fi

APPTAINER_PATH=/usr/bin/apptainer
# If the user requests an apptainer repository mirror, we need to point condor
# at the back-versioned singularity installation that stil respects the mirror
# file
if [ -n "$APPTAINER_REGISTRY_MIRROR" ]; then
    APPTAINER_PATH=/usr/local/bin/apptainer
fi

cat >$glidein_config <<EOF
ADD_CONFIG_LINE_SOURCE $PWD/add_config_line.source
CONDOR_VARS_FILE $condor_vars_file
ERROR_GEN_PATH $PWD/error_gen.sh
GLIDEIN_SINGULARITY_REQUIRE OPTIONAL
GLIDEIN_Singularity_Use PREFERRED
OSG_DEFAULT_CONTAINER_DISTRIBUTION $OSG_DEFAULT_CONTAINER_DISTRIBUTION
SINGULARITY_IMAGE_RESTRICTIONS None
SINGULARITY_DISABLE_PID_NAMESPACES $SINGULARITY_DISABLE_PID_NAMESPACES
GWMS_SINGULARITY_PATH $APPTAINER_PATH
GLIDEIN_WORKSPACE_ORIG $PWD
GLIDEIN_WORK_DIR $PWD/main
GLIDECLIENT_WORK_DIR $PWD/client
GLIDECLIENT_GROUP_WORK_DIR $PWD/$glidein_group_dir
GLIDEIN_Collector $COLLECTOR_HOST
GLIDECLIENT_Group $GLIDECLIENT_Group
GLIDEIN_Start_Extra $GLIDEIN_Start_Extra
OSG_PROJECT_NAME $OSG_PROJECT_NAME
GLIDEIN_Entry_Name $GLIDEIN_Site
EOF
if [[ $SINGULARITY_BIND_EXTRA ]]; then
    cat >>$glidein_config <<EOF
GLIDEIN_SINGULARITY_BINDPATH $SINGULARITY_BIND_EXTRA
EOF
fi
touch $condor_vars_file

export IS_CONTAINER_PILOT=1

unset SINGULARITY_BIND
export GLIDEIN_SINGULARITY_BINARY_OVERRIDE=$APPTAINER_PATH
${default_image_executable} $glidein_config
./main/singularity_setup.sh $glidein_config
${singularity_extras_lib}   $glidein_config
if [[ -e ${pelican_setup} ]]; then
    ${pelican_setup} $glidein_config
fi

# run the osgvo userenv advertise script
cp ${osgvo_advertise_userenv} .
$PWD/main/singularity_wrapper.sh ./"$(basename ${osgvo_advertise_userenv})" glidein_config osgvo-docker-pilot

if [[ -e ${osgvo_additional_htcondor_config} ]]; then
    echo >&2 "${osgvo_additional_htcondor_config} found; running it"
    bash ${osgvo_additional_htcondor_config} $glidein_config
    echo >&2 "${osgvo_additional_htcondor_config} done"
else
    echo >&2 "${osgvo_additional_htcondor_config} not found"
    echo >&2 "Setting compat config"

    # A few things were removed from 50-main.config to have
    # ${osgvo_additional_htcondor_config} take care of them instead; if we
    # don't have that script, we need to do them here.
    #
    # This can be removed once the changes in https://github.com/opensciencegrid/osg-flock/pull/212
    # get merged into the "main" group as well, and we always use ${osgvo_additional_htcondor_config}
    cat >>$PILOT_CONFIG_FILE <<END
IsBlackHole = False
STARTD_ATTRS = \$(STARTD_ATTRS), IsBlackHole

HasExcessiveLoad = LoadAvg > 2*DetectedCpus + 2
STARTD_ATTRS = \$(STARTD_ATTRS), HasExcessiveLoad

END
fi

# interpret the condor_vars
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



# Read a file for arbitrary additional attributes to insert into the startd ad
extra_attributes_file=/etc/osg/extra-attributes.cfg
if [[ -f $extra_attributes_file ]]; then
    /usr/local/sbin/add-extra-attributes "$extra_attributes_file" "$PILOT_CONFIG_FILE"
fi

# cleanup leftovers from previous instances
if is_true "$GARBAGE_COLLECTION"; then
    ./client/garbage_collection $glidein_config
else
    echo "Garbage collection is disabled. Enable by setting GARBAGE_COLLECTION=1"
fi

# In this container, we replace ldconfig with a wrapper; otherwise, when the nvidia hooks
# run they will run ldconfig and have it fail (it can't write into /etc), resulting
# in nvidia-smi being missing from the apptainer container.
#
# At the time of writing (apptainer 1.1.2), when apptainer runs the nvidia hooks we get
# the following in stderr:
#
#  > WARNING: While finding nv bind points: could not retrieve ld cache: could not execute ldconfig: exit status 1
#  > WARNING: Could not find any nv libraries on this host!
#
# It appears that something unknown is causing a failure with our ldconfig wrapper.  To
# workaround this fact, we are pre-invoking ldconfig.  This creates the cache and helps
# the inner singularity invocation succeed.
/usr/local/bin/ldconfig || :
