ARG BASE_OSG_SERIES=3.6
ARG BASE_YUM_REPO=testing

FROM alpine:latest AS compile
COPY launch_rsyslogd.c /tmp/launch_rsyslogd.c
RUN apk --no-cache add gcc musl-dev && \
 cc -static -o /launch_rsyslogd /tmp/launch_rsyslogd.c && \
 strip /launch_rsyslogd

FROM opensciencegrid/software-base:${BASE_OSG_SERIES}-el8-${BASE_YUM_REPO}

ENV IS_CONTAINER_PILOT=1

# Set this to "1" to use ITB versions of scripts and connect to the ITB pool
ENV ITB=

# Previous args have gone out of scope
ARG BASE_OSG_SERIES=3.6
ARG BASE_YUM_REPO=testing
ARG TIMESTAMP_TAG

ARG CONTAINER_TAG=opensciencegrid/osgvo-docker-pilot:${BASE_OSG_SERIES}-${BASE_YUM_REPO}-${TIMESTAMP_TAG}

RUN useradd osg \
 && mkdir -p ~osg/.condor \
 && yum -y install \
        osg-wn-client \
        redhat-lsb-core \
        apptainer \
        attr \
        git \
        rsyslog rsyslog-gnutls python3-cryptography python3-requests \
        bind-utils \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d

# Pull HTCondor from the proper repo. For "release" we need to use
# osg-upcoming-testing to meet the patch tuesday requirements.
RUN if [[ $BASE_YUM_REPO = release ]]; then \
      yum -y --enablerepo=osg-upcoming-testing install condor; \
    else \
      yum -y install condor; \
    fi

RUN git clone https://github.com/cvmfs/cvmfsexec /cvmfsexec \
 && cd /cvmfsexec \
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

# Space separated list of repos to mount at startup (if using cvmfsexec);
# leave this blank to disable cvmfsexec
ENV CVMFSEXEC_REPOS=
# The proxy to use for CVMFS; leave this blank to use the default
ENV CVMFS_HTTP_PROXY=
# The quota limit in MB for CVMFS; leave this blank to use the default
ENV CVMFS_QUOTA_LIMIT=


# Specify RANDOM when building the image to use the cache for installing RPMs but not for downloading scripts.
ARG RANDOM=

# glideinwms
ARG GWMS_REPO=edquist/glideinwms
ARG GWMS_BRANCH=SOFTWARE-5340.fix-PATH
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
 && install node-check/osgvo-default-image                              /usr/sbin/osgvo-default-image \
 && install node-check/osgvo-advertise-base                             /usr/sbin/osgvo-advertise-base \
 && install node-check/osgvo-advertise-userenv                          /usr/sbin/osgvo-advertise-userenv \
 && install job-wrappers/default_singularity_wrapper.sh                 /usr/sbin/osgvo-singularity-wrapper \
 && install node-check/ospool-lib                                       /gwms/client_group_main/ospool-lib \
 && install node-check/singularity-extras                               /gwms/client_group_main/singularity-extras \
 # itb files: \
 && install ospool-pilot/itb/pilot/default-image                        /usr/sbin/itb-osgvo-default-image \
 && install ospool-pilot/itb/pilot/advertise-base                       /usr/sbin/itb-osgvo-advertise-base \
 && install ospool-pilot/itb/pilot/advertise-userenv                    /usr/sbin/itb-osgvo-advertise-userenv \
 && install ospool-pilot/itb/lib/ospool-lib                             /gwms/client_group_itb/itb-ospool-lib \
 && install ospool-pilot/itb/pilot/singularity-extras                   /gwms/client_group_itb/itb-singularity-extras \
 && install job-wrappers/itb-default_singularity_wrapper.sh             /usr/sbin/itb-osgvo-singularity-wrapper \
 # common files: \
 && install stashcp/stashcp                                             /gwms/client/stashcp \
 && install stashcp/stash_plugin                                        /usr/libexec/condor/stash_plugin \
 && ln -snf /gwms/client/stashcp                                        /usr/bin/stashcp \
 # advertise info \
 && echo "OSG_FLOCK_REPO = \"$OSG_FLOCK_REPO\""        >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_BRANCH = \"$OSG_FLOCK_BRANCH\""    >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_HASH = \"$(git rev-parse HEAD)\""  >> /etc/condor/config.d/60-flock-sources.config \
 && echo "STARTD_ATTRS = \$(STARTD_ATTRS) OSG_FLOCK_REPO OSG_FLOCK_BRANCH OSG_FLOCK_HASH"  >> /etc/condor/config.d/60-flock-sources.config \
 # cleanup \
 && cd .. && rm -rf osg-flock

COPY condor_master_wrapper /usr/sbin/
RUN chmod 755 /usr/sbin/condor_master_wrapper

# Override the software-base supervisord.conf to throw away supervisord logs
COPY supervisord.conf /etc/supervisord.conf

# Options to limit resource usage:
# Number of CPUs available to jobs
ENV NUM_CPUS=
# Amount of memory (in MB) available to jobs
ENV MEMORY=

# Ensure that GPU libs can be accessed by user Singularity containers
# running inside Singularity osgvo-docker-pilot containers
# (SOFTWARE-4807)
COPY ldconfig_wrapper.sh /usr/local/bin/ldconfig
COPY 10-ldconfig-cache.sh /etc/osg/image-init.d/

COPY master_shutdown.sh /etc/condor/
COPY generate-hostcert entrypoint.sh /bin/
COPY 10-setup-htcondor.sh /etc/osg/image-init.d/
COPY 10-cleanup-htcondor.sh /etc/osg/image-cleanup.d/
COPY 10-htcondor.conf 10-rsyslogd.conf /etc/supervisord.d/
COPY 50-main.config /etc/condor/config.d/
COPY rsyslog.conf /etc/
RUN chmod 755 /bin/entrypoint.sh
RUN sed -i "s|@CONTAINER_TAG@|${CONTAINER_TAG}|" /etc/condor/config.d/50-main.config


RUN chown -R osg: ~osg 

RUN mkdir -p /pilot && chmod 1777 /pilot

# At Expanse, the admins provided a fixed UID/GID that the container will be run as;
# condor fails to start if this isn't a resolvable username.  For now, create the username
# by hand.  If we hit this at more sites, we can do a for-loop for populating /etc/{passwd,groups}
# instead of adding individual user accounts one-by-one.
RUN groupadd --gid 12497 g12497 && useradd --gid 12497 --create-home --uid 532362 u532362

COPY --from=compile /launch_rsyslogd /usr/bin/launch_rsyslogd
RUN chmod 04755 /usr/bin/launch_rsyslogd && \
    mkdir -p /etc/pki/rsyslog && chmod 01777 /etc/pki/rsyslog && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

COPY supervisord_startup.sh /usr/local/sbin/

WORKDIR /pilot
# We need an ENTRYPOINT so we can use cvmfsexec with any command (such as bash for debugging purposes)
ENTRYPOINT ["/bin/entrypoint.sh"]
# Adding ENTRYPOINT clears CMD
CMD ["/usr/local/sbin/supervisord_startup.sh"]
