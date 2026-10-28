// wipter-entry runs the Wipter desktop app (Electron) without a display and
// does by itself what a user would do in its window: sign in, accept the
// consent prompt, turn sharing on. It talks to the app over the Chrome
// DevTools protocol on a pipe (--remote-debugging-pipe, file descriptors 3
// and 4), so no debugging port is ever open: the app relays third-party
// traffic, and a port on localhost would be reachable through it.
//
// Env: WIPTER_EMAIL and WIPTER_PASSWORD (only used when the saved session in
// ~/.config/wipter-app is missing or expired; neither is passed on to the
// app), WIPTER_DEBUG=1 to show the app's own output.
//
// `wipter-entry -selftest` only checks that the app starts and shows its
// sign-in form, with a throwaway profile; the image build runs it.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const app = "/opt/Wipter/wipter-app.bin"

// Chromium switches: no display (headless Ozone), no GPU, no sandbox (needs
// user namespaces or a setuid helper; the container is the sandbox), no
// keyring (the app then keeps its login in its own config file), and no
// throttling of the window nobody looks at: its page runs the client.
var appArgs = []string{
	"--no-sandbox",
	"--ozone-platform=headless",
	"--disable-gpu",
	"--disable-software-rasterizer",
	"--password-store=basic",
	"--disable-background-timer-throttling",
	"--disable-renderer-backgrounding",
	"--disable-backgrounding-occluded-windows",
	"--remote-debugging-pipe",
}

func logf(format string, a ...any) {
	fmt.Printf("wipter-entry: "+format+"\n", a...)
}

func main() {
	selftest := len(os.Args) > 1 && os.Args[1] == "-selftest"
	email, password := os.Getenv("WIPTER_EMAIL"), os.Getenv("WIPTER_PASSWORD")
	os.Unsetenv("WIPTER_EMAIL")
	os.Unsetenv("WIPTER_PASSWORD")
	if !selftest && (email == "" || password == "") {
		fail("WIPTER_EMAIL and WIPTER_PASSWORD must be set")
	}
	if selftest {
		home, err := os.MkdirTemp("", "wipter-selftest-")
		if err != nil {
			fail(err.Error())
		}
		defer os.RemoveAll(home)
		os.Setenv("HOME", home)
	}

	toApp, appIn, err := os.Pipe() // fd 3 in the app: commands
	if err != nil {
		fail(err.Error())
	}
	appOut, fromApp, err := os.Pipe() // fd 4 in the app: replies
	if err != nil {
		fail(err.Error())
	}
	cmd := exec.Command(app, appArgs...)
	cmd.ExtraFiles = []*os.File{toApp, fromApp}
	if os.Getenv("WIPTER_DEBUG") == "1" {
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	}
	if err := cmd.Start(); err != nil {
		fail("cannot start the app: " + err.Error())
	}
	toApp.Close()
	fromApp.Close()

	// done closes when the app exits. stopping is set before the app is
	// stopped on purpose, so that exit isn't reported as a failure.
	done := make(chan struct{})
	var waitErr error
	go func() { waitErr = cmd.Wait(); close(done) }()
	var stopping atomic.Bool
	stop := func() {
		stopping.Store(true)
		cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sigs; stop(); os.Exit(0) }()

	c := newCDP(appIn, appOut)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-done
		cancel()
		if !stopping.Load() {
			fail(fmt.Sprintf("the app exited: %v", waitErr))
		}
	}()

	if selftest {
		runSelftest(ctx, c)
		stop()
		return
	}
	supervise(ctx, c, email, password)
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "wipter-entry: "+msg)
	os.Exit(1)
}

// ---------------------------------------------------------------------------
// What the launcher does with the window
// ---------------------------------------------------------------------------

// The app's own test IDs (data-testid) on the elements used below.
const probeJS = `(() => {
  const q = id => document.querySelector('[data-testid="' + id + '"]');
  const s = q('connection-status');
  const b = q('sign-in-button');
  return {
    ready: document.readyState === 'complete',
    signin: !!q('email-input'),
    signinEnabled: !!b && !b.disabled,
    consent: !!q('consent-agree-button'),
    status: s ? s.textContent.trim() : '',
    toggle: !!q('switch-status-button'),
  };
})()`

type state struct {
	Ready         bool   `json:"ready"`
	Signin        bool   `json:"signin"`
	SigninEnabled bool   `json:"signinEnabled"`
	Consent       bool   `json:"consent"`
	Status        string `json:"status"`
	Toggle        bool   `json:"toggle"`
}

func probe(ctx context.Context, p *page) (state, error) {
	var s state
	v, err := p.eval(ctx, probeJS)
	if err == nil {
		err = json.Unmarshal(v, &s)
	}
	return s, err
}

func runSelftest(ctx context.Context, c *cdp) {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Minute)
	defer cancel()
	p := &page{c: c}
	for {
		s, err := probe(ctx, p)
		if err == nil && s.Ready && s.Signin {
			logf("selftest: the sign-in form loaded")
			return
		}
		if ctx.Err() != nil {
			fail(fmt.Sprintf("selftest: no sign-in form after 4 minutes (last error: %v)", err))
		}
		sleep(ctx, 2*time.Second)
	}
}

func supervise(ctx context.Context, c *cdp, email, password string) {
	p := &page{c: c}
	var (
		last         state
		signedIn     bool
		offlineSince time.Time
		lastToggle   time.Time
		failures     int
	)
	for ctx.Err() == nil {
		s, err := probe(ctx, p)
		if err != nil || !s.Ready {
			sleep(ctx, 3*time.Second)
			continue
		}
		switch {
		case s.Consent:
			// The app stops sharing until its data-sharing consent is
			// accepted; running this image is that choice.
			if err := p.click(ctx, "consent-agree-button"); err == nil {
				logf("accepted the app's bandwidth-sharing consent prompt")
			}
		case s.Signin:
			if signedIn {
				logf("signed out (session expired?): signing in again")
				signedIn = false
			}
			if failures >= 3 {
				// Don't hammer the account with a wrong password: let
				// Docker restart the container later instead.
				logf("sign-in failed 3 times; check WIPTER_EMAIL / WIPTER_PASSWORD")
				sleep(ctx, 30*time.Minute)
				os.Exit(1)
			}
			if err := signIn(ctx, p, email, password); err != nil {
				failures++
				logf("sign-in failed (attempt %d/3): %v", failures, err)
				sleep(ctx, time.Duration(failures)*time.Minute)
				continue
			}
			failures = 0
		case s.Status != "":
			if !signedIn {
				logf("signed in")
				signedIn = true
			}
			if s.Status != last.Status {
				logf("status: %s", s.Status)
			}
			// Sharing is off (auto-connect disabled, or turned off from the
			// account): switch it on, at most every 10 minutes.
			if strings.EqualFold(s.Status, "offline") && s.Toggle {
				if offlineSince.IsZero() {
					offlineSince = time.Now()
				}
				if time.Since(offlineSince) > 90*time.Second && time.Since(lastToggle) > 10*time.Minute {
					if err := p.click(ctx, "switch-status-button"); err == nil {
						logf("sharing was off: turned it on")
						lastToggle = time.Now()
					}
				}
			} else {
				offlineSince = time.Time{}
			}
		}
		last = s
		sleep(ctx, 15*time.Second)
	}
}

func signIn(ctx context.Context, p *page, email, password string) error {
	logf("signing in")
	for _, f := range []struct{ id, text string }{{"email-input", email}, {"password-input", password}} {
		ok, err := p.eval(ctx, `(() => {
  const e = document.querySelector('[data-testid="`+f.id+`"]');
  const i = e && (e.matches('input') ? e : e.querySelector('input'));
  if (!i) return false;
  i.focus(); i.select();
  return true;
})()`)
		if err != nil {
			return err
		}
		if string(ok) != "true" {
			return errors.New("the sign-in form changed: no " + f.id)
		}
		// Typed as real input, so the page's own handlers see it.
		if _, err := p.call(ctx, "Input.insertText", map[string]any{"text": f.text}); err != nil {
			return err
		}
	}
	for i := 0; ; i++ {
		s, err := probe(ctx, p)
		if err != nil {
			return err
		}
		if s.SigninEnabled {
			break
		}
		if i == 10 {
			return errors.New("the sign-in button stays disabled (is WIPTER_EMAIL a valid address?)")
		}
		sleep(ctx, time.Second)
	}
	if err := p.click(ctx, "sign-in-button"); err != nil {
		return err
	}
	for i := 0; i < 45; i++ {
		sleep(ctx, 2*time.Second)
		s, err := probe(ctx, p)
		if err == nil && s.Ready && !s.Signin {
			return nil
		}
	}
	return errors.New("still on the sign-in form after 90 s (wrong email or password, or the account needs verifying in the app)")
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// ---------------------------------------------------------------------------
// Chrome DevTools protocol over the pipe: JSON messages ended by a NUL byte
// ---------------------------------------------------------------------------

type cdpReply struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

type cdp struct {
	mu      sync.Mutex
	w       io.Writer
	next    int
	pending map[int]chan cdpReply
}

func newCDP(w io.Writer, r io.Reader) *cdp {
	c := &cdp{w: w, pending: map[int]chan cdpReply{}}
	go func() {
		br := bufio.NewReaderSize(r, 1<<16)
		for {
			msg, err := br.ReadBytes(0)
			if err != nil {
				return
			}
			var rep cdpReply
			if json.Unmarshal(msg[:len(msg)-1], &rep) != nil || rep.ID == 0 {
				continue // events
			}
			c.mu.Lock()
			ch := c.pending[rep.ID]
			delete(c.pending, rep.ID)
			c.mu.Unlock()
			if ch != nil {
				ch <- rep
			}
		}
	}()
	return c
}

func (c *cdp) call(ctx context.Context, session, method string, params any) (json.RawMessage, error) {
	c.mu.Lock()
	c.next++
	id := c.next
	ch := make(chan cdpReply, 1)
	c.pending[id] = ch
	msg := map[string]any{"id": id, "method": method, "params": params}
	if session != "" {
		msg["sessionId"] = session
	}
	b, _ := json.Marshal(msg)
	_, err := c.w.Write(append(b, 0))
	c.mu.Unlock()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	select {
	case rep := <-ch:
		if rep.Error != nil {
			return nil, errors.New(method + ": " + rep.Error.Message)
		}
		return rep.Result, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, errors.New(method + ": no reply")
	}
}

// page is a session on the app's window, attached again whenever the window
// is replaced or reloaded.
type page struct {
	c       *cdp
	session string
}

func (p *page) attach(ctx context.Context) error {
	res, err := p.c.call(ctx, "", "Target.getTargets", map[string]any{})
	if err != nil {
		return err
	}
	var t struct {
		TargetInfos []struct {
			TargetID string `json:"targetId"`
			Type     string `json:"type"`
		} `json:"targetInfos"`
	}
	json.Unmarshal(res, &t)
	for _, ti := range t.TargetInfos {
		if ti.Type != "page" {
			continue
		}
		res, err := p.c.call(ctx, "", "Target.attachToTarget", map[string]any{"targetId": ti.TargetID, "flatten": true})
		if err != nil {
			return err
		}
		var a struct {
			SessionID string `json:"sessionId"`
		}
		json.Unmarshal(res, &a)
		p.session = a.SessionID
		// Nobody focuses the headless window: make the page behave as if
		// it had focus, or typed text goes nowhere.
		p.c.call(ctx, p.session, "Emulation.setFocusEmulationEnabled", map[string]any{"enabled": true})
		return nil
	}
	return errors.New("no app window yet")
}

func (p *page) call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	if p.session == "" {
		if err := p.attach(ctx); err != nil {
			return nil, err
		}
	}
	res, err := p.c.call(ctx, p.session, method, params)
	if err != nil {
		p.session = "" // stale session: attach again next time
	}
	return res, err
}

func (p *page) eval(ctx context.Context, expr string) (json.RawMessage, error) {
	res, err := p.call(ctx, "Runtime.evaluate", map[string]any{"expression": expr, "returnByValue": true})
	if err != nil {
		return nil, err
	}
	var r struct {
		Result struct {
			Value json.RawMessage `json:"value"`
		} `json:"result"`
		ExceptionDetails *struct {
			Text string `json:"text"`
		} `json:"exceptionDetails"`
	}
	if err := json.Unmarshal(res, &r); err != nil {
		return nil, err
	}
	if r.ExceptionDetails != nil {
		return nil, errors.New("page script failed: " + r.ExceptionDetails.Text)
	}
	return r.Result.Value, nil
}

func (p *page) click(ctx context.Context, testID string) error {
	v, err := p.eval(ctx, `(() => { const e = document.querySelector('[data-testid="`+testID+`"]'); if (!e) return false; e.click(); return true; })()`)
	if err == nil && string(v) != "true" {
		err = errors.New("no " + testID)
	}
	return err
}
