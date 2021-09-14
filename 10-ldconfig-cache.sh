#!/bin/bash

# Rebuild the ld.so cache for Singularity child containers (SOFTWARE-4807)
ldconfig "$LD_LIBRARY_PATH"
