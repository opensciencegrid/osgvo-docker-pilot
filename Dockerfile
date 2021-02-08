FROM opensciencegrid/osg-wn

ARG BASE_YUM_REPO=testing

# token auth require HTCondor 8.9.x
RUN useradd osg \
 && if [[ $BASE_YUM_REPO = release ]]; then \
       yumrepo=osg-upcoming; else \
       yumrepo=osg-upcoming-$BASE_YUM_REPO; fi \
 && mkdir -p ~osg/.condor \
 && yum -y --enablerepo=$yumrepo install condor \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d \
 && curl -s -o /usr/sbin/osgvo-user-job-wrapper https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/job-wrappers/user-job-wrapper.sh \
 && curl -s -o /usr/sbin/osgvo-node-advertise https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/osgvo-node-advertise \
 && chmod 755 /usr/sbin/osgvo-user-job-wrapper /usr/sbin/osgvo-node-advertise

COPY entrypoint.sh /bin/
COPY 50-main.config /etc/condor/config.d/
RUN chmod 755 /bin/entrypoint.sh
 
RUN chown -R osg: ~osg 

ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini.asc /tini.asc
RUN gpg --batch --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 595E85A6B1B4779EA4DAAEC70B588DFF0527A9B7 \
 && gpg --batch --verify /tini.asc /tini \
 && chmod +x /tini

ENTRYPOINT ["/tini", "/bin/entrypoint.sh"]

