#!/bin/bash
set -euo pipefail

# ==============================================================================
# Filaire TestFlight Automated Deployment Script
# ==============================================================================

# 1. Load deployment credentials
ENV_FILE=".deploy.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading credentials from $ENV_FILE..."
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
else
    echo "Error: $ENV_FILE not found."
    echo "Please create a .deploy.env file with ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, DEVELOPMENT_TEAM, and BUNDLE_ID."
    echo "See .deploy.env.example for template."
    exit 1
fi

# 2. Verify required credentials
if [ -z "${ASC_KEY_PATH:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
    echo "Error: ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be configured."
    exit 1
fi

# 3. Development Team ID and Bundle ID
if [ -z "${DEVELOPMENT_TEAM:-}" ] || [ -z "${BUNDLE_ID:-}" ]; then
    echo "Error: DEVELOPMENT_TEAM and BUNDLE_ID must be configured."
    exit 1
fi

echo "Using Development Team ID: ${DEVELOPMENT_TEAM}"
echo "Using Bundle ID: ${BUNDLE_ID}"

# 4. Expand tilde in key path if necessary
KEY_PATH=$(eval echo "$ASC_KEY_PATH")

if [ ! -f "$KEY_PATH" ]; then
    echo "Error: App Store Connect key file not found at $KEY_PATH."
    exit 1
fi

# 5. Mirror key to standard location expected by xcrun altool (~/.private_keys/AuthKey_<KEY_ID>.p8)
mkdir -p "$HOME/.private_keys"
STANDARD_KEY_PATH="$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$STANDARD_KEY_PATH" ]; then
    echo "Linking $KEY_PATH to $STANDARD_KEY_PATH..."
    cp "$KEY_PATH" "$STANDARD_KEY_PATH"
fi

# 6. Unlock login keychain for headless codesigning
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
else
    security unlock-keychain -p "" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
fi

# 7. Provision App Store profile via App Store Connect API
# provision.py requires PyJWT; set PYTHON_BIN to an interpreter that has it
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [ -f "scripts/provision.py" ]; then
    echo "=== Provisioning App Store Profile ==="
    $PYTHON_BIN scripts/provision.py || true
fi

IOS_PROFILE_NAME="${IOS_PROFILE_NAME:-Filaire AppStore ${BUNDLE_ID}}"

# 8. Build and deploy companion CLI tool fil to ~/bin/fil
if [ -d "tools/fil" ]; then
    echo "=== Building and deploying companion CLI tool fil ==="
    export PATH="$HOME/.cargo/bin:$PATH"
    if command -v cargo >/dev/null 2>&1; then
        cargo build --release --manifest-path tools/fil/Cargo.toml
        mkdir -p "$HOME/bin"
        cp tools/fil/target/release/fil "$HOME/bin/fil"
        chmod +x "$HOME/bin/fil"
        echo "Successfully deployed fil to $HOME/bin/fil"
    else
        echo "Warning: cargo not found, skipping fil CLI build."
    fi
fi

# 9. Generate Xcode Project with dynamic timestamp build version
echo "=== 1. Generating Xcode Project ==="
# Format: YYmmDD.HHMM.<hash> where <hash> is the first 4 hex digits converted to decimal.
# Total string length must be <= 18 characters (e.g. 260908.1348.8459 is 16 chars, max 17).
TIMESTAMP_BUILD=$(date +%y%m%d.%H%M)

COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "0000")
GIT_HEX="${COMMIT_HASH:0:4}"
if [ ${#GIT_HEX} -lt 4 ]; then GIT_HEX="0000"; fi
GIT_COMMIT_DEC=$((16#${GIT_HEX}))

GIT_COMMIT="$COMMIT_HASH"
if ! git diff --quiet HEAD 2>/dev/null; then GIT_COMMIT="${GIT_COMMIT}-dirty"; fi

export CURRENT_PROJECT_VERSION="${TIMESTAMP_BUILD}.${GIT_COMMIT_DEC}"
export GIT_COMMIT

if [ "${#CURRENT_PROJECT_VERSION}" -gt 18 ]; then
    echo "Error: CURRENT_PROJECT_VERSION '${CURRENT_PROJECT_VERSION}' exceeds 18 characters."
    exit 1
fi

echo "Setting build version: ${CURRENT_PROJECT_VERSION} (${GIT_COMMIT})"
xcodegen generate

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Filaire.xcarchive"
EXPORT_PATH="$BUILD_DIR/IPA"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 7. Create ExportOptions.plist
echo "=== 2. Creating ExportOptions.plist ==="
if [ -n "${IOS_PROFILE_NAME:-}" ]; then
    echo "Using manual signing with profile: ${IOS_PROFILE_NAME}"
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${IOS_PROFILE_NAME}</string>
    </dict>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EOF
else
    echo "Using automatic signing for team: ${DEVELOPMENT_TEAM}"
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EOF
fi

# 8. Archive Project
echo "=== 3. Archiving Project ==="
xcodebuild archive \
  -project Filaire.xcodeproj \
  -scheme Filaire \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  GIT_COMMIT="$GIT_COMMIT" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -skipPackagePluginValidation

# 9. Export IPA Package
echo "=== 4. Exporting IPA Package ==="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

IPA_FILE=$(find "$EXPORT_PATH" -name "*.ipa" | head -n 1)

if [ -z "$IPA_FILE" ]; then
    echo "Error: No IPA file found in $EXPORT_PATH."
    exit 1
fi

echo "Exported IPA at: $IPA_FILE"

# 10. Upload to TestFlight
echo "=== 5. Uploading to TestFlight via App Store Connect ==="
echo "Running altool at path '$(xcrun -f altool)'..."

xcrun altool --upload-app \
  --file "$IPA_FILE" \
  --type ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "=== Deploy Complete! Filaire build ${CURRENT_PROJECT_VERSION} (${GIT_COMMIT}) successfully submitted to TestFlight. ==="
