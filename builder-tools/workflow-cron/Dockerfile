# workflow-cron: dispatches GitHub Actions workflows on time (see README.md).
# A static Go binary on distroless: no shell, no package manager, runs as nonroot.
#
# The build stage runs natively and cross-compiles, so the arm64 image needs no QEMU.
# The tags are written out (no ARG) so Dependabot can bump them.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN go vet ./... \
 && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags='-s -w' -o /out/workflow-cron .

FROM gcr.io/distroless/static-debian12:nonroot
# Keep the Go runtime well inside the 32m container cap (init-workflow-cron.sh).
ENV GOMEMLIMIT=16MiB GOMAXPROCS=1
COPY --from=build /out/workflow-cron /workflow-cron
ENTRYPOINT ["/workflow-cron"]
