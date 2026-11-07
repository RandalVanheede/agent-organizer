#!/bin/sh
# Publish a release that existing installs pick up through Sparkle.
#
#   scripts/release.sh 1.1.0      (or: make release VERSION=1.1.0)
#
# Builds + signs the dmg, EdDSA-signs it with the private key in your login
# Keychain (Sparkle's sign_update), creates GitHub release v<version> with
# the dmg, then rewrites appcast.xml. You commit + push appcast.xml last:
# clients only see the update once it's on main, by which point the dmg
# already exists.
set -eu

VERSION="${1:-}"
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: scripts/release.sh <major.minor.patch>" >&2; exit 1 ;;
esac

REPO="RandalVanheede/agent-organizer"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
ASSET="AgentOrganizer-$VERSION.dmg"
DMG="build/$ASSET"

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch --quiet --tags origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || { echo "Push your branch first: the release tag is created on GitHub at this commit." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION already exists." >&2; exit 1; fi
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist | grep -q . \
    || { echo "SUPublicEDKey is empty in Resources/Info.plist; run $SPARKLE_BIN/generate_keys --account agent-organizer first." >&2; exit 1; }

BUILD_NUMBER="$(git rev-list --count HEAD)"
make dmg VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER"
cp "build/Agent Organizer.dmg" "$DMG"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account agent-organizer "$DMG")"

gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "v$VERSION" --generate-notes

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Organizer</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ASSET" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo
echo "Released v$VERSION. Last step — publish the update feed:"
echo "  git add appcast.xml && git commit -m '[<TASK-ID>]: Release v$VERSION' && git push"
