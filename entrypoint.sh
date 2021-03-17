#!/bin/bash

shopt -s nullglob
cvmfs_mounts=(/cvmfs/*)
if [[ -z $cvmfs_mounts && -d ~/cvmfsexec && -n $CVMFS_REPOS ]]; then
    # user hasn't bind-mounted /cvmfs; use cvmfsexec instead
    exec ~/cvmfsexec/cvmfsexec $CVMFS_REPOS -- "$@"
else
    exec "$@"
fi
