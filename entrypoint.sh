#!/bin/bash

set -x

shopt -s nullglob
cvmfs_mounts=(/cvmfs/*)
if [[ -z $cvmfs_mounts && -n $CVMFSEXEC_REPOS && -n $CVMFSEXEC_DIST ]]; then
    set -e
    echo "No cvmfs mounts; using cvmfsexec to mount $CVMFSEXEC_REPOS"
    # We need our own copy of cvmfsexec for permissions reasons.
    cvmfsexec_root=/tmp/cvmfsexec-$(id -u)
    if [[ ! -d $cvmfsexec_root ]]; then
        echo "No cvmfsexec dir found for this user at $cvmfsexec_root; creating one"
        cp -rp /cvmfsexec $cvmfsexec_root
        echo "Fetching $CVMFSEXEC_DIST CVMFS config"
        $cvmfsexec_root/makedist $CVMFSEXEC_DIST
    fi
    exec $cvmfsexec_root/cvmfsexec $CVMFSEXEC_REPOS -- "$@"
else
    exec "$@"
fi
