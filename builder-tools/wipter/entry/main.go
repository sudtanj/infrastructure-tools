// wipter-entry starts the Wipter desktop app (Electron) on a private virtual
// display (Xvfb, nothing else: no window manager or VNC) and keeps its output
// short: the app and Chromium log a lot (some of it with the
// account email), so only the status lines of the shim it loads first
// (shim/shim.js: signs in, accepts the consent prompt, keeps sharing on) are
// shown, as "wipter-entry: ..." lines. WIPTER_DEBUG=1 shows everything.
//
// Env: WIPTER_EMAIL and WIPTER_PASSWORD, read by the shim, which removes them
// from the app's environment.
//
// `wipter-entry -selftest` only checks that the app starts and shows its
// sign-in form, with a throwaway profile; the image build runs it.
//
// For builder-tools/wipter-bundle (the app and Xvfb outside this image):
// WIPTER_APP and WIPTER_XVFB are their paths, WIPTER_XKB_DIR Xvfb's keyboard
// data. (Chromium's headless display backend instead of Xvfb hangs Electron
// before its window opens, even with the GPU in-process.)
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

const defaultApp = "/opt/Wipter/wipter-app.bin"

// Chromium switches: X11 on the virtual display, no GPU (software
// compositing, done in the main process: no GPU process, and the build drops
// the GPU libraries), one page process, no sandbox and no zygote (the sandbox
// needs user namespaces or a setuid helper; the container is the sandbox), no
// keyring (the app then keeps its login in its own config file), a small V8
// young generation (~15 MB less, measured), fatal-only Chromium logging.
// WIPTER_CHROMIUM_FLAGS (space-separated) adds more or overrides these:
// --js-flags=--lite-mode saves ~30 MB more but turns off V8's optimizing
// compiler; --single-process hangs.
// Chromium's headless display backend would need no X server at all, but in
// Electron its GPU process still looks for one and the window never opens.
var appArgs = []string{
	"--no-sandbox",
	"--no-zygote",
	"--ozone-platform=x11",
	"--disable-gpu",
	"--in-process-gpu",
	"--disable-software-rasterizer",
	"--renderer-process-limit=1",
	"--disable-features=SpareRendererForSitePerProcess,MediaRouter,DialMediaRouteProvider,AudioServiceOutOfProcess",
	"--disable-renderer-accessibility",
	"--js-flags=--max-semi-space-size=1",
	"--password-store=basic",
	"--log-level=3",
}

const display = ":99"

// startX starts Xvfb on display :99, local socket only, without GLX (the
// app draws in software; the build drops Mesa), and waits for it.
func startX(debug bool) *exec.Cmd {
	xvfb := os.Getenv("WIPTER_XVFB")
	if xvfb == "" {
		xvfb = "/usr/bin/Xvfb"
	}
	args := []string{display, "-screen", "0", "800x600x16",
		"-nolisten", "tcp", "-noreset", "-nocursor", "-extension", "GLX"}
	if dir := os.Getenv("WIPTER_XKB_DIR"); dir != "" {
		args = append(args, "-xkbdir", dir)
	}
	// Xvfb only creates its socket dir as root.
	if os.Mkdir("/tmp/.X11-unix", 0o755) == nil {
		os.Chmod("/tmp/.X11-unix", 0o777|os.ModeSticky)
	}
	x := exec.Command(xvfb, args...)
	if debug {
		x.Stdout, x.Stderr = os.Stdout, os.Stderr
	}
	if err := x.Start(); err != nil {
		fail("cannot start Xvfb: " + err.Error())
	}
	for i := 0; i < 100; i++ {
		if _, err := os.Stat("/tmp/.X11-unix/X99"); err == nil {
			return x
		}
		time.Sleep(100 * time.Millisecond)
	}
	x.Process.Kill()
	fail("Xvfb did not start")
	return nil
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
	app := os.Getenv("WIPTER_APP")
	if app == "" {
		app = defaultApp
	}
	x := startX(debug)
	defer x.Process.Kill()
	os.Setenv("DISPLAY", display)
	args := append(appArgs[:len(appArgs):len(appArgs)], strings.Fields(os.Getenv("WIPTER_CHROMIUM_FLAGS"))...)
	if debug {
		args = append(args, "--enable-logging=stderr", "--log-level=0")
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
	x.Process.Kill()
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
