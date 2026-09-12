FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0

# Marks every image built from this file as ours, so ci/prune-images.sh can collect
# untagged leftovers without touching images belonging to anything else on the Docker
# host. Must stay in sync with `image_name` in the Jenkinsfile.
LABEL app="sleeptracker"

# No dependencies and no build step — the app is one static HTML file plus a
# stdlib-only Node server, so there is nothing to install or compile.
COPY package.json ./
COPY server.mjs ./
COPY public ./public

EXPOSE 3000
CMD ["node", "server.mjs"]
