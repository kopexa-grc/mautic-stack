#!/usr/bin/env bash
# Checks that every package in image/extensions is ready to be published
# as its own Composer package (see docs/publishing.md).
#
#   hack/check-packages.sh            # needs php + composer (or run in the php-apache:8.4-dev image)
set -euo pipefail
cd "$(dirname "$0")/../image/extensions"
status=0
err() { echo "  ERROR: $*"; status=1; }

for dir in */; do
  pkg="${dir%/}"
  echo "== $pkg"
  [[ -f "$pkg/VERSION" ]] || { err "VERSION missing"; continue; }
  version="$(tr -d '[:space:]' < "$pkg/VERSION")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "VERSION '$version' is not x.y.z"
  for f in LICENSE README.md CHANGELOG.md composer.json .gitattributes; do
    [[ -f "$pkg/$f" ]] || err "$f missing"
  done
  php -r 'exit(array_key_exists("version", json_decode(file_get_contents($argv[1]), true)) ? 1 : 0);' "$pkg/composer.json" \
    || err "composer.json must not contain \"version\" (Packagist takes it from git tags)"
  grep -q "^## $version " "$pkg/CHANGELOG.md" || err "CHANGELOG.md has no entry '## $version …'"
  if [[ -f "$pkg/Config/config.php" ]]; then
    plugin="$(php -r '$c = require $argv[1]; echo $c["version"] ?? "";' "$pkg/Config/config.php")"
    [[ "$plugin" == "$version" ]] || err "Config/config.php version '$plugin' != VERSION '$version'"
  fi
  # Versions hard-coded in code (e.g. the MCP server info).
  while IFS= read -r line; do
    [[ "$line" == *"'$version'"* ]] || err "outdated VERSION constant: $line"
  done < <(find "$pkg" -name '*.php' -exec grep -hE "const VERSION = '" {} + || true)
  out="$(COMPOSER_ROOT_VERSION="$version" composer validate --strict --no-check-lock --no-check-publish -d "$pkg" 2>&1)" \
    || { echo "$out"; err "composer validate failed"; }
done
# Dependencies between our packages must accept the current versions.
php -r '
  $v = [];
  foreach (glob("*/composer.json") as $f) { $v[json_decode(file_get_contents($f), true)["name"]] = trim(file_get_contents(dirname($f)."/VERSION")); }
  foreach (glob("*/composer.json") as $f) {
    foreach (json_decode(file_get_contents($f), true)["require"] ?? [] as $dep => $constraint) {
      if (!isset($v[$dep])) continue;
      [$maj, $min] = explode(".", $v[$dep]);
      $ok = preg_match("/^\\^(\\d+)\\.(\\d+)/", $constraint, $m) && ($maj === "0" ? ($m[1] === "0" && $m[2] === $min) : $m[1] === $maj);
      if (!$ok) { fwrite(STDERR, "  ERROR: $f requires $dep $constraint, but it is at $v[$dep]\n"); exit(1); }
    }
  }' || status=1
[[ $status == 0 ]] && echo "all packages ready"
exit $status
