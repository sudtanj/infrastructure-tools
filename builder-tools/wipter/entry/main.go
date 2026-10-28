// wipter-entry starts the Wipter desktop app (Electron) without a display and
// keeps its output short: the app and Chromium log a lot (some of it with the
// account email), so only the status lines of the shim it loads first
// (shim/shim.js: signs in, accepts the consent prompt, keeps sharing on) are
// shown, as "wipter-entry: ..." lines. WIPTER_DEBUG=1 shows everything.
//
// Env: WIPTER_EMAIL and WIPTER_PASSWORD, read by the shim, which removes them
// from the app's environment.
//
// `wipter-entry -selftest` only checks that the app starts and shows its
// sign-in form, with a throwaway profile; the image build runs it.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const app = "/opt/Wipter/wipter-app.bin"

// Chromium switches: no display (headless Ozone, drawing with its software
// GPU), no sandbox and no zygote (the sandbox needs user namespaces or a
// setuid helper; the container is the sandbox), no keyring (the app then
// keeps its login in its own config file), fatal-only Chromium logging.
var appArgs = []string{
	"--no-sandbox",
	"--no-zygote",
	"--ozone-platform=headless",
	"--password-store=basic",
	"--log-level=3",
}

const shimPrefix = "wipter-shim: "

func main() {
	selftest := len(os.Args) > 1 && os.Args[1] == "-selftest"
	if selftest {
		home, err := os.MkdirTemp("", "wipter-selftest-")
		if err != nil {
			fail(err.Error())
		}
		defer os.RemoveAll(home)
		os.Setenv("HOME", home)
		os.Setenv("WIPTER_SELFTEST", "1")
	} else if os.Getenv("WIPTER_EMAIL") == "" || os.Getenv("WIPTER_PASSWORD") == "" {
		fail("WIPTER_EMAIL and WIPTER_PASSWORD must be set")
	}
	debug := os.Getenv("WIPTER_DEBUG") == "1"

	// One stream for stdout and stderr, filtered below. A plain pipe rather
	// than StdoutPipe: Chromium's helper processes may hold it open a little
	// after the app exits, which mustn't keep this process waiting.
	out, w, err := os.Pipe()
	if err != nil {
		fail(err.Error())
	}
	args := appArgs
	if debug {
		args = append(args[:len(args):len(args)], "--enable-logging=stderr", "--log-level=0")
	}
	cmd := exec.Command(app, args...)
	cmd.Stdout, cmd.Stderr = w, w
	if err := cmd.Start(); err != nil {
		fail("cannot start the app: " + err.Error())
	}
	w.Close()
	copied := make(chan struct{})
	go func() {
		filter(out, debug)
		close(copied)
	}()

	var stopping sync.Once
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		for s := range sigs {
			stopping.Do(func() {
				cmd.Process.Signal(s)
				time.AfterFunc(10*time.Second, func() { cmd.Process.Kill() })
			})
		}
	}()

	err = cmd.Wait()
	select {
	case <-copied:
	case <-time.After(2 * time.Second):
	}
	code := cmd.ProcessState.ExitCode()
	if code != 0 {
		fmt.Printf("wipter-entry: the app exited (%v)\n", err)
		if code < 0 {
			code = 1
		}
	}
	os.Exit(code)
}

// filter passes the shim's lines through as "wipter-entry: ..." and drops
// the rest, unless debug is set.
func filter(r io.Reader, debug bool) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if msg, ok := strings.CutPrefix(line, shimPrefix); ok {
			fmt.Println("wipter-entry: " + msg)
		} else if debug {
			fmt.Println(line)
		}
	}
	io.Copy(io.Discard, r) // a line over 1 MiB: keep the pipe drained
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "wipter-entry: "+msg)
	os.Exit(1)
}
