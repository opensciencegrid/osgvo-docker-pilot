#!/bin/bash -x

CONTAINER_IMAGE='osgvo-docker-pilot:latest'
COMMON_DOCKER_ARGS='run --rm --user osg
                        --security-opt apparmor=unconfined
                        -v /path/to/token:/etc/condor/tokens-orig.d/flock.opensciencegrid.org
                        -e GLIDEIN_Site="None"
                        -e GLIDEIN_ResourceName="None"
                        -e GLIDEIN_Start_Extra="True"
                        -e OSG_SQUID_LOCATION="None"
                        -a stdout
                        -a stderr'

# Modern versions of Singularity aren't readily available on Ubuntu so
# we test Singularity-deployed osgvo-backfill containers inside a
# Docker container
TEST_CONTAINER_NAME=singularity-env
TEST_CONTAINER_EXTRA_ARGS=()

function usage {
    echo "Usage: $0 <docker|singularity> <bindmount|cvmfsexec>"
}

function install_singularity {
    docker run -d \
           --privileged \
           --name $TEST_CONTAINER_NAME \
           -v /var/run/docker.sock:/var/run/docker.sock \
           ${TEST_CONTAINER_EXTRA_ARGS[@]} \
           centos:centos7 \
           sleep infinity

    run_inside_test_container 'yum install -y epel-release'
    run_inside_test_container 'yum install -y singularity'
}

function run_inside_test_container {
    docker exec $TEST_CONTAINER_NAME "$@"
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

function test_HAS_SINGULARITY {
    fgrep "HAS_SINGULARITY = True" > /dev/null
}

function test_docker_bindmount_HAS_SINGULARITY {
    # Store output in a var so that we get its contents in the xtrace output
    out=$(docker $COMMON_DOCKER_ARGS \
                 --cap-add=DAC_OVERRIDE --cap-add=SETUID --cap-add=SETGID \
                 --cap-add=DAC_READ_SEARCH \
                 --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=SYS_PTRACE \
                 -v /cvmfs:/cvmfs:shared \
                 $CONTAINER_IMAGE \
                 /usr/sbin/osgvo-node-advertise)
    test_HAS_SINGULARITY <<< "$out"
}

function test_docker_bindmount_startup {
    docker run --user osg \
           --detach \
           --name backfill \
           -v /cvmfs:/cvmfs:shared \
           -v /path/to/token:/etc/condor/tokens-orig.d/flock.opensciencegrid.org \
           -e GLIDEIN_Site="None" \
           -e GLIDEIN_ResourceName="None" \
           -e GLIDEIN_Start_Extra="True" \
           -e OSG_SQUID_LOCATION="None" \
           $CONTAINER_IMAGE
     docker logs -f backfill | fgrep "Setting ready state 'Ready' for STARTD"
}

function test_docker_cvmfsexec_HAS_SINGULARITY {
    # Store output in a var so that we get its contents in the xtrace output
    out=$(docker $COMMON_DOCKER_ARGS \
                 --privileged \
                 -e CVMFSEXEC_REPOS="oasis.opensciencegrid.org \
                           singularity.opensciencegrid.org" \
                 $CONTAINER_IMAGE \
                 /usr/sbin/osgvo-node-advertise)
    test_HAS_SINGULARITY <<< "$out"
}

function test_singularity_bindmount_HAS_SINGULARITY {
    run_inside_test_container SINGULARITYENV_TOKEN=None \
                              SINGULARITYENV_GLIDEIN_Site=None \
                              SINGULARITYENV_GLIDEIN_ResourceName=None \
                              SINGULARITYENV_GLIDEIN_Start_Extra=True \
                              singularity run \
                                          --scratch /pilot \
                                          -B /cvmfs \
                                          -cip \
                                          docker://$CONTAINER_IMAGE \
                                          /usr/sbin/osgvo-node-advertise \
        | test_HAS_SINGULARITY
}

function test_singularity_cvmfsexec_HAS_SINGULARITY {
    run_inside_test_container SINGULARITYENV_TOKEN=None \
                              SINGULARITYENV_GLIDEIN_Site=None \
                              SINGULARITYENV_GLIDEIN_ResourceName=None \
                              SINGULARITYENV_GLIDEIN_Start_Extra=True \
                              singularity run \
                                          --scratch /pilot \
                                          -cip \
                                          docker://$CONTAINER_IMAGE \
                                          /usr/sbin/osgvo-node-advertise \
        | test_HAS_SINGULARITY
}

if [[ $# -ne 2 ]] ||
       ! [[ $1 =~ ^(docker|singularity)$ ]] ||
       ! [[ $2 =~ ^(bindmount|cvmfsexec)$ ]]; then
    usage
    exit 1
fi

CONTAINER_RUNTIME="$1"
CVMFS_INSTALL="$2"

if [[ $CVMFS_INSTALL == 'bindmount' ]]; then
    TEST_CONTAINER_EXTRA_ARGS+=("-v /cvmfs:/cvmfs:shared")
    install_cvmfs
    start_cvmfs
fi
[[ $CONTAINER_RUNTIME == 'singularity' ]] && install_singularity

case "$CONTAINER_RUNTIME-$CVMFS_INSTALL" in
    docker-bindmount)
        test_docker_bindmount_HAS_SINGULARITY
        test_docker_bindmount_startup
        ;;
    docker-cvmfsexec)
        test_docker_cvmfsexec_HAS_SINGULARITY
        ;;
    singularity-bindmount)
        test_singularity_bindmount_HAS_SINGULARITY
        ;;
    singularity-cvmfsexec)
        test_singularity_cvmfsexec_HAS_SINGULARITY
        ;;
esac
