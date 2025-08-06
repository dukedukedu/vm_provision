#!/bin/bash

set -euo pipefail

LOG_FILE="vm_provisioning.log"
ERROR_LOG="vm_provisioning_errors.log"
> "$LOG_FILE"
> "$ERROR_LOG"

# Force non-interactive installs
export DEBIAN_FRONTEND=noninteractive

echo "Starting VM provisioning on Debian/Ubuntu..." | tee -a "$LOG_FILE"

# Function to log and display errors
log_error() {
    echo "ERROR: $1" | tee -a "$ERROR_LOG"
}

# Function to log debconf config used by each package
log_package_config() {
    local pkg=$1
    echo "== Debconf selections for $pkg ==" >> "$LOG_FILE"
    if debconf-get-selections | grep "^$pkg" >> "$LOG_FILE"; then
        echo "✓ Debconf selections found for $pkg" >> "$LOG_FILE"
    else
        echo "No debconf selections found for $pkg (likely no prompts or defaults used)." >> "$LOG_FILE"
    fi
    echo "" >> "$LOG_FILE"
}

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
    diffutils
    unzip
)

# Install common packages
echo "Installing common packages..." | tee -a "$LOG_FILE"
for pkg in "${COMMON_PACKAGES[@]}"; do
    echo "Installing $pkg..." | tee -a "$LOG_FILE"
    if apt install -y "$pkg" >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        log_package_config "$pkg"
    else
        log_error "Failed to install $pkg."
    fi
done

# Detect cloud platform
echo "Detecting cloud platform..." | tee -a "$LOG_FILE"
CLOUD_PROVIDER="unknown"

CLOUD_PROVIDER="unknown"

# Try Azure first
if curl -s -H Metadata:true --connect-timeout 2 \
    "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
    | grep -iq "azure"; then
    CLOUD_PROVIDER="azure"

# Then try AWS (IMDSv2 with fallback to IMDSv1)
else
    TOKEN=$(curl -s --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

    if [[ -n "$TOKEN" ]]; then
        METADATA=$(curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/dynamic/instance-identity/document)

        if echo "$METADATA" | grep -q '"instanceId"' && echo "$METADATA" | grep -q '"region"'; then
            CLOUD_PROVIDER="aws"
        fi
    else
        # Try IMDSv1 as fallback
        METADATA=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/dynamic/instance-identity/document)

        if echo "$METADATA" | grep -q '"instanceId"' && echo "$METADATA" | grep -q '"region"'; then
            CLOUD_PROVIDER="aws"
        fi
    fi
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

echo "Provisioning completed. Check '$LOG_FILE' for details and '$ERROR_LOG' for any issues." | tee -a "$LOG_FILE"
