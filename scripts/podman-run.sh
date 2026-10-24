#/bin/bash

podman run --rm -it \
    -v "${PWD}:/srv/jekyll:Z" \
    -e JEKYLL_ROOTLESS=1 \
    -e BUNDLE_APP_CONFIG=.bundle \
    -p 127.0.0.1:4000:4000 \
    docker.io/jekyll/jekyll:stable \
    /bin/bash -c "cd /srv/jekyll && bundle install && bundle exec jekyll serve --host 0.0.0.0 --port 4000 --livereload"
