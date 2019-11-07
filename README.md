# OSGVO Pilot Container

A Docker container build emulating a worker node for the OSG VO, using token authentication.

This container embeds an OSG pilot and, if provided with valid credentials, connects to the OSG
flock pool.

In order to successfully start payload jobs:

1. Configure authentication. OSGVO administrators can provide the token, which you can then
   pass to the container via the `TOKEN` environment variable.
2. Set `GLIDEIN_Site` and `GLIDEIN_ResourceName` so that you get credit for the shared cycles.
3. Set the `OSG_SQUID_LOCATION` environment variable to the HTTP address to a valid Squid location.
4. Optional: Pick a directory where jobs can do I/O, and map it to /tmp inside with `-v /somelocaldir:/tmp`
   This is only required if you do not want the I/O inside the container instance.

Example invocation utilizing a grid proxy:

```
docker run -it --rm --user osg \
       --cap-add=DAC_OVERRIDE --cap-add=SETUID --cap-add=SETGID \
       --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=SYS_PTRACE \
       -v /cvmfs:/cvmfs \
       -e TOKEN="..." \
       -e GLIDEIN_Site="..." \
       -e GLIDEIN_ResourceName="..." \
       -e OSG_SQUID_LOCATION="..." \
       opensciencegrid/osgvo-docker-pilot:latest
```


