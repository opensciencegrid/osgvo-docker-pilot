ARG BASE_OSG_SERIES=24
ARG BASE_YUM_REPO=testing
# This corresponds to the base image used by opensciencegrid/software-base
# el8         = quay.io/centos/centos:stream8
# al8         = quay.io/almalinux/almalinux:8
# el9         = quay.io/almalinux/almalinux:9
# cuda_11_8_0 = nvidia/cuda:11.8.0-runtime-rockylinux8
ARG BASE_OS=el9

FROM alpine:latest AS compile
COPY launch_rsyslogd.c /tmp/launch_rsyslogd.c
RUN apk --no-cache add gcc musl-dev && \
 cc -static -o /launch_rsyslogd /tmp/launch_rsyslogd.c && \
 strip /launch_rsyslogd

FROM hub.opensciencegrid.org/opensciencegrid/software-base:${BASE_OSG_SERIES}-${BASE_OS}-${BASE_YUM_REPO}

# Previous args have gone out of scope
ARG BASE_OSG_SERIES
ARG BASE_OS
ARG BASE_YUM_REPO
ARG TIMESTAMP_IMAGE=osgvo-docker-pilot:${BASE_OSG_SERIES}-${BASE_OS}-${BASE_YUM_REPO}-$(date +%Y%m%d-%H%M)
ARG LOCAL_APPTAINER_VERSION=1.3.6

RUN useradd osg \
 && mkdir -p ~osg/.condor \
 && if [[ $BASE_YUM_REPO != release ]]; then \
        yum -y install apptainer --enablerepo=epel-testing; \
    else \
        yum -y install apptainer; \
    fi \
 && yum -y install \
        osg-wn-client \
        attr \
        'git >= 2' \
        rsyslog rsyslog-gnutls python3-cryptography python3-requests \
        bind-utils \
        socat \
        tini \
        delve \
 && if [[ $BASE_OS != el9 ]]; then yum -y install redhat-lsb-core; fi \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d

# Pull HTCondor from the proper repo. For "release" we need to use
# osg-upcoming-testing to meet the patch tuesday requirements.
RUN if [[ $BASE_YUM_REPO = release ]]; then \
      yum -y --enablerepo=osg-upcoming-testing install condor && \
      if /usr/local/bin/pkg-cmp-gt.sh condor 23.10.26; then \
        yum -y --enablerepo=osg-upcoming-testing swap pelican pelican-debug; \
      fi; \
    else \
      yum -y install condor && \
      if /usr/local/bin/pkg-cmp-gt.sh condor 23.10.26; then \
        yum -y swap pelican pelican-debug; \
      fi; \
    fi

# Install an alternate back-version of apptainer with support for registry mirrors,
# which was broken in the 1.4 release https://github.com/apptainer/apptainer/issues/2919
RUN curl -s https://raw.githubusercontent.com/apptainer/apptainer/main/tools/install-unprivileged.sh | \
    bash -s - -d $(cat /etc/os-release | grep PLATFORM | grep -o 'el[0-9]\+') -v ${LOCAL_APPTAINER_VERSION} /usr/local/


# Make a /proc dir in the sandbox condor uses to test singularity so we can test proc bind mounting
# Workaround for https://opensciencegrid.atlassian.net/browse/HTCONDOR-1574
RUN mkdir -p /usr/libexec/condor/singularity_test_sandbox/proc

# CVMFSEXEC_BRANCH=TAGGED means use the highest versioned tag
ARG CVMFSEXEC_BRANCH=TAGGED
RUN git clone https://github.com/cvmfs/cvmfsexec /cvmfsexec \
 && cd /cvmfsexec \
 && if [[ $CVMFSEXEC_BRANCH = TAGGED ]]; then \
        CVMFSEXEC_BRANCH=$(git tag --sort=version:refname | tail -n 1); \
    fi \
 && git checkout $CVMFSEXEC_BRANCH \
 && ./makedist osg \
 # /cvmfs-cache and /cvmfs-logs is where the cache and logs will go; possibly bind-mounted. \
 # Needs to be 1777 so the unpriv user can use it. \
 # (Can't just chown, don't know the UID of the unpriv user.) \
 && mkdir -p /cvmfs-cache /cvmfs-logs \
 && chmod 1777 /cvmfs-cache /cvmfs-logs \
 && rm -rf dist/var/lib/cvmfs log \
 && ln -s /cvmfs-cache dist/var/lib/cvmfs \
 && ln -s /cvmfs-logs log \
 # tar up and delete the contents of /cvmfsexec so the unpriv user can extract it and own the files. \
 && tar -czf /cvmfsexec.tar.gz ./* \
 && rm -rf ./* \
 # Again, needs to be 1777 so the unpriv user can extract into it. \
 && chmod 1777 /cvmfsexec

# Specify RANDOM when building the image to use the cache for installing RPMs but not for downloading scripts.
ARG RANDOM=

# glideinwms
ARG GWMS_REPO=glideinWMS/glideinwms
ARG GWMS_BRANCH=master
RUN mkdir -p /gwms/main /gwms/client /gwms/client_group_main /gwms/client_group_itb /gwms/.gwms.d/bin /gwms/.gwms.d/exec/{cleanup,postjob,prejob,setup,setup_singularity} \
 && git clone --depth=1 --branch ${GWMS_BRANCH} https://github.com/${GWMS_REPO} glideinwms \
 && cd glideinwms \
 && install creation/web_base/error_gen.sh            /gwms/error_gen.sh                        \
 && install creation/web_base/add_config_line.source  /gwms/add_config_line.source              \
 && install creation/web_base/setup_prejob.sh         /gwms/.gwms.d/exec/prejob/setup_prejob.sh \
 && install creation/web_base/singularity_setup.sh    /gwms/main/singularity_setup.sh           \
 && install creation/web_base/singularity_wrapper.sh  /gwms/main/singularity_wrapper.sh         \
 && install creation/web_base/singularity_lib.sh      /gwms/main/singularity_lib.sh             \
 && echo "GWMS_REPO = \"$GWMS_REPO\""                                       >> /etc/condor/config.d/60-flock-sources.config \
 && echo "GWMS_BRANCH = \"$GWMS_BRANCH\""                                   >> /etc/condor/config.d/60-flock-sources.config \
 && echo "GWMS_HASH = \"$(git rev-parse HEAD)\""                            >> /etc/condor/config.d/60-flock-sources.config \
 && echo "STARTD_ATTRS = \$(STARTD_ATTRS) GWMS_REPO GWMS_BRANCH GWMS_HASH"  >> /etc/condor/config.d/60-flock-sources.config \
 && cd .. && rm -rf glideinwms                                                                  \
 && chmod 755 /gwms/*.sh /gwms/main/*.sh

# osgvo scripts
# Specify the branch and fork of the opensciencegrid/osg-flock repo to get the pilot scripts from
ARG OSG_FLOCK_REPO=opensciencegrid/osg-flock
ARG OSG_FLOCK_BRANCH=master
RUN git clone --branch ${OSG_FLOCK_BRANCH} https://github.com/${OSG_FLOCK_REPO} osg-flock \
 && cd osg-flock \
 # production files: \
 && install ospool-pilot/main/pilot/default-image                       /usr/sbin/osgvo-default-image \
 && install ospool-pilot/main/pilot/advertise-base                      /usr/sbin/osgvo-advertise-base \
 && install ospool-pilot/main/pilot/advertise-userenv                   /usr/sbin/osgvo-advertise-userenv \
 && install ospool-pilot/main/pilot/additional-htcondor-config          /usr/sbin/osgvo-additional-htcondor-config \
 && install ospool-pilot/main/lib/ospool-lib                            /gwms/client_group_main/ospool-lib \
 && install ospool-pilot/main/pilot/singularity-extras                  /gwms/client_group_main/singularity-extras \
 && install job-wrappers/default_singularity_wrapper.sh                 /usr/sbin/osgvo-singularity-wrapper \
 && install ospool-pilot/main/job/prepare-hook                          /gwms/client_group_main/prepare-hook \
 && install ospool-pilot/main/job/simple-job-wrapper.sh                 /usr/sbin/simple-job-wrapper \
 # itb files: \
 && install ospool-pilot/itb/pilot/default-image                        /usr/sbin/itb-osgvo-default-image \
 && install ospool-pilot/itb/pilot/advertise-base                       /usr/sbin/itb-osgvo-advertise-base \
 && install ospool-pilot/itb/pilot/advertise-userenv                    /usr/sbin/itb-osgvo-advertise-userenv \
 && install ospool-pilot/itb/pilot/additional-htcondor-config           /usr/sbin/itb-osgvo-additional-htcondor-config \
 && install ospool-pilot/itb/lib/ospool-lib                             /gwms/client_group_itb/itb-ospool-lib \
 && install ospool-pilot/itb/pilot/singularity-extras                   /gwms/client_group_itb/itb-singularity-extras \
 && install job-wrappers/itb-default_singularity_wrapper.sh             /usr/sbin/itb-osgvo-singularity-wrapper \
 && install ospool-pilot/itb/job/prepare-hook                           /gwms/client_group_itb/itb-prepare-hook \
 && install ospool-pilot/itb/job/simple-job-wrapper.sh                  /usr/sbin/itb-simple-job-wrapper \
 # common files: \
 #   pelican-execeptions is a common file from main, because we use a "find" to locate it, so we can only have one \
 && install ospool-pilot/main/etc/pelican-exceptions.csv                /gwms/client_group_main/pelican-exceptions.csv \
 && install /usr/bin/stashcp                                            /gwms/client/stashcp \
 && install tools/garbage_collection/garbage_collection                 /gwms/client/garbage_collection \
 && install tools/garbage_collection/garbage_collection.aarch64         /gwms/client/garbage_collection.aarch64 \
 && install tools/garbage_collection/garbage_collection.x86_64          /gwms/client/garbage_collection.x86_64 \
 && install tools/garbage_collection/garbage_collection.opt-out         /gwms/client/garbage_collection.opt-out \
 # advertise info \
 && echo "OSG_FLOCK_REPO = \"$OSG_FLOCK_REPO\""        >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_BRANCH = \"$OSG_FLOCK_BRANCH\""    >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_HASH = \"$(git rev-parse HEAD)\""  >> /etc/condor/config.d/60-flock-sources.config \
 && echo "STARTD_ATTRS = \$(STARTD_ATTRS) OSG_FLOCK_REPO OSG_FLOCK_BRANCH OSG_FLOCK_HASH"  >> /etc/condor/config.d/60-flock-sources.config \
 # cleanup \
 && cd .. && rm -rf osg-flock

# Override the software-base supervisord.conf to throw away supervisord logs
COPY supervisord.conf /etc/supervisord.conf

# Ensure that GPU libs can be accessed by user Singularity containers
# running inside Singularity osgvo-docker-pilot containers
# (SOFTWARE-4807)
COPY ldconfig_wrapper.sh /usr/local/bin/ldconfig
COPY 10-ldconfig-cache.sh /etc/osg/image-init.d/

COPY 10-setup-htcondor.sh 20-setup-apptainer.sh /etc/osg/image-init.d/
COPY 10-cleanup-htcondor.sh /etc/osg/image-cleanup.d/
COPY 10-htcondor.conf 10-rsyslogd.conf /etc/supervisord.d/
COPY 50-main.config /etc/condor/config.d/
COPY rsyslog.conf /etc/
RUN sed -i "s|@CONTAINER_TAG@|${TIMESTAMP_IMAGE}|" /etc/condor/config.d/50-main.config


RUN chown -R osg: ~osg 

RUN mkdir -p /pilot && chmod 1777 /pilot

# Depending on configuration, may need to write to system apptainer config directory as an unprivileged user
RUN mkdir -p /etc/containers/registries.conf.d/ && chown osg:osg /etc/containers/registries.conf.d/

# At Expanse, the admins provided a fixed UID/GID that the container will be run as;
# condor fails to start if this isn't a resolvable username.  For now, create the username
# by hand.  If we hit this at more sites, we can do a for-loop for populating /etc/{passwd,groups}
# instead of adding individual user accounts one-by-one.
#
# The Expanse user has such a high UID that it causes problems with people
# running this container using UID namespaces.
# Set NO_EXPANSE_USER when building the image to not add that user.
ARG NO_EXPANSE_USER=
RUN if [[ -z "$NO_EXPANSE_USER" ]]; then \
        groupadd --gid 12497 g12497 && useradd --gid 12497 --create-home --uid 532362 u532362; \
    fi

COPY --from=compile /launch_rsyslogd /usr/bin/launch_rsyslogd
RUN chmod 04755 /usr/bin/launch_rsyslogd && \
    mkdir -p /etc/pki/rsyslog && chmod 01777 /etc/pki/rsyslog && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

COPY --chmod=0755 sbin/* /usr/local/sbin/

WORKDIR /pilot
# We need an ENTRYPOINT so we can use cvmfsexec with any command (such as bash for debugging purposes)
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
# Adding ENTRYPOINT clears CMD
CMD ["/usr/local/sbin/supervisord_startup.sh"]


#
# Here are the various environment variables you can use to customize your pilot
#

# Options to limit resource usage:
# Number of CPUs available to jobs
ENV NUM_CPUS=
# Amount of memory (in MB) available to jobs
ENV MEMORY=

# Space separated list of repos to mount at startup (if using cvmfsexec);
# leave this blank to disable cvmfsexec
ENV CVMFSEXEC_REPOS=
# The proxy to use for CVMFS; leave this blank to use the default
ENV CVMFS_HTTP_PROXY=
# The quota limit in MB for CVMFS; leave this blank to use the default
ENV CVMFS_QUOTA_LIMIT=
# Set this to true to turn on CVMFSEXEC debugging
ENV CVMFSEXEC_DEBUG=false

# How many hours to accept new jobs for
ENV ACCEPT_JOBS_FOR_HOURS=336
# Hours to let running jobs finish during retirement
ENV RETIREMENT_HOURS=24
# Minutes to wait before shutting down due to lack of jobs
ENV ACCEPT_IDLE_MINUTES=30

# Set this to restrict this pilot to only run jobs from a specific Project
ENV OSG_PROJECT_NAME=

# Additional paths to bind for Singularity jobs; same syntax as the -B option in singularity run
ENV SINGULARITY_BIND_EXTRA=

# Additional restrictions for your START expression
ENV GLIDEIN_Start_Extra=

# Add a random string in the NETWORK_HOSTNAME (useful if running multiple containers with the same actual hostname)
ENV GLIDEIN_RANDOMIZE_NAME=false

# Send pilot and condor logs to a central syslog server
ENV ENABLE_REMOTE_SYSLOG=true

# Use ITB versions of scripts and connect to the ITB pool
ENV ITB=false

# Set a non-dockerhub container registry mirror for apptainer to avoid pull rate limits
ENV APPTAINER_REGISTRY_MIRROR=

# The pool to join; this can be 'itb-ospool', 'prod-ospool', 'prod-path-facility',
# 'dev-path-facility', or the hostname or host:port of a central manager.
# If it's set to 'ospool', then it will use 'itb-ospool'  or 'prod-ospool' depending on $ITB.
ENV POOL=ospool
