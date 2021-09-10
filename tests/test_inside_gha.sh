#!/bin/bash -x

CONTAINER_IMAGE='osgvo-docker-pilot:latest'
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

# Modern versions of Singularity aren't readily available on Ubuntu so
# we test Singularity-deployed osgvo-backfill containers inside a
# Docker container
TEST_CONTAINER_NAME=singularity-env

function usage {
    echo "Usage: $0 <docker|singularity> <bindmount|cvmfsexec>"
}

function install_singularity {
    docker run -d \
           --privileged \
           --name $TEST_CONTAINER_NAME \
           "$@" \
           centos:centos7 \
           sleep infinity

    run_inside_test_container -- yum install -y epel-release
    run_inside_test_container -- yum install -y singularity
}

function start_singularity_backfill {
    run_inside_test_container -e SINGULARITYENV_TOKEN=None \
                              -e SINGULARITYENV_GLIDEIN_Site=None \
                              -e SINGULARITYENV_GLIDEIN_ResourceName=None \
                              -e SINGULARITYENV_GLIDEIN_Start_Extra=True \
                              -- \
                              singularity instance start \
                                          -B /cvmfs \
                                          -B .:/pilot \
                                          -c \
                                          docker-archive:///tmp/osgvo-docker-pilot.tar \
                                          backfill
}

function run_inside_test_container {
    docker_opts=()
    for arg in "$@"; do
        shift
        if [[ $arg == "--" ]]; then
            break
        fi
        docker_opts+=("$arg")
    done

    if [[ -z "$*" ]]; then
        echo 'Usage: run_inside_test_container [DOCKER_OPTS] -- <COMMAND TO EXEC>'
        return 2
    fi

    docker exec "${docker_opts[@]}" "$TEST_CONTAINER_NAME" "$@"
}

function install_cvmfs {
    apt-get install lsb-release
    wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
    wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-contrib-release/cvmfs-contrib-release-latest_all.deb
    dpkg -i cvmfs-release-latest_all.deb cvmfs-contrib-release-latest_all.deb
    rm -f *.deb
    apt-get update
    apt-get install -y cvmfs-config-osg cvmfs    
}

function start_cvmfs {
    systemctl start autofs
    mkdir -p /etc/auto.master.d/
    echo "/cvmfs /etc/auto.cvmfs" > /etc/auto.master.d/cvmfs.autofs
    cat << EOF > /etc/cvmfs/default.local
CVMFS_REPOSITORIES="$((echo oasis.opensciencegrid.org;echo cms.cern.ch;ls /cvmfs)|sort -u|paste -sd ,)"
CVMFS_QUOTA_LIMIT=2000
CVMFS_HTTP_PROXY="DIRECT"
EOF
    systemctl restart autofs
    ls -l /cvmfs/singularity.opensciencegrid.org
}

function start_docker_backfill {
    touch $OSP_TOKEN_PATH
    docker $COMMON_DOCKER_ARGS \
           "$@" \
           $CONTAINER_IMAGE
}

function run_inside_backfill_container {
    docker exec backfill "$@"
}

function run_inside_singularity_backfill {
    run_inside_test_container -- singularity exec instance://backfill "$@"
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

    logfile=$(wait_for_output 600 run_inside_backfill_container find /pilot -name StartLog)
    if [[ -z $logfile ]]; then
        docker ps -a
        docker logs backfill
        return 1
    fi

    wait_for_output 60 \
                    run_inside_backfill_container \
                        grep \
                        -- \
                        'Changing activity: Benchmarking -> Idle' \
                        $logfile \
        || return 1
}

function test_docker_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    logdir=$(run_inside_backfill_container find /pilot -type d -name log)
    startd_addr=$(run_inside_backfill_container condor_who -log $logdir -dae | awk '/^Startd/ {print $6}')
    has_singularity=$(run_inside_backfill_container condor_status -direct $startd_addr -af HAS_SINGULARITY)
    if [[ $has_singularity == 'true' ]]; then
        return 0
    fi
    return 1
}

function test_singularity_startup {
    print_test_header "Testing container startup"

    logfile=$(wait_for_output 600 run_inside_singularity_backfill find /pilot -name StartLog)
    if [[ -z $logfile ]]; then
        run_inside_test_container -- singularity instance list
        return 1
    fi

    wait_for_output 60 \
                    run_inside_singularity_backfill \
                        grep \
                        -- \
                        'Changing activity: Benchmarking -> Idle' \
                        $logfile \
        || return 1
}

function test_singularity_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    logdir=$(run_inside_singularity_backfill find /pilot -type d -name log)
    startd_addr=$(run_inside_singularity_backfill condor_who -log $logdir -dae | awk '/^Startd/ {print $6}')
    has_singularity=$(run_inside_singularity_backfill condor_status -direct $startd_addr -af HAS_SINGULARITY)
    if [[ $has_singularity == 'true' ]]; then
        return 0
    fi
    return 1
}

if [[ $# -ne 2 ]] ||
       ! [[ $1 =~ ^(docker|singularity)$ ]] ||
       ! [[ $2 =~ ^(bindmount|cvmfsexec)$ ]]; then
    usage
    exit 1
fi

CONTAINER_RUNTIME="$1"
CVMFS_INSTALL="$2"
EXIT_CODE=0

case "$CVMFS_INSTALL" in
    bindmount)
        DOCKER_EXTRA_ARGS=(--cap-add DAC_OVERRIDE
                           --cap-add DAC_READ_SEARCH
                           --cap-add SETUID
                           --cap-add SETGID
                           --cap-add SYS_ADMIN
                           --cap-add SYS_CHROOT
                           --cap-add SYS_PTRACE
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
        test_docker_startup                         || EXIT_CODE=1
        test_docker_HAS_SINGULARITY                 || EXIT_CODE=1
        ;;
    singularity)
        tempfile=$(mktemp)
        docker save $CONTAINER_IMAGE -o $tempfile
        DOCKER_EXTRA_ARGS+=(-v "$tempfile:/tmp/osgvo-docker-pilot.tar")
        install_singularity "${DOCKER_EXTRA_ARGS[@]}"
        start_singularity_backfill
        test_singularity_startup                    || EXIT_CODE=1
        test_singularity_HAS_SINGULARITY            || EXIT_CODE=1
        ;;
esac

exit $EXIT_CODE
