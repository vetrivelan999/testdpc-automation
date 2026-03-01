#!/bin/bash

# setup_ubuntu.sh - One-time environment setup for building android-testdpc
# Run this script on a fresh Ubuntu 22.04 or 24.04 system
# Usage: sudo ./setup_ubuntu.sh

set -e

echo "=========================================="
echo "Setting up Ubuntu for android-testdpc build"
echo "=========================================="

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo ./setup_ubuntu.sh"
    exit 1
fi

# Detect Ubuntu version
if command -v lsb_release &> /dev/null; then
    UBUNTU_VERSION=$(lsb_release -rs)
    echo "Detected Ubuntu version: $UBUNTU_VERSION"
else
    # Fallback: check /etc/os-release
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        UBUNTU_VERSION="${VERSION_ID}"
        echo "Detected OS version: $UBUNTU_VERSION"
    else
        echo "Warning: Could not detect OS version, proceeding anyway"
    fi
fi

# Update package lists
echo "[1/7] Updating package lists..."
apt-get update -y

# Install basic dependencies
echo "[2/7] Installing basic dependencies..."
apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    zip \
    ed \
    openssl \
    xz-utils \
    python3 \
    qrencode \
    build-essential

# Install OpenJDK 21 (required for Bazel 7.4.1+)
echo "[3/7] Installing OpenJDK 21..."
apt-get install -y openjdk-21-jdk

# Set JAVA_HOME based on architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
    echo "export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64" >> /etc/profile.d/java.sh
else
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
    echo "export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64" >> /etc/profile.d/java.sh
fi
echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /etc/profile.d/java.sh
source /etc/profile.d/java.sh

# Install Bazel
echo "[4/7] Installing Bazel..."
apt-get install -y apt-transport-https curl gnupg

# Install Bazel 7.4.1 (version required by android-testdpc)
BAZEL_VERSION="7.4.1"
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    # ARM64 - download Bazel binary directly
    curl -fsSL "https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel_nojdk-${BAZEL_VERSION}-linux-arm64" -o /usr/local/bin/bazel
    chmod +x /usr/local/bin/bazel
else
    # AMD64 - install specific version from apt
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/bazel.gpg
    echo "deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8" | tee /etc/apt/sources.list.d/bazel.list
    apt-get update -y
    apt-get install -y bazel-${BAZEL_VERSION}
    # Create symlink
    ln -sf /usr/bin/bazel-${BAZEL_VERSION} /usr/local/bin/bazel
fi

# Install Android SDK
echo "[5/7] Installing Android SDK..."
ANDROID_SDK_ROOT=/opt/android-sdk
mkdir -p $ANDROID_SDK_ROOT
cd $ANDROID_SDK_ROOT

# Download command-line tools (version 9477386 works reliably)
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip"
curl -L -o cmdline-tools.zip "$CMDLINE_TOOLS_URL"
unzip -q cmdline-tools.zip
rm cmdline-tools.zip

# Move to correct directory structure
mkdir -p cmdline-tools/latest
mv cmdline-tools/bin cmdline-tools/lib cmdline-tools/NOTICE.txt cmdline-tools/source.properties cmdline-tools/latest/ 2>/dev/null || true

# Set ANDROID_HOME
export ANDROID_HOME=$ANDROID_SDK_ROOT
export ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT
echo "export ANDROID_HOME=$ANDROID_SDK_ROOT" >> /etc/profile.d/android.sh
echo "export ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT" >> /etc/profile.d/android.sh
echo "export PATH=\$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH" >> /etc/profile.d/android.sh
echo "export PATH=\$ANDROID_HOME/platform-tools:\$PATH" >> /etc/profile.d/android.sh
source /etc/profile.d/android.sh

# Accept SDK licenses
echo "[6/7] Accepting Android SDK licenses..."
yes | sdkmanager --licenses > /dev/null 2>&1 || true

# Install required SDK packages
echo "[7/7] Installing Android SDK Platform 34 and 35..."
sdkmanager "platforms;android-34" "platforms;android-35" "build-tools;34.0.0" "build-tools;35.0.0"

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Environment variables set:"
echo "  JAVA_HOME=$JAVA_HOME"
echo "  ANDROID_HOME=$ANDROID_HOME"
echo ""
echo "Please run: source /etc/profile.d/android.sh && source /etc/profile.d/java.sh"
echo "Or start a new shell session to load environment variables."
echo ""
