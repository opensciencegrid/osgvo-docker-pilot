#!/bin/bash

fail () {
    echo "$@" >&2
    exit 1
}

cvmfsexec_root=/cvmfsexec
cvmfsexec_tarball=/cvmfsexec.tar.gz
cvmfsexec_local_config=$cvmfsexec_root/dist/etc/cvmfs/default.local
htcondor_supervisord_config=/etc/supervisord.d/10-htcondor.conf

if [[ -d /cvmfs/config-osg.opensciencegrid.org ]]; then
    echo "OSG CVMFS already available (perhaps via bind-mount),"
    echo "skipping cvmfsexec."
    exec "$@"
elif [[ -z $CVMFSEXEC_REPOS ]]; then
    echo "No CVMFS repos requested, skipping cvmfsexec."
    exec "$@"
fi
CVMFSEXEC_REPOS=$(tr -s ',' ' ' <<<"$CVMFSEXEC_REPOS")

cd "$cvmfsexec_root" || \
    fail "Couldn't enter $cvmfsexec_root"
if [[ ! -e $cvmfsexec_root/dist ]]; then
    tar -xzf $cvmfsexec_tarball -C $cvmfsexec_root || \
        fail "Couldn't extract $cvmfsexec_tarball into $cvmfsexec_root"
fi

$cvmfsexec_root/cvmfsexec -N -- /bin/true || \
    fail "cvmfsexec smoke test failed.  You may not have the permissions to run cvmfsexec; see https://github.com/cvmfs/cvmfsexec#README for details"

add_or_replace () {
    local file="$1"
    local var="$2"
    local value="$3"

    if grep -Eq "^${var}=" "$file"; then
        sed -i -r -e "s#^${var}=.*#${var}=${value}#" "$file"
    else
        echo "${var}=\"${value}\"" >> "$file"
    fi
}

add_or_replace_quoted () {
    local file="$1"
    local var="$2"
    local value="$3"

    if grep -Eq "^${var}=" "$file"; then
        sed -i -r -e "s#^${var}=.*#${var}=\"${value}\"#" "$file"
    else
        echo "${var}=\"${value}\"" >> "$file"
    fi
}

if [[ -e /cvmfsexec/default.local ]]; then
    cp -f /cvmfsexec/default.local "$cvmfsexec_local_config"
fi

if [[ -n $CVMFS_HTTP_PROXY ]]; then
    add_or_replace_quoted "$cvmfsexec_local_config" CVMFS_HTTP_PROXY "${CVMFS_HTTP_PROXY}"
fi

if [[ -n $CVMFS_QUOTA_LIMIT ]]; then
    add_or_replace_quoted "$cvmfsexec_local_config" CVMFS_QUOTA_LIMIT "${CVMFS_QUOTA_LIMIT}"
fi

if [ "x$SUPERVISORD_RESTART_POLICY" != "x" ]; then
    add_or_replace "$htcondor_supervisord_config" autorestart "${SUPERVISORD_RESTART_POLICY}"
fi

exec $cvmfsexec_root/cvmfsexec -N $CVMFSEXEC_REPOS -- "$@"
