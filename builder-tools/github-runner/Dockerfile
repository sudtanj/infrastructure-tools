# Supervisor for ephemeral GitHub Actions runners (see README.md).
# It does not run jobs itself: for every job it starts a fresh container from
# the official ghcr.io/actions/actions-runner image with a single-use JIT config.
#
# The tag is written out (no ARG) so Dependabot can bump it.
FROM alpine:3.22

# bash + curl + jq for the GitHub API, openssl to sign the GitHub App JWT,
# docker-cli to start runner containers through the mounted socket.
RUN apk add --no-cache bash ca-certificates curl docker-cli jq openssl

COPY supervisor.sh /usr/local/bin/gh-runner-supervisor
RUN chmod 0755 /usr/local/bin/gh-runner-supervisor \
 && bash -n /usr/local/bin/gh-runner-supervisor

# Root filesystem is read-only at run time; the docker CLI keeps its config in $HOME.
ENV HOME=/tmp

ENTRYPOINT ["/usr/local/bin/gh-runner-supervisor"]
CMD ["run"]
