# OSGVO Pilot Container

A Docker container build emulating a worker node for the OSG VO, using token authentication.

This container embeds an OSG pilot and, if provided with valid credentials, connects to the OSG
flock pool.

In order to successfully start payload jobs:

1. Configure authentication. OSGVO administrators can provide the token, which you can then
   pass to the container by volume mounting it as a file under /etc/condor/tokens-orig.d/.
2. Set `GLIDEIN_Site` and `GLIDEIN_ResourceName` so that you get credit for the shared cycles.
3. Set the `OSG_SQUID_LOCATION` environment variable to the HTTP address to a valid Squid location.
4. Optional: Pick a directory where jobs can do I/O, and map it to /tmp inside with `-v /somelocaldir:/tmp`
   This is only required if you do not want the I/O inside the container instance.
5. Optional: add to the START expression with `GLIDEIN_Start_Extra`. This is useful to limit
   the pilot to only run certain jobs.

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
singularity run --contain --bind /cvmfs docker://opensciencegrid/osgvo-docker-pilot

```

If you are planning on running a lot of these jobs, you can download the Docker
container once, and create a local Singularity image to use in that last
singularity command instead of the docker:// URL. Example:

```
$ singularity build osgvo-pilot.sif docker://opensciencegrid/osgvo-docker-pilot
```



