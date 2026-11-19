#!/bin/zsh
# Notarizes and staples build/PeriPage Bridge.app, then zips it to build/PeriPage-Bridge.zip.
# Build first with a Developer ID:  SIGN_ID="Developer ID Application: ..." scripts/build.sh
#
# Credentials (either):
#   NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
# or an App Store Connect API key:
#   ASC_KEY_PATH=/path/AuthKey_XXXX.p8  ASC_KEY_ID=XXXX  ASC_ISSUER_ID=xxxxxxxx-...
set -e
cd "$(dirname "$0")/../build"
APP="PeriPage Bridge.app"
if [[ -n "$NOTARY_PROFILE" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  : ${ASC_KEY_PATH:?set NOTARY_PROFILE or ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID}
  auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi
rm -f upload.zip PeriPage-Bridge.zip
ditto -c -k --keepParent "$APP" upload.zip
xcrun notarytool submit upload.zip "${auth[@]}" --wait
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
rm upload.zip
ditto -c -k --keepParent "$APP" PeriPage-Bridge.zip
echo "ready: build/PeriPage-Bridge.zip"
