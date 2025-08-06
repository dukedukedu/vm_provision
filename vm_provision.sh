#!/bin/bash

set -euo pipefail

LOG_FILE="vm_provisioning.log"
ERROR_LOG="vm_provisioning_errors.log"
> "$LOG_FILE"
> "$ERROR_LOG"

echo "Starting VM provisioning on Debian/Ubuntu..." | tee -a "$LOG_FILE"

# Function to log and display errors
log_error() {
    echo "ERROR: $1" | tee -a "$ERROR_LOG"
}

# Update and upgrade system
echo "Updating and upgrading packages..." | tee -a "$LOG_FILE"
if ! apt update -y && apt upgrade -y >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
    log_error "Failed to update and upgrade system packages."
    exit 1
fi

# Common packages to install
COMMON_PACKAGES=(
    logrotate
    cron
    msmtp
    msmtp-mta
    mailutils
    git
    jq
    gnupg
    curl
    openssl
    base64
    diffutils
)

# Install common packages
echo "Installing common packages..." | tee -a "$LOG_FILE"
for pkg in "${COMMON_PACKAGES[@]}"; do
    echo "Installing $pkg..." | tee -a "$LOG_FILE"
    if ! apt install -y "$pkg" >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        log_error "Failed to install $pkg."
    fi
done

# Detect cloud platform
echo "Detecting cloud platform..." | tee -a "$LOG_FILE"
CLOUD_PROVIDER="unknown"

if curl -s -H Metadata:true --connect-timeout 2 http://169.254.169.254/metadata/instance?api-version=2021-02-01 \
    | grep -iq "azure"; then
    CLOUD_PROVIDER="azure"
elif curl -s --connect-timeout 2 http://169.254.169.254/latest/dynamic/instance-identity/document \
    | grep -iq "amazon"; then
    CLOUD_PROVIDER="aws"
fi

echo "Detected platform: $CLOUD_PROVIDER" | tee -a "$LOG_FILE"

# Install Azure CLI
install_azcli() {
    echo "Installing Azure CLI..." | tee -a "$LOG_FILE"
    if ! curl -sL https://aka.ms/InstallAzureCLIDeb | bash >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        log_error "Failed to install Azure CLI."
    fi
}

# Install AWS CLI
install_awscli() {
    echo "Installing AWS CLI..." | tee -a "$LOG_FILE"
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    if curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
        && unzip -q awscliv2.zip \
        && ./aws/install >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        echo "AWS CLI installed." | tee -a "$LOG_FILE"
    else
        log_error "Failed to install AWS CLI."
    fi
    cd - >/dev/null
    rm -rf "$TMP_DIR"
}

# Install cloud-specific CLI
if [[ "$CLOUD_PROVIDER" == "azure" ]]; then
    install_azcli
elif [[ "$CLOUD_PROVIDER" == "aws" ]]; then
    install_awscli
else
    log_error "Could not detect cloud platform. Skipping cloud CLI installation."
fi

echo "Provisioning completed. Check '$ERROR_LOG' for any errors." | tee -a "$LOG_FILE"
