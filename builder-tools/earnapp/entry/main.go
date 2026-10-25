// earnapp-entry writes the device ID and the "enabled" status into
// /etc/earnapp, then replaces itself with `earnapp run`. The client reads its
// ID from /etc/earnapp/uuid (it makes up a new one if the file is missing,
// which would be a device not linked to any account) and exits if
// /etc/earnapp/status is missing.
package main

import (
	"fmt"
	"os"
	"regexp"
	"syscall"
)

const (
	confDir = "/etc/earnapp"
	client  = "/usr/bin/earnapp"
)

// The client's own format: sdk-node- and a v4 UUID without dashes.
var idRe = regexp.MustCompile(`^sdk-node-[0-9a-f]{32}$`)

func main() {
	id := os.Getenv("EARNAPP_UUID")
	if !idRe.MatchString(id) {
		fail("EARNAPP_UUID must be sdk-node- followed by 32 lowercase hex digits")
	}
	os.Unsetenv("EARNAPP_UUID")
	for _, f := range []struct{ name, data string }{{"uuid", id}, {"status", "enabled\n"}} {
		if err := os.WriteFile(confDir+"/"+f.name, []byte(f.data), 0o600); err != nil {
			fail(fmt.Sprintf("cannot write %s/%s (mount a writable tmpfs there): %v", confDir, f.name, err))
		}
	}
	err := syscall.Exec(client, []string{client, "run"}, os.Environ())
	fail("cannot start " + client + ": " + err.Error())
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "earnapp-entry: "+msg)
	os.Exit(1)
}
