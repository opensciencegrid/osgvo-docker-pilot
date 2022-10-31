#!/bin/bash -x

OSP_TOKEN_PATH=/tmp/token
COMMON_DOCKER_ARGS="run --user osg
                        --detach
                        --security-opt apparmor=unconfined
                        --name backfill
                        -v $OSP_TOKEN_PATH:/etc/condor/tokens-orig.d/flock.opensciencegrid.org
                        -e GLIDEIN_Site='None'
                        -e GLIDEIN_ResourceName='None'
                        -e GLIDEIN_Start_Extra='True'
                        -e OSG_SQUID_LOCATION='None'"

function usage {
    echo "Usage: $0 <docker|singularity> <bindmount|cvmfsexec>"
}

SINGULARITY_OUTPUT=$(mktemp)
PILOT_DIR=$(mktemp -d)
function start_singularity_backfill {
    useradd -mG docker testuser
    singularity=/cvmfs/oasis.opensciencegrid.org/mis/singularity/bin/singularity
    echo -n "Singularity version is: "
    $singularity version
    chown testuser: $SINGULARITY_OUTPUT $PILOT_DIR
    su - testuser -c \
       "SINGULARITYENV_TOKEN=None \
       SINGULARITYENV_GLIDEIN_Site=None \
       SINGULARITYENV_GLIDEIN_ResourceName=None \
       SINGULARITYENV_GLIDEIN_Start_Extra=True \
       $singularity \
          run \
            -B /cvmfs \
            -B $PILOT_DIR:/pilot \
            -cip \
            docker-daemon:$CONTAINER_IMAGE > $SINGULARITY_OUTPUT 2>&1 &"
}

function install_cvmfs {
    if [[ $- = *e* ]]; then
        olde="-e"
    else
        olde="+e"
    fi
    set -e
    apt-get install lsb-release
    wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
    wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-contrib-release/cvmfs-contrib-release-latest_all.deb
    dpkg -i cvmfs-release-latest_all.deb cvmfs-contrib-release-latest_all.deb
    rm -f *.deb
    apt-get update
    apt-get install -y cvmfs-config-osg cvmfs
    set $olde
}

function start_cvmfs {
    if [[ $- = *e* ]]; then
        olde="-e"
    else
        olde="+e"
    fi
    set -e
    systemctl start autofs
    mkdir -p /etc/auto.master.d/
    echo "/cvmfs /etc/auto.cvmfs" > /etc/auto.master.d/cvmfs.autofs
    cat << EOF | tee /etc/cvmfs/default.local
CVMFS_REPOSITORIES="$( (echo oasis.opensciencegrid.org;echo cms.cern.ch;ls /cvmfs) | sort -u|paste -sd ,)"
CVMFS_QUOTA_LIMIT=2000
CVMFS_HTTP_PROXY="DIRECT"
EOF
    systemctl restart autofs
    ls -l /cvmfs/singularity.opensciencegrid.org
    set $olde
}

function start_docker_backfill {
    touch $OSP_TOKEN_PATH
    docker $COMMON_DOCKER_ARGS \
           "$@" \
           "$CONTAINER_IMAGE"
}

function run_inside_backfill_container {
    docker exec backfill "$@"
}

function debug_docker_backfill {
    docker ps -a
    docker logs backfill
}

function print_test_header {
    msg=$@
    sep=$(python -c "print ('=' * ${#msg})")
    echo -e "$sep\n$msg\n$sep"
}

function wait_for_output {
    set +x
    maxtime="$1"
    shift
    for (( i=0; i<$maxtime; ++i )); do
        out=$("$@")
        if [[ -n $out ]]; then
            echo $out
            set -x
            return 0
        fi
        sleep 1
    done
    set -x
    return 1
}

function test_docker_startup {
    print_test_header "Testing container startup"

    logfile=$(wait_for_output 600 run_inside_backfill_container find /pilot -name StartLog -size +1)
    if [[ -z $logfile ]]; then
        debug_docker_backfill
        return 1
    fi

    wait_for_output 60 \
                    run_inside_backfill_container \
                        grep \
                        -- \
                        'Changing activity: Benchmarking -> Idle' \
                        $logfile \
        || (tail -n 400 $logfile && return 1)
}

function test_docker_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    logdir=$(run_inside_backfill_container find /pilot -type d -name log)
    startd_addr=$(run_inside_backfill_container condor_who -log $logdir -dae | awk '/^Startd/ {print $6}')
    has_singularity=$(run_inside_backfill_container condor_status -direct $startd_addr -af HAS_SINGULARITY)
    if [[ $has_singularity == 'true' ]]; then
        return 0
    fi

    debug_docker_backfill
    return 1
}

function test_singularity_startup {
    print_test_header "Testing container startup"

    logfile=$(wait_for_output 600 find $PILOT_DIR -name StartLog -size +1)
    if [[ -z $logfile ]]; then
        cat $SINGULARITY_OUTPUT
        return 1
    fi

    ret=0
    wait_for_output 60 \
                    grep \
                    -- \
                    'Changing activity: Benchmarking -> Idle' \
                    $logfile \
        || ret=$?
    echo "Singularity logs:"
    head -n 100 $logfile
    echo "..."
    tail -n 400 $logfile
    return $ret
}

function test_singularity_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    egrep -i 'HAS_SINGULARITY *= *True' $SINGULARITY_OUTPUT; ret=$?
    if [[ $ret -ne 0 ]]; then
        cat $SINGULARITY_OUTPUT
    fi
    return $ret
}

if [[ $# -ne 3 ]] ||
       ! [[ $1 =~ ^(docker|singularity)$ ]] ||
       ! [[ $2 =~ ^(bindmount|cvmfsexec)$ ]]; then
    usage
    exit 1
fi

CONTAINER_RUNTIME="$1"
CVMFS_INSTALL="$2"
CONTAINER_IMAGE="$3"

case "$CVMFS_INSTALL" in
    bindmount)
        DOCKER_EXTRA_ARGS=(--security-opt seccomp=unconfined
                           --security-opt systempaths=unconfined
                           --security-opt no-new-privileges
                           -v "/cvmfs:/cvmfs:shared")
        install_cvmfs
        start_cvmfs
        ;;
    cvmfsexec)
        DOCKER_EXTRA_ARGS=(--privileged
                           -e CVMFSEXEC_REPOS='oasis.opensciencegrid.org singularity.opensciencegrid.org')
        ;;
esac

case "$CONTAINER_RUNTIME" in
    docker)
        start_docker_backfill "${DOCKER_EXTRA_ARGS[@]}" || exit 1
        test_docker_startup                             || exit 1
        test_docker_HAS_SINGULARITY                     || exit 1
        ;;
    singularity)
        # we only support Singularity + bind mounted CVMFS
        [[ "$CVMFS_INSTALL" == "bindmount" ]]           || exit 1
        start_singularity_backfill                      || exit 1
        test_singularity_startup                        || exit 1
        test_singularity_HAS_SINGULARITY                || exit 1
        ;;
esac
