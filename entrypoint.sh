#!/bin/bash

shopt -s nullglob
cvmfs_mounts=(/cvmfs/*)
if [[ -z $cvmfs_mounts && -d /cvmfsexec-template && -n $CVMFSEXEC_REPOS ]]; then
    set -e
    echo "No cvmfs mounts, but /cvmfsexec-template exists and caller has requested mounting $CVMFSEXEC_REPOS"
    # user hasn't bind-mounted /cvmfs; use cvmfsexec instead
    # We need our own copy of cvmfsexec for permissions reasons.
    cvmfsexec_root=/tmp/cvmfsexec-$(id -u)
    if [[ ! -d $cvmfsexec_root ]]; then
        echo "No cvmfsexec dir found for this user at $cvmfsexec_root; creating from template"
        cp -rp /cvmfsexec-template $cvmfsexec_root
        echo "Fetching OSG CVMFS config"
        $cvmfsexec_root/makedist osg
    fi
    exec $cvmfsexec_root/cvmfsexec $CVMFSEXEC_REPOS -- "$@"
else
    exec "$@"
fi
