#!/bin/bash
# host-side helper to generate tags

set -eu

id=$(podman ps 2>/dev/null | grep jekyll | awk '{print $1}')

podman exec $id /srv/jekyll/scripts/generate_tags.rb
