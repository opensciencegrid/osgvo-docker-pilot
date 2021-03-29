#!/bin/bash

fail () {
    echo "$@" >&2
    exit 1
}

cvmfsexec_root=/cvmfsexec
cvmfsexec_tarball=/cvmfsexec.tar.gz

if [[ -d /cvmfs/config-osg.opensciencegrid.org ]]; then
    # OSG CVMFS already available (perhaps via bind-mount),
    # no special action needed.
    exec "$@"
elif [[ -z $CVMFSEXEC_REPOS ]]; then
    # No CVMFS repos requested, skipping cvmfsexec.
    exec "$@"
fi

cd "$cvmfsexec_root" || \
    fail "Couldn't enter $cvmfsexec_root"
if [[ ! -e $cvmfsexec_root/dist ]]; then
    tar -xzf $cvmfsexec_tarball -C $cvmfsexec_root || \
        fail "Couldn't extract $cvmfsexec_tarball into $cvmfsexec_root"
fi

$cvmfsexec_root/cvmfsexec -- /bin/true || \
    fail "cvmfsexec smoke test failed.  You may not have the permissions to run cvmfsexec; see https://github.com/cvmfs/cvmfsexec#README for details"

exec $cvmfsexec_root/cvmfsexec $CVMFSEXEC_REPOS -- "$@"
