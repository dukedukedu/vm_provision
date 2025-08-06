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
    debconf-utils
    logrotate
    cron
    msmtp
    msmtp-mta
    mailutils
    git
    jq
    gnupg
    openssl
    diffutils
    unzip
)

MSMTP_INSTALLED=false

# Install common packages
echo "Installing common packages..." | tee -a "$LOG_FILE"
apt update
for pkg in "${COMMON_PACKAGES[@]}"; do
    echo "Installing $pkg..." | tee -a "$LOG_FILE"
    if apt install -y "$pkg" >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        log_package_config "$pkg"

        if [[ "$pkg" == "msmtp" ]]; then
            MSMTP_INSTALLED=true
        fi
    else
        log_error "Failed to install $pkg."
    fi
done

# Detect cloud platform
echo "Detecting cloud platform..." | tee -a "$LOG_FILE"

detect_platform() {
    # Try AWS IMDSv2
    if TOKEN=$(curl -s --fail --connect-timeout 1 -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); then

        if curl -s --fail --connect-timeout 1 \
            -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/ >/dev/null; then
            echo "aws"
            return
        fi
    fi

    # Fallback to AWS IMDSv1
    if curl -s --fail --connect-timeout 1 \
         http://169.254.169.254/latest/meta-data/ >/dev/null; then
        echo "aws"
        return
    fi

    # Try Azure
    if curl -s --fail -H "Metadata:true" --connect-timeout 1 \
         "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
         -o /dev/null; then
        echo "azure"
        return
    fi

    echo "unknown"
    return
}

# Capture and sanitize platform detection
PLATFORM=$(detect_platform 2>/dev/null | head -n1 | tr -d '\r\n')
echo "Detected platform: $PLATFORM" | tee -a "$LOG_FILE"

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

    if command -v aws >/dev/null 2>&1; then
        echo "AWS CLI is already installed. Skipping." | tee -a "$LOG_FILE"
        return
    fi

    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    if curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
        && unzip -q awscliv2.zip \
        && ./aws/install >> "$LOG_FILE" 2>>"$ERROR_LOG"; then
        echo "AWS CLI installed." | tee -a "$LOG_FILE"
    else
        log_error "Failed to install AWS CLI."
    fi
    rm -rf "$TMP_DIR"
}

# Install cloud-specific CLI
if [[ "$PLATFORM" == "azure" ]]; then
    install_azcli
elif [[ "$PLATFORM" == "aws" ]]; then
    install_awscli
else
    log_error "Could not detect cloud platform. Skipping cloud CLI installation."
fi

# Colors
YELLOW="\033[1;33m"
RESET="\033[0m"

if [[ "$MSMTP_INSTALLED" == "true" && ! -f /etc/msmtprc ]]; then
    echo -e "${YELLOW}NOTE: Don't forget to manually configure /etc/msmtprc${RESET}"
    echo "NOTE: Don't forget to manually configure /etc/msmtprc" >> "$LOG_FILE"
fi

echo "Provisioning completed. Check '$LOG_FILE' for details and '$ERROR_LOG' for any issues." | tee -a "$LOG_FILE"
