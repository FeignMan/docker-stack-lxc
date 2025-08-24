#!/bin/bash

# This script generates a hashed password using Authelia's Docker image.
usage() {
    echo "Usage: $0"
    echo "This script generates a hashed password using Authelia's Docker image."
    echo "You will be prompted to enter a password."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

echo -n "Enter password: "
read -s password
echo
echo -n "Confirm password: "
read -s confirm_password
echo

if [[ "$password" != "$confirm_password" ]]; then
    echo "Passwords do not match. Exiting."
    exit 1
elif [[ -z "$password" ]]; then
    echo "Password cannot be empty. Exiting."
    exit 1
else
    echo -e "\nGenerating hashed password..."
fi
echo

docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$password"
