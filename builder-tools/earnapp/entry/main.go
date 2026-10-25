// earnapp-entry prepares /etc/earnapp, registers the device and then replaces
// itself with `earnapp run`. The client reads its ID from /etc/earnapp/uuid
// (it makes up a new one if the file is missing, which would be a device not
// linked to any account). `earnapp run` alone never tells EarnApp the device
// exists, so linking it fails with "device not found": `earnapp start`, which
// the official installer runs, does that (POST /install_device), then writes
// the status file `run` needs and /etc/earnapp/registered.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const (
	confDir  = "/etc/earnapp"
	client   = "/usr/bin/earnapp"
	attempts = 5
)

// The client's own format: sdk-node- and a v4 UUID without dashes.
var idRe = regexp.MustCompile(`^sdk-node-[0-9a-f]{32}$`)

func main() {
	id := os.Getenv("EARNAPP_UUID")
	if !idRe.MatchString(id) {
		fail("EARNAPP_UUID must be sdk-node- followed by 32 lowercase hex digits")
	}
	os.Unsetenv("EARNAPP_UUID")

	// The client sends a hardware serial on registration, read from the
	// devicetree or from `ip link` through a shell. Docker hides the first
	// and the image has no shell, so the build points it at this file
	// instead: stable for a given ID.
	sum := sha256.Sum256([]byte("earnapp-serial:" + id))
	write("uuid", id)
	write("serial", hex.EncodeToString(sum[:16]))
	// `start` refuses to run when the status is already "enabled".
	os.Remove(confDir + "/status")
	os.Remove(confDir + "/registered")

	for i := 1; ; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		cmd := exec.CommandContext(ctx, client, "start")
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		cmd.Run() // exits 0 even when registration failed: check the file
		cancel()
		if reg, _ := os.ReadFile(confDir + "/registered"); strings.TrimSpace(string(reg)) == id {
			fmt.Println("earnapp-entry: device registered")
			break
		}
		if i == attempts {
			fail(fmt.Sprintf("device registration failed %d times; exiting so Docker retries later", attempts))
		}
		fmt.Fprintf(os.Stderr, "earnapp-entry: registration failed (attempt %d/%d), retrying\n", i, attempts)
		os.Remove(confDir + "/status")
		time.Sleep(time.Duration(i*15) * time.Second)
	}

	err := syscall.Exec(client, []string{client, "run"}, os.Environ())
	fail("cannot start " + client + ": " + err.Error())
}

func write(name, data string) {
	if err := os.WriteFile(confDir+"/"+name, []byte(data), 0o600); err != nil {
		fail(fmt.Sprintf("cannot write %s/%s (mount a writable tmpfs there): %v", confDir, name, err))
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "earnapp-entry: "+msg)
	os.Exit(1)
}
