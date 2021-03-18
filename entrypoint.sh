#!/bin/bash

shopt -s nullglob
cvmfs_mounts=(/cvmfs/*)
if [[ -z $cvmfs_mounts && -d /cvmfsexec-template && -n $CVMFSEXEC_REPOS ]]; then
    # user hasn't bind-mounted /cvmfs; use cvmfsexec instead
    # We need our own copy of cvmfsexec for permissions reasons.
    cvmfsexec_root=/tmp/cvmfsexec-$(id -u)
    if [[ ! -d $cvmfsexec_root ]]; then
        cp -rp /cvmfsexec-template $cvmfsexec_root
        $cvmfsexec_root/makedist osg
    fi
    exec $cvmfsexec_root/cvmfsexec $CVMFSEXEC_REPOS -- "$@"
else
    exec "$@"
fi
