ARG BASE_YUM_REPO=testing

FROM alpine:latest AS compile
COPY launch_rsyslogd.c /tmp/launch_rsyslogd.c
RUN apk --no-cache add gcc musl-dev && \
 cc -static -o /launch_rsyslogd /tmp/launch_rsyslogd.c && \
 strip /launch_rsyslogd

FROM opensciencegrid/software-base:3.6-el7-${BASE_YUM_REPO}

# Previous arg has gone out of scope
ARG BASE_YUM_REPO=testing
ARG TIMESTAMP

# token auth require HTCondor 8.9.x
RUN useradd osg \
 && mkdir -p ~osg/.condor \
 && yum -y install \
        condor \
        osg-wn-client \
        redhat-lsb-core \
        singularity \
        attr \
        git \
        rsyslog rsyslog-gnutls python36-cryptography python36-requests \
        bind-utils \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d

# Specify RANDOM when building the image to use the cache for installing RPMs but not for downloading scripts.
ARG RANDOM=

# glideinwms
RUN mkdir -p /gwms/main /gwms/client /gwms/client_group_main /gwms/.gwms.d/bin /gwms/.gwms.d/exec/{cleanup,postjob,prejob,setup,setup_singularity} \
 && curl -sSfL -o /gwms/error_gen.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/error_gen.sh \
 && curl -sSfL -o /gwms/add_config_line.source https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/add_config_line.source \
 && curl -sSfL -o /gwms/.gwms.d/exec/prejob/setup_prejob.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/setup_prejob.sh \
 && curl -sSfL -o /gwms/main/singularity_setup.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_setup.sh \
 && curl -sSfL -o /gwms/main/singularity_wrapper.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_wrapper.sh \
 && curl -sSfL -o /gwms/main/singularity_lib.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_lib.sh \
 && chmod 755 /gwms/*.sh /gwms/main/*.sh

# osgvo scripts
# Set ITB to use itb versions of all the pilot scripts and join the ITB pool
ARG ITB=
# Specify the branch and fork of the opensciencegrid/osg-flock repo to get the pilot scripts from
ARG OSG_FLOCK_REPO=opensciencegrid/osg-flock
ARG OSG_FLOCK_BRANCH=master
RUN git clone --branch ${OSG_FLOCK_BRANCH} https://github.com/${OSG_FLOCK_REPO} osg-flock \
 && cd osg-flock \
 && install node-check/${ITB:+itb-}osgvo-default-image                  /usr/sbin/osgvo-default-image \
 && install node-check/${ITB:+itb-}osgvo-advertise-base                 /usr/sbin/osgvo-advertise-base \
 && install node-check/${ITB:+itb-}osgvo-advertise-userenv              /usr/sbin/osgvo-advertise-userenv \
 && install job-wrappers/${ITB:+itb-}default_singularity_wrapper.sh     /usr/sbin/osgvo-singularity-wrapper \
 && install node-check/${ITB:+itb-}ospool-lib                           /gwms/client_group_main/ospool-lib \
 && install node-check/${ITB:+itb-}singularity-extras                   /gwms/client_group_main/singularity-extras \
 && install stashcp/stashcp                                             /gwms/client/stashcp \
 && install stashcp/stashcp                                             /usr/libexec/condor/stash_plugin \
 && ln -s   /gwms/client/stashcp                                        /usr/bin/stashcp \
 && echo "OSG_FLOCK_REPO = \"$OSG_FLOCK_REPO\""        >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_BRANCH = \"$OSG_FLOCK_BRANCH\""    >> /etc/condor/config.d/60-flock-sources.config \
 && echo "OSG_FLOCK_HASH = \"$(git rev-parse HEAD)\""  >> /etc/condor/config.d/60-flock-sources.config \
 && echo "STARTD_ATTRS = \$(STARTD_ATTRS) OSG_FLOCK_REPO OSG_FLOCK_BRANCH OSG_FLOCK_HASH"  >> /etc/condor/config.d/60-flock-sources.config \
 && cd .. && rm -rf osg-flock

COPY condor_master_wrapper /usr/sbin/
RUN chmod 755 /usr/sbin/condor_master_wrapper

# Override the software-base supervisord.conf to throw away supervisord logs
COPY supervisord.conf /etc/supervisord.conf

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

RUN if [[ -n $TIMESTAMP ]]; then \
       tag=opensciencegrid/osgvo-docker-pilot:${BASE_YUM_REPO}${ITB+-itb}-${TIMESTAMP}; \
    else \
       tag=; \
    fi; \
    sed -i "s|@CONTAINER_TAG@|$tag|" \
           /etc/condor/config.d/50-main.config

RUN \
    if [[ -n $ITB ]]; then \
        # Set the default pool to ITB, but allow turning off with -e ITBPOOL=0
        echo 'export ITBPOOL=${ITBPOOL:-1}' > /etc/osg/image-init.d/01-itb.sh; \
        echo 'Is_ITB_Site = True'  >> /etc/condor/config.d/55-itb.config; \
        echo 'STARTD_ATTRS = $(STARTD_ATTRS) Is_ITB_Site'  >> /etc/condor/config.d/55-itb.config; \
        echo 'START = $(START) && (TARGET.ITB_Sites =?= True)'  >> /etc/condor/config.d/55-itb.config; \
    fi

RUN chown -R osg: ~osg 

RUN mkdir -p /pilot && chmod 1777 /pilot

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
