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
6. Optional: cap the system resources available to jobs (described in the
   [limiting resource usage section below](#limiting-resource-usage)).

In addition, you will be able to run more OSG jobs if you provide CVMFS.  You can do this
in two ways:

1. Mount CVMFS on the host and bind-mount it into the container by adding `-v /cvmfs:/cvmfs:shared`.
   This is the preferred mechanism.
2. Use cvmfsexec as described in [the cvmfsexec section below](#cvmfs-without-a-bind-mount-using-cvmfsexec).

Note: Supporting Singularity jobs inside the container will require the capabilities
`DAC_OVERRIDE`, `DAC_READ_SEARCH`, `SETGID`, `SETUID`, `SYS_ADMIN`, `SYS_CHROOT`, and `SYS_PTRACE`.

Example invocation utilizing a token for authentication and bind-mounting CVMFS:

```
docker run -it --rm --user osg \
       --cap-add=DAC_OVERRIDE --cap-add=SETUID --cap-add=SETGID \
       --cap-add=DAC_READ_SEARCH \
       --cap-add=SYS_ADMIN --cap-add=SYS_CHROOT --cap-add=SYS_PTRACE \
       -v /cvmfs:/cvmfs:shared \
       -v /path/to/token:/etc/condor/tokens-orig.d/flock.opensciencegrid.org \
       -e GLIDEIN_Site="..." \
       -e GLIDEIN_ResourceName="..." \
       -e GLIDEIN_Start_Extra="True" \
       -e OSG_SQUID_LOCATION="..." \
       opensciencegrid/osgvo-docker-pilot:release
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

On EL7, you must have kernel version >= 3.10.0-1127 (run `rpm -q kernel` to check),
and user namespaces enabled.  See step 1 in the
[Singularity Install document](https://opensciencegrid.org/docs/worker-node/install-singularity/#enabling-unprivileged-singularity)
for details.

On EL8, you must have kernel version >= 4.18.
See the [cvmfsexec README](https://github.com/cvmfs/cvmfsexec#readme) details.

Note that cvmfsexec will not be run if CVMFS repos are already available in
`/cvmfs` via bind-mount.

Using cvmfsexec takes place in the entrypoint, which means it will still happen
even if you specify a different command to run, such as `bash`.  You can bypass
the entrypoint by passing `--entrypoint <cmd>` where `<cmd>` is some different
command to run, e.g. `--entrypoint bash`.  Setting the entrypoint this way
clears the command.

There are several environment variables you can set for cvmfsexec:

-   `CVMFSEXEC_REPOS` - this is a space-separated list of CVMFS repos to mount,
    if using cvmfsexec; leave this blank to disable cvmfsexec.
    OSG jobs frequently use the OASIS repo (`oasis.opensciencegrid.org`) and
    the singularity repo (`singularity.opensciencegrid.org`).

-   `CVMFS_HTTP_PROXY` - this sets the proxy to use for CVMFS; if left blank
    it will find the best one via WLCG Web Proxy Auto Discovery.

-   `CVMFS_QUOTA_LIMIT` - the quota limit in MB for CVMFS; leave this blank to
    use the system default (4 GB)

You can add other CVMFS options by bind-mounting a config file over
`/cvmfsexec/default.local`; note that options in environment variables are preferred
over options in `/cvmfsexec/default.local`.

You can store the cache outside of the container by bind-mounting a directory
to `/cvmfs-cache`.
You can store the logs outside of the container by bind-mounting a directory to
`/cvmfs-logs`.

cvmfsexec requires the additional options `--device=/dev/fuse` and
`--security-opt=seccomp=unconfined`.  Supporting Singularity jobs when using
cvmfsexec requires privileged containers (`--privileged`).  Using privileged
containers avoids the need for those two additional options and all the
`--cap-add` options without adding much risk, so it is recommended.

The following example invocation will:
-   Use a token for authentication
-   Use cvmfsexec to mount the OASIS and Singularity CVMFS repos
-   Use `/var/cache/cvmfsexec` on the host for the CVMFS cache
-   Use `/var/log/cvmfsexec` on the host for the CVMFS logs
-   Support Singularity jobs

```
docker run -it --rm --user osg \
       --privileged \
       -v /var/cache/cvmfsexec:/cvmfsexec-cache \
       -v /var/log/cvmfsexec:/cvmfsexec-logs \
       -v /path/to/token:/etc/condor/tokens-orig.d/flock.opensciencegrid.org \
       -e GLIDEIN_Site="..." \
       -e GLIDEIN_ResourceName="..." \
       -e GLIDEIN_Start_Extra="True" \
       -e OSG_SQUID_LOCATION="..." \
       -e CVMFSEXEC_REPOS="oasis.opensciencegrid.org \
                           singularity.opensciencegrid.org" \
       opensciencegrid/osgvo-docker-pilot:release
```


## Limiting Resource Usage

By default, the OSG pilot container will allow jobs to utilize the entire
node's resources (CPUs, memory).  If you don't want to allow jobs
to use all of these, you can specify limits.

You must specify limits in two places:

-   As environment variables, limiting the resources HTCondor offers to jobs.

-   As options to the `docker run` command, limiting the resources the pilot
    container can use.

### Limiting CPUs

To limit the number of CPUs available to jobs (thus limiting the number of
simultaneous jobs), add the following to your `docker run` command:

```
   -e NUM_CPUS=<X>  --cpus=<X> \
```
where `<X>` is the number of CPUs you want to allow jobs to use.

The `NUM_CPUS` environment variable will tell HTCondor not to offer more
than the given number of CPUs to jobs; the `--cpus` argument will tell
Docker not to allocate more than the given number of CPUs to the container.

Both options are necessary for optimal behavior.


### Limiting memory

To limit the total amount of memory available to jobs, add the following to
your `docker run` command:

```
    -e MEMORY=<X> --memory=$(( (<X> + 100) * 1024 * 1024 )) \
```
where `<X>` is the total amount of memory (in MB) you want to allow jobs to use.

Both options are necessary for optimal behavior.
Note that the above command will allocate 100 MB more memory to the container;
the reasons are detailed below.

The `MEMORY` environment variable will tell HTCondor not to offer more
than the given amount of memory to jobs; the `--memory` argument will tell
Docker to kill the container if its total memory usage exceeds the given number.

HTCondor will place jobs on hold if they exceed their requested memory, but it
may not notice high memory usage immediately.  In addition, non-job processes
(such as HTCondor and crond) also use some amount of memory.  Therefore it is
important to give the container some extra room.
