# OSGVO Pilot Container

A Docker container build emulating a worker node for the OSG VO, using token authentication.

This container embeds an OSG pilot and, if provided with valid credentials, connects to the OSG
flock pool.

In order to successfully start payload jobs:

1. Configure authentication. OSGVO administrators can provide the token, which you can then
   pass to the container by volume mounting it as a file under /etc/condor/tokens-orig.d/.
2. Set `GLIDEIN_Site` and `GLIDEIN_ResourceName` so that you get credit for the shared cycles.
3. Set the `OSG_SQUID_LOCATION` environment variable to the HTTP address to a valid Squid location.
4. Optional: Pick a directory where jobs can do I/O, and map it to `/pilot` inside with
   `-v /somelocaldir:/pilot`
   This is only required if you do not want the I/O inside the container instance.
5. Optional: add to the START expression with `GLIDEIN_Start_Extra`. This is useful to limit
   the pilot to only run certain jobs.

In addition, you will be able to run more OSG jobs if you provide CVMFS.  You can do this
in two ways:

1. Mount CVMFS on the host and bind-mount it into the container by adding `-v /cvmfs:/cvmfs`.
   This is the preferred mechanism.
2. Use cvmfsexec as described in [the cvmfsexec section below](#cvmfs-without-a-bind-mount-using-cvmfsexec).

Example invocation utilizing a token for authentication:

```
docker run -it --rm --user osg \
       --cap-add=DAC_OVERRIDE --cap-add=SETUID --cap-add=SETGID \
       --cap-add=CAP_DAC_READ_SEARCH \
       --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=SYS_PTRACE \
       -v /cvmfs:/cvmfs:shared \
       -v /path/to/token:/etc/condor/tokens-orig.d/flock.opensciencegrid.org
       -e GLIDEIN_Site="..." \
       -e GLIDEIN_ResourceName="..." \
       -e GLIDEIN_Start_Extra="True" \
       -e OSG_SQUID_LOCATION="..." \
       opensciencegrid/osgvo-docker-pilot:latest
```

## Singularity / Bring Your Own Resources

This container can also be used by users who want to use non-OSG resources for their
computations, such as campus clusters or clusters with user specific allocations. The
example below is a generic Slurm/Singularity example, but can be modified for other
schedulers. You still need to request a token from OSG staff.

Jobs should be requesting single full nodes. If your compute nodes have 24 nodes,
the submit file should look something like:

```
#!/bin/bash
#SBATCH --job-name=osg-glidein
#SBATCH -p compute
#SBATCH -N 1
#SBATCH -n 24
#SBATCH -t 48:00:00
#SBATCH --output=osg-glidein-%j.log

export TOKEN="put_your_provided_token_here"

# Set this so that the OSG accouting knows where the jobs ran
export GLIDEIN_Site="SDSC"
export GLIDEIN_ResourceName="Comet"

# This is an important setting limiting what jobs your glideins will accept.
# At the minimum, the expression should limit the "Owner" of the jobs to 
# whatever your username is on the OSG _submit_ side
export GLIDEIN_Start_Extra="Owner == \"my_osgconnect_username\""

module load singularity
singularity run --contain --bind /cvmfs --scratch /pilot docker://opensciencegrid/osgvo-docker-pilot

```

If you are planning on running a lot of these jobs, you can download the Docker
container once, and create a local Singularity image to use in that last
singularity command instead of the docker:// URL. Example:

```
$ singularity build osgvo-pilot.sif docker://opensciencegrid/osgvo-docker-pilot
```


## CVMFS Without a Bind-Mount Using cvmfsexec

If you don't have CVMFS available on the host, the container can still make
CVMFS available by using [cvmfsexec](https://github.com/cvmfs/cvmfsexec#readme).

You will need to specify a list of CVMFS repos to mount in the environment
variable `CVMFSEXEC_REPOS`.
This will require a kernel version >= 3.10.0-1127 on an EL7-compatible host
with user namespaces enabled or >= 4.18 on an EL8-compatible host --
see the cvmfsexec README linked above for details.

This will also require granting the container some additional privileges, which
you can do in one of two ways:

1.  Add `--privileged` to the `docker run` invocation.

2.  Add
    `--security-opt seccomp=unconfined --security-opt systempaths=unconfined --device=/dev/fuse`
    to the `docker run` invocation.

The second option will add only the minimum necessary privileges for cvmfsexec.
You can add additional security to that option by also adding `--security-opt no-new-privileges`.
If cvmfsexec does not have the required privileges, the container will fail.

Note that cvmfsexec will not be run if CVMFS repos are already available in
`/cvmfs` via bind-mount.

Using cvmfsexec takes place in the entrypoint, which means it will still happen
even if you specify a different command to run, such as `bash`.  You can bypass
the entrypoint by passing `--entrypoint <cmd>` where `<cmd>` is some different
command to run, e.g. `--entrypoint bash`.  Setting the entrypoint this way
clears the command.

There are several environment variables you can set for cvmfsexec:

-   `CVMFSEXEC_REPOS` - this is a comma-separated list of CVMFS repos to mount,
    if using cvmfsexec; leave this blank to disable cvmfsexec.
    OSG jobs frequently use the OASIS repo (`oasis.opensciencegrid.org`).

-   `CVMFS_HTTP_PROXY` - this sets the proxy to use for CVMFS; if left blank
    it will find the best one via WLCG Web Proxy Auto Discovery.

-   `CVMFS_QUOTA_LIMIT` - the quota limit in MB for CVMFS; leave this blank to
    use the system default (4 GB)


You can store the cache outside of the container by bind-mounting a directory
to `/cvmfs-cache`.
You can store the logs outside of the container by bind-mounting a directory to
`/cvmfs-logs`.


Here is an example invocation using a token for authentication, using cvmfsexec
to mount the OASIS repos instead of bind-mounting `/cvmfs`, sending the cache
to `/var/cache/cvmfsexec` and the logs to `/var/log/cvmfsexec`:

```
docker run -it --rm --user osg \
       --cap-add=DAC_OVERRIDE --cap-add=SETUID --cap-add=SETGID \
       --cap-add=CAP_DAC_READ_SEARCH \
       --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=SYS_PTRACE \
       --security-opt seccomp=unconfined \
       --security-opt systempaths=unconfined \
       --device=/dev/fuse \
       -v /var/cache/cvmfsexec:/cvmfsexec-cache \
       -v /var/log/cvmfsexec:/cvmfsexec-logs \
       -e TOKEN="..." \
       -e GLIDEIN_Site="..." \
       -e GLIDEIN_ResourceName="..." \
       -e GLIDEIN_Start_Extra="True" \
       -e OSG_SQUID_LOCATION="..." \
       -e CVMFSEXEC_REPOS=oasis.opensciencegrid.org \
       opensciencegrid/osgvo-docker-pilot:latest
```

