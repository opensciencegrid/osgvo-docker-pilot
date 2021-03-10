#!/bin/bash

prog=${0##*/}

fail () {
    echo "$prog:" "$@" >&2
    exit 1
}


shopt -s nullglob
if [[ -d /etc/condor/tokens-orig.d && -n $(echo /etc/condor/tokens-orig.d/*) ]]; then
    install -o condor -g condor -m 0600 /etc/condor/tokens-orig.d/* /etc/condor/tokens.d/
fi

# vim:et:sw=4:sts=4:ts=8
