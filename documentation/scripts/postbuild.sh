#!/bin/bash
# Runs after `vocs build`.
set -e
cd "$(dirname "$0")/.."

# The static landing page is the site root.
cp public/landing/index.html dist/public/index.html

# vocs builds sitemap and robots URLs from `baseUrl` without `basePath`.
# `baseUrl` has to stay host-only, or canonical URLs get /boo twice.
perl -pi -e 's#https://ph1p\.github\.io/(?!boo/)#https://ph1p.github.io/boo/#g' \
  dist/public/sitemap.xml dist/public/robots.txt
