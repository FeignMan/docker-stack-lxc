#!/bin/bash
set -e

if command -v docker &> /dev/null; then
    echo "Docker is already installed."
    exit 0
fi

# Uninstall conflicting packages
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do 
    sudo apt-get remove "$pkg"
done

# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install -yqq ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

DOCKER_VERSION=$(apt-cache madison docker-ce | awk '{ print $3 }' | fzf --prompt="Select Docker version: " | head -n 1)
if [ -z "$DOCKER_VERSION" ]; then
    echo "No Docker version selected. Exiting."
    exit 1
fi
# Install Docker
sudo apt-get install -yqq docker-ce=$DOCKER_VERSION docker-ce-cli=$DOCKER_VERSION containerd.io docker-buildx-plugin docker-compose-plugin
# Enable and start Docker service
sudo systemctl enable docker
sudo systemctl start docker
# Add current user to the docker group
sudo usermod -aG docker $USER
echo "Docker installation completed. Please log out and log back in to apply group changes."
echo "You can verify the installation by running 'docker --version'."
