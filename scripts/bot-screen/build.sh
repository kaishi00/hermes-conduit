#!/usr/bin/env bash
# Builds Conduit/Resources/BotScreen/BotScreenViewer.html, the page that draws a bot's
# screen (Bot Screen): noVNC's RFB client (MPL-2.0, the version Hermes Desktop
# ships) and viewer.js, bundled into one module inlined in the page. The app
# feeds it the stream (Conduit/Services/BotScreen.swift).
#
#   scripts/bot-screen/build.sh
set -euo pipefail
NOVNC=1.7.0
ESBUILD=0.25.0
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm pack --silent "@novnc/novnc@$NOVNC" >/dev/null && mkdir -p node_modules/@novnc \
  && tar xzf "novnc-novnc-$NOVNC.tgz" && mv package node_modules/@novnc/novnc)
cp "$here/viewer.js" "$work/viewer.js"
(cd "$work" && npx --yes "esbuild@$ESBUILD" viewer.js --bundle --format=esm --minify --target=safari17 \
  --legal-comments=eof --log-level=warning --outfile=bundle.js)
out="$root/Conduit/Resources/BotScreen/BotScreenViewer.html"
mkdir -p "$(dirname "$out")"
{
  cat <<HTML
<!doctype html>
<!-- Conduit's Bot Screen viewer. Built by scripts/bot-screen/build.sh from
     scripts/bot-screen/viewer.js and noVNC $NOVNC (https://github.com/novnc/noVNC,
     MPL-2.0; source: https://registry.npmjs.org/@novnc/novnc/-/novnc-$NOVNC.tgz). Don't edit by hand. -->
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
  html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden;
               -webkit-user-select: none; -webkit-touch-callout: none; }
  #screen { width: 100%; height: 100%; }
</style>
</head>
<body>
<div id="screen"></div>
<script type="module">
HTML
  # A literal </script> in the bundle would end the tag early.
  sed 's#</script#<\\/script#g' "$work/bundle.js"
  cat <<'HTML'
</script>
</body>
</html>
HTML
} > "$out"
echo "wrote $out ($(wc -c < "$out") bytes)"
