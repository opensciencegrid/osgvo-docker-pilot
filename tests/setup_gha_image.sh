#!/bin/bash -x

function install_apptainer {
    # https://apptainer.org/docs/admin/main/installation.html#install-ubuntu-packages
    apt -y update
    apt install -y software-properties-common
    add-apt-repository -y ppa:apptainer/ppa
    apt -y update
    apt install -y apptainer
}

install_apptainer
