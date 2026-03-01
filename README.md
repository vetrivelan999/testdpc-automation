# Automated Android TestDPC Build System

Automated build scripts for compiling android-testdpc and generating QR provisioning data.

## Quick Start

### 1. Setup (One-time on fresh Ubuntu)

```bash
# Run with sudo on Ubuntu 22.04 or 24.04
sudo ./setup_ubuntu.sh

# Reload environment variables
source /etc/profile.d/android.sh
source /etc/profile.d/java.sh
```

### 2. Build

```bash
# Make scripts executable
chmod +x build_testdpc.sh

# Build from cloned repository
./build_testdpc.sh ./android-testdpc

# Or build from zip archive
./build_testdpc.sh /path/to/android-testdpc.zip output/
```

## Output

The script generates:

| File | Description |
|------|-------------|
| `output/testdpc.apk` | Built APK ready for installation |
| `output/provisioning.json` | JSON data for QR code provisioning |
| `output/provisioning_qrcode.png` | QR code image (if qrencode installed) |

## QR Code Provisioning

1. Factory reset your Android device (N+)
2. Tap the welcome screen 6 times
3. Scan the generated QR code
4. Follow on-screen instructions

## Provisioning JSON Format

```json
{
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME": "com.afwsamples.testdpc/com.afwsamples.testdpc.DeviceAdminReceiver",
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM": "<checksum>",
    "android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION": "<apk-path>"
}
```

## Requirements

- Ubuntu 22.04 or 24.04
- Internet connection (for downloading dependencies)
- ~10GB disk space (Android SDK + Bazel cache)

## Files

- `setup_ubuntu.sh` - Installs JDK 17, Bazel, Android SDK, utilities
- `build_testdpc.sh` - Main build automation script
- `android-testdpc/` - Cloned source repository

## Custom Build

To build with custom package name or signing key, modify the WORKSPACE and BUILD files before running the build script.

## Troubleshooting

### Bazel build fails
- Ensure `ANDROID_HOME` is set correctly
- Check SDK platforms 34 and 35 are installed
- Run `bazel clean` and retry

### Signature checksum extraction fails
- Ensure `openssl` and `keytool` are installed
- Check APK is properly signed (debug builds are auto-signed by Bazel)

### QR code image not generated
- Install qrencode: `sudo apt-get install qrencode`
