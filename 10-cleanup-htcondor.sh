#!/bin/bash

LOCAL_DIR=$(condor_config_val LOCAL_DIR)

[[ -d "$LOCAL_DIR" ]] && rm -rf "$LOCAL_DIR"
