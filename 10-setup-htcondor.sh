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

    var_name_len=${#var_name}
    var_val=$(grep "^${var_name} " $glidein_config | tail -n 1 | cut -c $((var_name_len + 2))- )
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


#
# Set pool defaults
#

# Default to the production OSPool unless $ITB is set
if is_true "$ITB"; then
    POOL=${POOL:=itb-ospool}
    glidein_group=itb
    glidein_group_dir=client_group_itb
    script_exec_prefix=/usr/sbin/itb-
    script_lib_prefix=/gwms/client_group_itb/itb-
else
    POOL=${POOL:=prod-ospool}
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
        default_cm2=cm-2.facility.path-cc.io
        default_syslog_host=syslog.osg.chtc.io
        GLIDECLIENT_Group=path-container
        ;;
    *)
        echo "Unknown pool $POOL" >&2
        exit 1
        ;;
esac

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
        generate-hostcert "$_CONDOR_SEC_PASSWORD_FILE" "$REGISTRY_HOSTNAME" || SYSLOG_HOST=""
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
    CONDOR_HOST=$default_cm1,$default_cm2
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
    CCB_SUFFIX="?sock=collector$(random_range 1 5)"
elif [[ $POOL =~ (itb|prod)-path-facility ]]; then
    # Choose a random PATh facility collector for CCB
    # cm-1.facility.path-cc.io:9618?sock=collector9623
    CCB_SUFFIX="9618?sock=collector962$(random_range 0 4)"
fi

if [[ $POOL =~ (itb|prod)-ospool ]]; then
    # OSPools - specific CCB servers. Append the CCB suffix to each ccb host
    COLLECTOR_HOST=$default_cm1$CCB_SUFFIX,$default_cm2$CCB_SUFFIX
    CCB_ADDRESS=$default_ccb1$CCB_SUFFIX,$default_ccb2$CCB_SUFFIX
elif [[ -n $CCB_RANGE_LOW && -n $CCB_RANGE_HIGH ]] ||
       [[ $POOL == 'prod-path-facility' ]]; then
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

if is_true "$CONTAINER_PILOT_USE_JOB_HOOK" && [[ ! -e ${prepare_hook} ]]; then
    echo >&2 "CONTAINER_PILOT_USE_JOB_HOOK requested but job hook not found at ${prepare_hook}"
    exit 1
fi

# to avoid collisions when ~ is shared, write the config file to /tmp
export PILOT_CONFIG_FILE=$LOCAL_DIR/condor_config.pilot

cat >$PILOT_CONFIG_FILE <<EOF
CONDOR_HOST = ${CONDOR_HOST}

# unique local dir
LOCAL_DIR = $LOCAL_DIR

# mimic gwms so gwms scripts will work
EXECUTE = $LOCAL_DIR/execute

SEC_TOKEN_DIRECTORY = $LOCAL_DIR/condor/tokens.d

COLLECTOR_HOST = $COLLECTOR_HOST
CCB_ADDRESS = $CCB_ADDRESS

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

STARTD_ATTRS = \$(STARTD_ATTRS) ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES
MASTER_ATTRS = \$(MASTER_ATTRS) ACCEPT_JOBS_FOR_HOURS ACCEPT_IDLE_MINUTES

# policy
use policy : Hold_If_Memory_Exceeded

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

# WANT_HOLD for exceeding disk is set up in 'additional-htcondor-config'

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

# some admins prefer to reserve gpu slots for gpu jobs, others
# want to run cpu jobs if there are no gpu jobs available
if is_true "$ALLOW_CPUJOB_ON_GPUSLOT"; then
    echo "CPUJOB_ON_GPUSLOT = True" >> "$PILOT_CONFIG_FILE"
else
    echo "CPUJOB_ON_GPUSLOT = ifThenElse(MY.TotalGPUs > 0 && MY.GPUs > 0, TARGET.RequestGPUs > 0, True)" >> "$PILOT_CONFIG_FILE"
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
if is_true "$CONTAINER_PILOT_USE_JOB_HOOK"; then
    cp -a ${simple_job_wrapper} condor_job_wrapper.sh
else
    cp -a ${osgvo_singularity_wrapper} condor_job_wrapper.sh
fi

# minimum env to get glideinwms scripts to work
export glidein_config=$LOCAL_DIR/glidein_config
export condor_vars_file=$LOCAL_DIR/main/condor_vars.lst

# set some defaults for the glideinwms based scripts
if [[ -z $OSG_DEFAULT_CONTAINER_DISTRIBUTION ]]; then
    OSG_DEFAULT_CONTAINER_DISTRIBUTION="30%__opensciencegrid/osgvo-el7:latest 70%__opensciencegrid/osgvo-el8:latest"
fi
# The glidein scripts expect a 1 or a 0
if is_true "$SINGULARITY_DISABLE_PID_NAMESPACES"; then
    SINGULARITY_DISABLE_PID_NAMESPACES=1
else
    SINGULARITY_DISABLE_PID_NAMESPACES=0
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
GWMS_SINGULARITY_PATH /usr/bin/apptainer
GLIDEIN_WORK_DIR $PWD/main
GLIDECLIENT_WORK_DIR $PWD/client
GLIDECLIENT_GROUP_WORK_DIR $PWD/$glidein_group_dir
GLIDEIN_Collector $COLLECTOR_HOST
GLIDECLIENT_Group $GLIDECLIENT_Group
GLIDEIN_Start_Extra $GLIDEIN_Start_Extra
OSG_PROJECT_NAME $OSG_PROJECT_NAME
EOF
if [[ $SINGULARITY_BIND_EXTRA ]]; then
    cat >>$glidein_config <<EOF
GLIDEIN_SINGULARITY_BINDPATH $SINGULARITY_BIND_EXTRA
EOF
fi
touch $condor_vars_file

disable_osdf_plugin () {
    echo "$*; stash://, osdf:// URL support disabled" >&2
    echo "STASH_PLUGIN =" >> "$PILOT_CONFIG_FILE"
    echo "OSDF_PLUGIN =" >> "$PILOT_CONFIG_FILE"  # forward compat
}

# Test the Stash/OSDF plugin that's shipped with Condor; disable it if the test fails.
# TODO: This should be moved to additional-htcondor-config.
osdf_plugin=$(condor_config_val OSDF_PLUGIN 2>/dev/null || condor_config_val STASH_PLUGIN 2>/dev/null)
osdf_remote_test_file=/osgconnect/public/osg/testfile.txt
osdf_test_file=$(mktemp -t osdf-test-file.XXXXXX)
osdf_debug_log=$(mktemp -t osdf-debug-log.XXXXXX)
if [[ ! $osdf_plugin || ! -f $osdf_plugin || ! -x $osdf_plugin ]]; then
    # Can't run it, can't test it. No need to explicitly disable it though.
    echo >&2 "Stash/OSDF file transfer plugin is missing or not runnable; stash://, osdf:// URL support nonfunctional"
elif ! timeout 60s "$osdf_plugin" -d "$osdf_remote_test_file" "$osdf_test_file" >/dev/null 2>"$osdf_debug_log"; then
    disable_osdf_plugin "Stash/OSDF file transfer test failed"
    cat >&2 "$osdf_debug_log"
elif [[ ! -s $osdf_test_file ]]; then
    disable_osdf_plugin "Stash/OSDF file transfer test created an empty file"
    cat >&2 "$osdf_debug_log"
else
    # Sanity check
    filetransfer_plugins=$(condor_config_val FILETRANSFER_PLUGINS 2>/dev/null)
    if [[ $filetransfer_plugins != *${osdf_plugin}* ]]; then
        echo >&2 "Stash/OSDF file transfer plugin missing from plugins list; stash://, osdf:// URL support nonfunctional"
    else
        # Everything's OK. Get the version so we can advertise it.
        osdf_plugin_version=$("$osdf_plugin" -classad | awk '/^PluginVersion / { print $3 }' | tr -d '"')
        if [[ $osdf_plugin_version ]]; then
            echo "STASH_PLUGIN_VERSION = \"$osdf_plugin_version\"" >> "$PILOT_CONFIG_FILE"
            echo "OSDF_PLUGIN_VERSION = \"$osdf_plugin_version\"" >> "$PILOT_CONFIG_FILE"  # forward compat
            echo "STARTD_ATTRS = \$(STARTD_ATTRS) STASH_PLUGIN_VERSION OSDF_PLUGIN_VERSION" >> "$PILOT_CONFIG_FILE"
        fi
    fi
fi
rm -f "$osdf_test_file" "$osdf_debug_log"

export IS_CONTAINER_PILOT=1
# some of the scripts use set/unset for this boolean
if ! is_true "$CONTAINER_PILOT_USE_JOB_HOOK"; then
    unset CONTAINER_PILOT_USE_JOB_HOOK
fi

unset SINGULARITY_BIND
export GLIDEIN_SINGULARITY_BINARY_OVERRIDE=/usr/bin/apptainer
${default_image_executable} $glidein_config
./main/singularity_setup.sh $glidein_config
${singularity_extras_lib}   $glidein_config

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
IsBlackHole = IfThenElse(RecentJobDurationAvg is undefined, false, RecentJobDurationCount >= 10 && RecentJobDurationAvg < 180)
STARTD_ATTRS = \$(STARTD_ATTRS), IsBlackHole

HasExcessiveLoad = LoadAvg > 2*DetectedCpus + 2
STARTD_ATTRS = \$(STARTD_ATTRS), HasExcessiveLoad

DISK_EXCEEDED = (JobUniverse != 13 && DiskUsage =!= UNDEFINED && DiskUsage > Disk)
HOLD_REASON_DISK_EXCEEDED = disk usage exceeded request_disk
use POLICY : WANT_HOLD_IF( DISK_EXCEEDED, \$(HOLD_SUBCODE_DISK_EXCEEDED:104), \$(HOLD_REASON_DISK_EXCEEDED) )

END
fi

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
