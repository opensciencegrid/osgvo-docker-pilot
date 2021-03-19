#!/bin/bash

fail () {
    echo "$@" >&2
    exit 1
}

shopt -s nullglob
cvmfs_mounts=(/cvmfs/*)
if [[ -z $cvmfs_mounts && -n $CVMFSEXEC_REPOS && -n $CVMFSEXEC_DIST ]]; then
    echo "No cvmfs mounts; using cvmfsexec to mount $CVMFSEXEC_REPOS"
    # We need our own copy of cvmfsexec for permissions reasons.
    cvmfsexec_root=/tmp/cvmfsexec-$(id -u)
    if [[ ! -d $cvmfsexec_root ]]; then
        echo "No cvmfsexec dir found for this user at $cvmfsexec_root; creating one"
        cp -rp /cvmfsexec $cvmfsexec_root || fail "Couldn't create $cvmfsexec_root"
        echo "Fetching $CVMFSEXEC_DIST CVMFS config"
        $cvmfsexec_root/makedist $CVMFSEXEC_DIST || fail "Couldn't fetch CVMFS config"
    fi
    $cvmfsexec_root/cvmfsexec -- /bin/true || \
        fail "cvmfsexec smoke test failed.  You may not have the permissions to run cvmfsexec; see https://github.com/cvmfs/cvmfsexec#README for details"
    exec $cvmfsexec_root/cvmfsexec $CVMFSEXEC_REPOS -- "$@"
else
    exec "$@"
fi
