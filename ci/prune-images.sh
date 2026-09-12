#!/bin/sh
#
# Reclaim Docker disk on the Jenkins host. Adapted from the plants repo's version.
#
# Called from the Jenkinsfile's post { always { } } on every build. Nothing else removes
# the immutable <image>:<branch>-<build> tag each build mints — buildDiscarder rotates
# Jenkins' own build records, not images — so without this the host accumulates one app
# image per build, from every branch, forever. It runs on `always` because a build that
# fails after the build stage has still tagged an image.
#
# Reads its configuration from the environment (the Jenkinsfile's `environment` block and
# its IMAGES_TO_KEEP build parameter), so the Jenkinsfile can invoke it with a
# single-quoted `sh` step and interpolate nothing:
#
#   image_name       repository to clean, e.g. sleeptracker   (required)
#   branch_slug      this build's branch slug, e.g. main      (required)
#   IMAGES_TO_KEEP   recent images to keep for this branch    (default 5)
#
# Run it by hand on the host the same way:
#
#   image_name=sleeptracker branch_slug=main sh ci/prune-images.sh
#
set -u

IMAGE="${image_name:?image_name is not set}"
SLUG="${branch_slug:?branch_slug is not set}"

# IMAGES_TO_KEEP is a build parameter, so treat it as untrusted: anything that is not a
# plain integer falls back to the default rather than reaching the arithmetic below.
KEEP="${IMAGES_TO_KEEP:-5}"
case "$KEEP" in
    '' | *[!0-9]*) KEEP=5 ;;
esac

# Images from branches that were merged and deleted are only reachable by age: that
# branch's job never runs again, so the per-branch rotation below can never see them.
STALE_DAYS="${STALE_IMAGE_DAYS:-14}"

echo "=== Keeping the newest $KEEP $IMAGE images for '$SLUG' ==="

# Tags are minted as <slug>-<build number>, so sorting numerically on that number is exact
# and immune to clock skew — and note it must be numeric, since a lexicographic sort ranks
# -10 below -9 and would prune the newest builds first.
#
# `docker rmi` without -f already refuses to delete an image any container still
# references, running or stopped, which is what keeps the deployed app and its `-old`
# rollback container safe.
for n in $(docker images --format '{{.Tag}}' "$IMAGE" \
           | sed -n "s/^$SLUG-\([0-9][0-9]*\)\$/\1/p" \
           | sort -rn | tail -n +$((KEEP + 1))); do
    if docker rmi "$IMAGE:$SLUG-$n" > /dev/null 2>&1; then
        echo "  pruned $IMAGE:$SLUG-$n"
    else
        echo "  kept   $IMAGE:$SLUG-$n (still referenced)"
    fi
done

# Everything the rotation cannot reach: images from deleted branches, and untagged
# leftovers from a moved `latest`. `label=` is what makes --all safe — without it this
# would also collect node:24-alpine and every other base image on the host. The label is
# set in the Dockerfile; the two must stay in sync.
echo "=== Pruning unused $IMAGE images older than $STALE_DAYS days ==="
docker image prune --all --force \
    --filter "label=app=$IMAGE" \
    --filter "until=$((STALE_DAYS * 24))h" || true

docker system df || true
