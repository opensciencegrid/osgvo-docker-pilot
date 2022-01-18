#!/bin/bash

# Save current stdout/err to FD 3&4.  Combine FD 1&2.
# Start a subshell to pipe all the output to a logfile
exec 3>&1 4>&2 &> >(tee -a /tmp/startup.log)

# Allow the derived images to run any additional runtime customizations
shopt -s nullglob
for x in /etc/osg/image-init.d/*.sh; do source "$x"; done
shopt -u nullglob

# Allow child images to add cleanup customizations
function source_cleanup {
    shopt -s nullglob
    for x in /etc/osg/image-cleanup.d/*.sh; do source "$x"; done
    shopt -u nullglob
}
trap source_cleanup EXIT TERM QUIT

chmod go-w /etc/cron.*/* 2>/dev/null || :

# Restore stdout and err to the FD we stored in FD 3&4.
exec 1>&3 2>&4
sleep 1

# Now we can actually start the supervisor
# Note the original stdout / err are still available as fd 3 & 4.  rsyslog will
# only log to the latter set.
exec /usr/bin/supervisord -c /etc/supervisord.conf &> /pilot/log/supervisord.log
