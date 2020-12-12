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

if [[ -d /etc/condor/passwords-orig.d && -n $(echo /etc/condor/passwords-orig.d/*) ]]; then
    install -o root -g root -m 0600 /etc/condor/passwords-orig.d/* /etc/condor/passwords.d/
fi
shopt -u nullglob

if [[ -f /etc/condor/gsi-orig.d/hostcert.pem && -f /etc/condor/gsi-orig.d/hostkey.pem ]]; then
    install -o root -g root -m 0644 /etc/condor/gsi-orig.d/hostcert.pem /etc/grid-security/hostcert.pem
    install -o root -g root -m 0600 /etc/condor/gsi-orig.d/hostkey.pem /etc/grid-security/hostkey.pem
fi


# vim:et:sw=4:sts=4:ts=8
