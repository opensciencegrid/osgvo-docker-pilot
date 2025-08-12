#!/bin/bash -x

APPTAINER_BIN=/cvmfs/oasis.opensciencegrid.org/mis/apptainer/bin/apptainer
OSP_TOKEN_PATH=/tmp/token
CONDOR_LOGDIR=/pilot/log
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

ABORT_CODE=126
SINGULARITY_OUTPUT=$(mktemp)
PILOT_DIR=$(mktemp -d)
function start_singularity_backfill {
    useradd -mG docker testuser
    echo -n "Singularity version is: "
    $APPTAINER_BIN version
    chown testuser: $SINGULARITY_OUTPUT $PILOT_DIR

    su - testuser -c \
       "$APPTAINER_BIN instance start \
          -B /cvmfs \
          -B /dev/fuse \
          -B $PILOT_DIR:/pilot \
          -ci \
          docker-daemon:$CONTAINER_IMAGE \
          backfill"

    ret=$?
    [[ $ret -eq $ABORT_CODE ]] && return $ABORT_CODE

    su - testuser -c \
       "APPTAINERENV_TOKEN=None \
       APPTAINERENV_GLIDEIN_Site=None \
       APPTAINERENV_GLIDEIN_ResourceName=None \
       APPTAINERENV_GLIDEIN_Start_Extra=True \
       $APPTAINER_BIN exec instance://backfill /usr/local/sbin/supervisord_startup.sh > $SINGULARITY_OUTPUT 2>&1 &" 

    ret=$?
    [[ $ret -eq $ABORT_CODE ]] && cat "$SINGULARITY_OUTPUT"
    return $ret
}

function start_docker_backfill {
    touch $OSP_TOKEN_PATH
    docker $COMMON_DOCKER_ARGS \
           "$@" \
           "$CONTAINER_IMAGE"
}

function run_inside_backfill_container {
    if ! docker exec backfill /bin/true &>/dev/null; then
        return $ABORT_CODE
    else
        docker exec backfill "$@"
    fi
}

function debug_docker_backfill {
    docker ps -a
    docker logs backfill
}

function docker_exit_with_cleanup {
    ret=${1:-0}
    docker rm -f backfill || :
    exit $ret
}

function print_test_header {
    msg=$*
    sep=$(python -c "print ('=' * ${#msg})")
    echo -e "$sep\n$msg\n$sep"
}

function condor_version_in_range {
    local minimum maximum
    minimum=${1:?minimum not provided to condor_version_in_range}
    maximum=${2:-99.99.99}

    local condor_version
    condor_version=$(run_inside_backfill_container condor_version | awk '/CondorVersion/ {print $2}')
    python3 -c '
import sys
minimum = [int(x) for x in sys.argv[1].split(".")]
maximum = [int(x) for x in sys.argv[2].split(".")]
version = [int(x) for x in sys.argv[3].split(".")]
sys.exit(0 if minimum <= version <= maximum else 1)
' "$minimum" "$maximum" "$condor_version"
}

function wait_for_output {
    set +x
    maxtime="$1"
    shift
    for (( i=0; i<$maxtime; ++i )); do
        out=$("$@"); ret=$?
        if [[ -n $out ]]; then
            echo "$out"
            set -x
            if [[ $ret -eq $ABORT_CODE ]]; then
                return $ABORT_CODE
            else
                return 0
            fi
        fi
        if [[ $ret -eq $ABORT_CODE ]]; then
            return $ABORT_CODE
        fi
        sleep 1
    done
    set -x
    return 1
}

function test_docker_startup {
    print_test_header "Testing container startup"

    # Wait for the startd to be ready
    # N.B. we have condor dump the eval'ed STARTD_State expression
    # because `condor_who -wait` always returns 0
    startd_ready=$(run_inside_backfill_container condor_who -log "$CONDOR_LOGDIR" \
                                                            -wait:300 'IsReady && STARTD_State =?= "Ready"' \
                                                            -af 'STARTD_State =?= "Ready"')
    ret=$?

    if [[ $ret -eq $ABORT_CODE ]]; then
        debug_docker_backfill
        return $ABORT_CODE
    fi

    if [[ $startd_ready != "true" ]]; then
        run_inside_backfill_container tail -n 400 "$CONDOR_LOGDIR/StartLog"
    fi
}

function test_docker_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    # Condor 23.8 has a bug where condor_status -direct for startd ads still
    # attempts to contact the collector.  Hopefully it will be fixed in 23.10;
    # in the meantime, use -pool instead of -direct (which is a hack).
    local direct
    if condor_version_in_range 23.8.0 23.10.0; then
        direct="-pool"
    else
        direct="-direct"
    fi

    startd_addr=$(run_inside_backfill_container \
                    condor_who -log $CONDOR_LOGDIR \
                               -wait:300 'IsReady && STARTD_State =?= "Ready"' \
                               -dae \
                    | awk '/^Startd/ {print $6}'); ret=$?
    [[ $ret -eq $ABORT_CODE ]] && { debug_docker_backfill; return $ABORT_CODE; }
    echo "startd addr: $startd_addr"
    has_singularity=$(run_inside_backfill_container \
        env _CONDOR_SEC_CLIENT_AUTHENTICATION_METHODS=FS \
        condor_status -slot "$direct" "$startd_addr" -af HAS_SINGULARITY \
    ); ret=$?
    [[ $ret -eq $ABORT_CODE ]] && { debug_docker_backfill; return $ABORT_CODE; }
    if [[ $has_singularity == 'true' ]]; then
        return 0
    fi

    debug_docker_backfill
    return 1
}

function test_singularity_startup {
    print_test_header "Testing container startup"

    # Wait for the startd to be ready
    # N.B. we have condor dump the eval'ed STARTD_State expression
    # because `condor_who -wait` always returns 0
    startd_ready=$(su - testuser -c \
                     "$APPTAINER_BIN exec instance://backfill \
                         condor_who -log $CONDOR_LOGDIR \
                                    -wait:300 'IsReady && STARTD_State =?= \"Ready\"' \
                                    -af 'STARTD_State =?= \"Ready\"'")

    if [[ $startd_ready != "true" ]]; then
        cat $SINGULARITY_OUTPUT
        cat "$CONDOR_LOGDIR/StartLog"
        return 1
    fi
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
        ;;
    cvmfsexec)
        DOCKER_EXTRA_ARGS=(--privileged
                           -e CVMFSEXEC_REPOS='oasis.opensciencegrid.org singularity.opensciencegrid.org'
                           -e CVMFSEXEC_DEBUG=true)
        ;;
esac

case "$CONTAINER_RUNTIME" in
    docker)
        start_docker_backfill "${DOCKER_EXTRA_ARGS[@]}" || docker_exit_with_cleanup $?
        test_docker_startup                             || docker_exit_with_cleanup $?
        test_docker_HAS_SINGULARITY                     || docker_exit_with_cleanup $?
        docker stop backfill
        docker_exit_with_cleanup 0
        ;;
    singularity)
        # we only support Singularity + bind mounted CVMFS
        [[ "$CVMFS_INSTALL" == "bindmount" ]]           || exit 1
        start_singularity_backfill                      || exit 1
        test_singularity_startup                        || exit 1
        test_singularity_HAS_SINGULARITY                || exit 1
        ;;
esac
