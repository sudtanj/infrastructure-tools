// Entrypoint for the distroless image. There is no shell to expand
// TS_TAILSCALED_EXTRA_ARGS, so this appends it to the container arguments,
// split on whitespace like the official image's containerboot, and execs
// tailscaled. Extra args come last, so for a repeated flag (--port) they win.
package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
)

const tailscaled = "/usr/local/bin/tailscaled"

func main() {
	args := []string{tailscaled, "--statedir=/var/lib/tailscale", "--socket=/var/run/tailscale/tailscaled.sock"}
	args = append(args, os.Args[1:]...)
	args = append(args, strings.Fields(os.Getenv("TS_TAILSCALED_EXTRA_ARGS"))...)
	err := syscall.Exec(tailscaled, args, os.Environ())
	fmt.Fprintln(os.Stderr, "exec tailscaled:", err)
	os.Exit(1)
}
