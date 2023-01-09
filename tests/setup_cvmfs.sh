#!/bin/bash -x

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

install_cvmfs
start_cvmfs
