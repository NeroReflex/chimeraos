#!/bin/bash

set -e

# Function to handle errors
error_handler() {
    local lineno=$1
    local msg=$2
    echo "Error occurred at line ${lineno}: ${msg}"
}

# Set the trap to call the error_handler function on ERR
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

if [ "$EUID" -ne 0 ]
    then echo "This script MUST be run as root"
    exit
fi

echo "Setting up autologin for first boot..."

# TODO: do actions here

echo "Done."
