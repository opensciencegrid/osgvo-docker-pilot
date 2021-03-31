ARG BASE_YUM_REPO=testing

FROM opensciencegrid/software-base:3.5-el7-${BASE_YUM_REPO}

# Previous arg has gone out of scope
ARG BASE_YUM_REPO=testing

# token auth require HTCondor 8.9.x
RUN useradd osg \
 && if [[ $BASE_YUM_REPO = release ]]; then \
       yumrepo=osg-upcoming; else \
       yumrepo=osg-upcoming-$BASE_YUM_REPO; fi \
 && mkdir -p ~osg/.condor \
 && yum -y --enablerepo=$yumrepo install \
        condor \
        osg-wn-client \
        redhat-lsb-core \
        singularity \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d \
 && curl -s -o /usr/sbin/osgvo-user-job-wrapper https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/job-wrappers/user-job-wrapper.sh \
 && curl -s -o /usr/sbin/osgvo-node-advertise https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/osgvo-node-advertise \
 && chmod 755 /usr/sbin/osgvo-user-job-wrapper /usr/sbin/osgvo-node-advertise

COPY condor_master_wrapper /usr/sbin/
RUN chmod 755 /usr/sbin/condor_master_wrapper

# Override the software-base supervisord.conf to throw away supervisord logs
COPY supervisord.conf /etc/supervisord.conf
COPY 10-setup-htcondor.sh /etc/osg/image-init.d/
COPY 10-cleanup-htcondor.sh /etc/osg/image-cleanup.d/
COPY 10-htcondor.conf /etc/supervisord.d/
COPY 50-main.config /etc/condor/config.d/
 
RUN chown -R osg: ~osg 

WORKDIR /tmp
