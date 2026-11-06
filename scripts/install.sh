#!/bin/zsh
# Builds a Release copy of Mumble and installs it to /Applications, then relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Sign with your Apple Development certificate if you have one (Xcode › Settings › Accounts), so macOS
# keeps the microphone and Accessibility permissions after a rebuild. Otherwise it's signed to run locally,
# and you'll be asked for them again after each install.
signing=()
cert=$(security find-certificate -c "Apple Development" -p 2>/dev/null || true)
team=$(print -r -- "$cert" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F' = ' '/organizationalUnitName/ { print $2; exit }' || true)
if [[ -n "$team" ]]; then
  echo "Signing with Apple Development (team $team)"
  signing=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team")
else
  echo "No Apple Development certificate found, so signing to run locally"
fi

xcodegen generate -q
xcodebuild -project Mumble.xcodeproj -scheme Mumble -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build -quiet "${signing[@]}"

pkill -x Mumble 2>/dev/null && sleep 1 || true
rm -rf /Applications/Mumble.app
cp -R build/Build/Products/Release/Mumble.app /Applications/
open /Applications/Mumble.app
echo "Installed /Applications/Mumble.app"
