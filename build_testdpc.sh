#!/bin/bash

# build_testdpc.sh - Automated build script for android-testdpc
# Builds APK and generates provisioning data for QR code setup
#
# Usage: ./build_testdpc.sh <path-to-repo.zip|path-to-repo-dir> [output-dir]
#
# Outputs:
#   - APK file ready for installation
#   - Admin component name
#   - Signature checksum for QR provisioning
#   - provisioning.json with all QR code data

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${2:-$SCRIPT_DIR/output}"
WORK_DIR="$SCRIPT_DIR/build_workspace"

# Print colored message
print_msg() {
    echo -e "${2}${1}${NC}"
}

# Print error and exit
error_exit() {
    print_msg "ERROR: $1" "$RED"
    exit 1
}

# Check required dependencies
check_dependencies() {
    print_msg "Checking dependencies..." "$BLUE"
    
    local missing=()
    
    # Check for required tools
    for cmd in bazel unzip openssl base64 keytool; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    # Check for ed (required for setupcompat patching)
    if ! command -v ed &> /dev/null; then
        missing+=("ed")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        error_exit "Missing dependencies: ${missing[*]}. Run setup_ubuntu.sh first or install manually."
    fi
    
    # Check ANDROID_HOME
    if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
        error_exit "ANDROID_HOME or ANDROID_SDK_ROOT not set. Please set Android SDK path."
    fi
    
    # Use ANDROID_SDK_ROOT if ANDROID_HOME not set
    export ANDROID_HOME=${ANDROID_HOME:-$ANDROID_SDK_ROOT}
    
    print_msg "All dependencies satisfied." "$GREEN"
}

# Extract repository from zip or use existing directory
extract_repo() {
    local input="$1"
    
    print_msg "Processing input: $input" "$BLUE"
    
    # Clean work directory
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    if [[ "$input" == *.zip ]]; then
        # Extract zip file
        print_msg "Extracting zip archive..." "$BLUE"
        unzip -q "$input" -d "$WORK_DIR"
        
        # Find the extracted directory (might be nested)
        REPO_DIR=$(find "$WORK_DIR" -maxdepth 2 -name "BUILD" -type f | head -1 | xargs dirname)
        
        if [ -z "$REPO_DIR" ]; then
            error_exit "Could not find BUILD file in extracted archive. Invalid repository?"
        fi
    elif [ -d "$input" ]; then
        # Use existing directory
        print_msg "Using existing repository directory..." "$BLUE"
        REPO_DIR="$input"
    else
        error_exit "Input must be a .zip file or existing directory: $input"
    fi
    
    # Validate repository structure
    if [ ! -f "$REPO_DIR/BUILD" ] || [ ! -f "$REPO_DIR/WORKSPACE" ]; then
        error_exit "Invalid repository: Missing BUILD or WORKSPACE file"
    fi
    
    print_msg "Repository ready at: $REPO_DIR" "$GREEN"
}

# Build APK with Bazel
build_apk() {
    print_msg "Building APK with Bazel..." "$BLUE"
    print_msg "This may take several minutes on first build..." "$YELLOW"
    
    cd "$REPO_DIR"
    
    # Build the testdpc target
    bazel build testdpc
    
    # Get the actual bazel-bin path (handles symlinks)
    local bazel_bin=$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")
    
    # Locate the output APK using absolute path
    APK_PATH="$(cd "$bazel_bin" && pwd)/testdpc.apk"
    
    if [ ! -f "$APK_PATH" ]; then
        # Try alternative location
        APK_PATH="$(cd "$bazel_bin" && pwd)/testdpc_unsigned.apk"
        if [ ! -f "$APK_PATH" ]; then
            error_exit "Build failed: APK not found in $bazel_bin"
        fi
    fi
    
    print_msg "Build successful!" "$GREEN"
    print_msg "APK location: $APK_PATH" "$GREEN"
}

# Extract signature checksum from APK
# Returns URL-safe Base64 encoded SHA-256 hash of signing certificate
get_signature_checksum() {
    local apk="$1"
    local checksum=""
    
    print_msg "Extracting signature checksum..." "$BLUE"
    
    # Create temp directory for extraction
    local temp_dir=$(mktemp -d)
    
    # Extract APK (it's a ZIP file)
    unzip -q "$apk" -d "$temp_dir"
    
    # Find the signature file (RSA or DSA)
    local sig_file=""
    if [ -f "$temp_dir/META-INF/CERT.RSA" ]; then
        sig_file="$temp_dir/META-INF/CERT.RSA"
    elif [ -f "$temp_dir/META-INF/CERT.DSA" ]; then
        sig_file="$temp_dir/META-INF/CERT.DSA"
    elif [ -f "$temp_dir/META-INF/CERT.SF" ]; then
        # If only SF file exists, we need to extract cert differently
        sig_file="$temp_dir/META-INF/CERT.SF"
    fi
    
    if [ -z "$sig_file" ] || [ ! -f "$sig_file" ]; then
        # Alternative method: use keytool to extract from APK directly
        # This works for APKs signed with APK Signature Scheme v2/v3
        print_msg "Using alternative certificate extraction method..." "$YELLOW"
        
        # Use apksigner if available, otherwise use openssl
        if command -v apksigner &> /dev/null; then
            checksum=$(apksigner verify --print-certs "$apk" 2>/dev/null | grep "SHA-256" | head -1 | sed 's/.*: //' | tr -d ' ')
        else
            # Extract certificate using keytool from APK's keystore
            # For debug builds, Bazel uses a debug keystore
            local cert_der="$temp_dir/cert.der"
            
            # Try to extract DER certificate from RSA file
            if [ -f "$temp_dir/META-INF/CERT.RSA" ]; then
                # Extract the certificate from PKCS7 signature
                openssl pkcs7 -inform DER -in "$temp_dir/META-INF/CERT.RSA" -print_certs 2>/dev/null | \
                    openssl x509 -outform DER -out "$cert_der" 2>/dev/null || true
            fi
            
            if [ -f "$cert_der" ] && [ -s "$cert_der" ]; then
                # Calculate SHA-256 and encode as URL-safe Base64
                checksum=$(openssl dgst -sha256 -binary "$cert_der" | base64 | tr '+/' '-_' | tr -d '=')
            else
                # Fallback: extract from APK using jarsigner info
                checksum=$(unzip -p "$apk" META-INF/CERT.RSA 2>/dev/null | \
                    openssl pkcs7 -inform DER -print_certs 2>/dev/null | \
                    openssl x509 -outform DER 2>/dev/null | \
                    openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
            fi
        fi
    else
        # Extract certificate from signature file
        local cert_der="$temp_dir/cert.der"
        
        if [[ "$sig_file" == *.RSA ]]; then
            # Extract certificate from PKCS7 structure
            openssl pkcs7 -inform DER -in "$sig_file" -print_certs 2>/dev/null | \
                openssl x509 -outform DER -out "$cert_der" 2>/dev/null || true
        fi
        
        if [ -f "$cert_der" ] && [ -s "$cert_der" ]; then
            checksum=$(openssl dgst -sha256 -binary "$cert_der" | base64 | tr '+/' '-_' | tr -d '=')
        fi
    fi
    
    # Clean up temp directory
    rm -rf "$temp_dir"
    
    if [ -z "$checksum" ]; then
        error_exit "Failed to extract signature checksum from APK"
    fi
    
    echo "$checksum"
}

# Get component name from AndroidManifest.xml
get_component_name() {
    local apk="$1"
    
    print_msg "Extracting component name..." "$BLUE"
    
    # Extract AndroidManifest.xml and parse for device admin receiver
    # The component name format is: package/receiverClassName
    
    local temp_dir=$(mktemp -d)
    unzip -q "$apk" -d "$temp_dir"
    
    # Use aapt if available, otherwise parse binary manifest
    local package_name=""
    local receiver_name=""
    
    if command -v aapt &> /dev/null; then
        package_name=$(aapt dump badging "$apk" 2>/dev/null | grep "package:" | head -1 | sed "s/package: name='\\([^']*\\)'.*/\\1/")
        # Find DeviceAdminReceiver
        receiver_name=$(aapt dump xmltree "$apk" AndroidManifest.xml 2>/dev/null | grep -A5 "DeviceAdminReceiver" | grep "android:name" | head -1 | sed "s/.*android:name=\"\\([^\"]*\\)\".*/\\1/")
    elif command -v aapt2 &> /dev/null; then
        package_name=$(aapt2 dump badging "$apk" 2>/dev/null | grep "package:" | head -1 | sed "s/package: name='\\([^']*\\)'.*/\\1/")
    fi
    
    # Fallback: try to extract from manifest using strings
    if [ -z "$package_name" ]; then
        package_name=$(strings "$temp_dir/AndroidManifest.xml" 2>/dev/null | grep -o 'com\.afwsamples\.testdpc' | head -1)
    fi
    
    rm -rf "$temp_dir"
    
    # Default values from the original testdpc project
    if [ -z "$package_name" ]; then
        package_name="com.afwsamples.testdpc"
    fi
    
    # DeviceAdminReceiver is the standard component
    if [ -z "$receiver_name" ]; then
        receiver_name="com.afwsamples.testdpc.DeviceAdminReceiver"
    fi
    
    echo "$package_name/$receiver_name"
}

# Generate provisioning JSON for QR code
generate_provisioning_json() {
    local component="$1"
    local checksum="$2"
    local apk_location="$3"
    
    cat << EOF
{
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME": "$component",
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM": "$checksum",
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION": "$apk_location"
}
EOF
}

# Generate QR code image
generate_qr_code() {
    local json="$1"
    local output_file="$2"
    
    if command -v qrencode &> /dev/null; then
        qrencode -o "$output_file" "$json"
        print_msg "QR code generated: $output_file" "$GREEN"
    else
        print_msg "qrencode not installed, skipping QR image generation" "$YELLOW"
    fi
}

# Main function
main() {
    local input="${1:-}"
    
    print_msg "==========================================" "$BLUE"
    print_msg "Automated android-testdpc Build Script" "$BLUE"
    print_msg "==========================================" "$BLUE"
    
    # Validate input
    if [ -z "$input" ]; then
        echo "Usage: $0 <path-to-repo.zip|path-to-repo-dir> [output-dir]"
        echo ""
        echo "Example:"
        echo "  $0 android-testdpc.zip"
        echo "  $0 /path/to/android-testdpc output"
        exit 1
    fi
    
    # Check dependencies
    check_dependencies
    
    # Extract repository
    extract_repo "$input"
    
    # Build APK
    build_apk
    
    # Get signature checksum
    CHECKSUM=$(get_signature_checksum "$APK_PATH")
    print_msg "Signature checksum: $CHECKSUM" "$GREEN"
    
    # Get component name
    COMPONENT_NAME=$(get_component_name "$APK_PATH")
    print_msg "Component name: $COMPONENT_NAME" "$GREEN"
    
    # Prepare output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Copy APK to output
    cp "$APK_PATH" "$OUTPUT_DIR/testdpc.apk"
    print_msg "APK copied to: $OUTPUT_DIR/testdpc.apk" "$GREEN"
    
    # Generate provisioning JSON
    APK_LOCATION="file://$OUTPUT_DIR/testdpc.apk"
    PROVISIONING_JSON=$(generate_provisioning_json "$COMPONENT_NAME" "$CHECKSUM" "$APK_LOCATION")
    
    # Save provisioning JSON
    echo "$PROVISIONING_JSON" > "$OUTPUT_DIR/provisioning.json"
    print_msg "Provisioning JSON saved to: $OUTPUT_DIR/provisioning.json" "$GREEN"
    
    # Generate QR code
    generate_qr_code "$PROVISIONING_JSON" "$OUTPUT_DIR/provisioning_qrcode.png"
    
    # Print final output
    echo ""
    print_msg "==========================================" "$GREEN"
    print_msg "BUILD COMPLETE - QR Provisioning Data" "$GREEN"
    print_msg "==========================================" "$GREEN"
    echo ""
    print_msg "APK Location:" "$YELLOW"
    echo "  $OUTPUT_DIR/testdpc.apk"
    echo ""
    print_msg "Admin Component Name:" "$YELLOW"
    echo "  $COMPONENT_NAME"
    echo ""
    print_msg "Signature Checksum:" "$YELLOW"
    echo "  $CHECKSUM"
    echo ""
    print_msg "Provisioning JSON (for QR code):" "$YELLOW"
    echo "$PROVISIONING_JSON"
    echo ""
    print_msg "To provision a device:" "$BLUE"
    echo "1. Factory reset the device"
    echo "2. Tap the welcome screen 6 times"
    echo "3. Scan the QR code from: $OUTPUT_DIR/provisioning_qrcode.png"
    echo "4. Or manually enter the provisioning data above"
    echo ""
}

# Run main function
main "$@"
