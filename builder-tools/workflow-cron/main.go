// workflow-cron dispatches GitHub Actions workflows (workflow_dispatch) on a cron schedule.
//
// GitHub's own `schedule:` trigger is best effort: runs start minutes to an hour late, and are
// sometimes dropped, worst at the top of the hour. A workflow_dispatch event starts within
// seconds, so a small always-on clock that sends one at the right minute runs jobs on time.
//
// Configuration is environment only (see README.md):
//
//	WORKFLOW_CRON_GITHUB_TOKEN  token with Actions: write on the repo (required)
//	WORKFLOW_CRON_JOBS          one job per line (or separated by ;), required:
//	                              <min> <hour> <dom> <month> <dow> <workflow file> [input=value ...]
//	WORKFLOW_CRON_REPO          owner/name, default sudtanj/infrastructure-tools
//	WORKFLOW_CRON_REF           branch or tag to run, default main
//	WORKFLOW_CRON_TZ            IANA zone the cron fields are in, default UTC
//	WORKFLOW_CRON_TELEGRAM_TOKEN, WORKFLOW_CRON_TELEGRAM_CHAT_ID
//	                            optional: a message when a dispatch fails for good
//
// `workflow-cron -check` validates the configuration, prints each job's next run and exits.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // distroless/static has no zoneinfo
)

type job struct {
	spec     string
	sched    *schedule
	workflow string
	inputs   map[string]string
}

type config struct {
	token, repo, ref, api string
	loc                   *time.Location
	jobs                  []job
	tgToken, tgChat       string
}

var (
	workflowRe = regexp.MustCompile(`^[A-Za-z0-9._-]+\.ya?ml$`)
	repoRe     = regexp.MustCompile(`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)
	inputRe    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*$`)
	loc        = time.UTC
	client     = &http.Client{Timeout: 30 * time.Second}
)

func logf(level, format string, args ...any) {
	fmt.Printf("%s [%s] %s\n", time.Now().In(loc).Format("2006-01-02 15:04:05 -0700"), level, fmt.Sprintf(format, args...))
}

func env(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

func loadConfig() (*config, error) {
	c := &config{
		token:   env("WORKFLOW_CRON_GITHUB_TOKEN", ""),
		repo:    env("WORKFLOW_CRON_REPO", "sudtanj/infrastructure-tools"),
		ref:     env("WORKFLOW_CRON_REF", "main"),
		api:     strings.TrimRight(env("WORKFLOW_CRON_API", "https://api.github.com"), "/"),
		tgToken: env("WORKFLOW_CRON_TELEGRAM_TOKEN", ""),
		tgChat:  env("WORKFLOW_CRON_TELEGRAM_CHAT_ID", ""),
	}
	var err error
	if c.loc, err = time.LoadLocation(env("WORKFLOW_CRON_TZ", "UTC")); err != nil {
		return nil, fmt.Errorf("WORKFLOW_CRON_TZ: %w", err)
	}
	loc = c.loc
	if !repoRe.MatchString(c.repo) {
		return nil, fmt.Errorf("WORKFLOW_CRON_REPO %q is not owner/name", c.repo)
	}
	lines := strings.FieldsFunc(os.Getenv("WORKFLOW_CRON_JOBS"), func(r rune) bool { return r == '\n' || r == ';' })
	for i, line := range lines {
		if j := strings.Index(line, "#"); j >= 0 {
			line = line[:j]
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) < 6 {
			return nil, fmt.Errorf("job %d: want 5 cron fields and a workflow file: %q", i+1, line)
		}
		s, err := parseSchedule(f[:5])
		if err != nil {
			return nil, fmt.Errorf("job %d (%s): %w", i+1, strings.Join(f[:5], " "), err)
		}
		j := job{spec: strings.Join(f[:5], " "), sched: s, workflow: f[5], inputs: map[string]string{}}
		if !workflowRe.MatchString(j.workflow) {
			return nil, fmt.Errorf("job %d: %q is not a workflow file name (e.g. build.yaml)", i+1, j.workflow)
		}
		for _, kv := range f[6:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok || !inputRe.MatchString(k) {
				return nil, fmt.Errorf("job %d: %q is not input=value", i+1, kv)
			}
			j.inputs[k] = v
		}
		c.jobs = append(c.jobs, j)
	}
	if len(c.jobs) == 0 {
		return nil, errors.New("WORKFLOW_CRON_JOBS has no jobs")
	}
	return c, nil
}

func (j job) String() string {
	keys := make([]string, 0, len(j.inputs))
	for k := range j.inputs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	s := j.workflow
	for _, k := range keys {
		s += " " + k + "=" + j.inputs[k]
	}
	return s
}

// githubDo sends one GitHub API request and returns the status and a short error message.
func (c *config) githubDo(ctx context.Context, method, path string, body any) (int, string, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, "", err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.api+path, rd)
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "workflow-cron")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var msg struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(raw, &msg)
	if resp.StatusCode == http.StatusForbidden && resp.Header.Get("X-RateLimit-Remaining") == "0" {
		return http.StatusTooManyRequests, msg.Message, nil
	}
	return resp.StatusCode, msg.Message, nil
}

func workflowPath(c *config, wf string) string {
	return "/repos/" + c.repo + "/actions/workflows/" + url.PathEscape(wf)
}

// verify checks every workflow exists, is enabled and is readable with the token. A wrong
// token or a missing workflow is fatal; GitHub being unreachable is not (it may come back).
func (c *config) verify(ctx context.Context) error {
	seen := map[string]bool{}
	for _, j := range c.jobs {
		if seen[j.workflow] {
			continue
		}
		seen[j.workflow] = true
		code, msg, err := c.githubDo(ctx, http.MethodGet, workflowPath(c, j.workflow), nil)
		switch {
		case err != nil:
			logf("!", "could not reach GitHub to check %s: %v", j.workflow, err)
		case code == http.StatusUnauthorized:
			return errors.New("GitHub refused the token (401): expired or revoked")
		case code == http.StatusNotFound:
			return fmt.Errorf("%s not found in %s (or the token cannot see the repo)", j.workflow, c.repo)
		case code != http.StatusOK:
			logf("!", "checking %s: GitHub answered %d %s", j.workflow, code, msg)
		}
	}
	return nil
}

// maxSkew is how far the local clock may be from GitHub's before a dispatch is skipped.
const maxSkew = 2 * time.Minute

// githubTime reads GitHub's clock from the Date header of /rate_limit (free: not counted).
func (c *config) githubTime(ctx context.Context) (time.Time, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.api+"/rate_limit", nil)
	if err != nil {
		return time.Time{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("User-Agent", "workflow-cron")
	resp, err := client.Do(req)
	if err != nil {
		return time.Time{}, err
	}
	resp.Body.Close()
	return http.ParseTime(resp.Header.Get("Date"))
}

// dispatch sends the workflow_dispatch event, retrying network errors, 5xx and rate limits
// for about five minutes. A 4xx (bad input, workflow disabled, no permission) is not retried.
func (c *config) dispatch(ctx context.Context, j job, at time.Time) {
	// A board without a battery-backed clock (Orange Pi) boots with the time it saved at
	// shutdown until NTP syncs, and would fire slots that are not due. GitHub's clock decides.
	if gh, err := c.githubTime(ctx); err == nil {
		if skew := time.Since(gh); skew > maxSkew || skew < -maxSkew {
			logf("x", "skipped %s due %s: the local clock is %s off GitHub's (NTP not synced yet?)", j, at.Format("15:04"), skew.Round(time.Second))
			c.alert(fmt.Sprintf("workflow-cron: skipped %s, the device clock is %s off (NTP not synced?)", j.workflow, skew.Round(time.Second)))
			return
		}
	} else {
		logf("!", "could not read GitHub's clock (%v); dispatching anyway", err)
	}
	body := map[string]any{"ref": c.ref, "inputs": j.inputs}
	delay := 5 * time.Second
	for attempt := 1; ; attempt++ {
		code, msg, err := c.githubDo(ctx, http.MethodPost, workflowPath(c, j.workflow)+"/dispatches", body)
		if err == nil && code >= 200 && code < 300 {
			late := time.Since(at).Round(time.Second)
			logf("+", "dispatched %s (due %s, sent %s later, attempt %d)", j, at.Format("15:04"), late, attempt)
			return
		}
		reason := fmt.Sprintf("GitHub answered %d %s", code, msg)
		if err != nil {
			reason = err.Error()
		}
		retry := err != nil || code >= 500 || code == http.StatusTooManyRequests
		if !retry || attempt == 6 || ctx.Err() != nil {
			logf("x", "dispatch of %s due %s failed: %s", j, at.Format("15:04"), reason)
			c.alert(fmt.Sprintf("workflow-cron: could not start %s (due %s): %s", j.workflow, at.Format("2006-01-02 15:04 MST"), reason))
			return
		}
		logf("!", "dispatch of %s failed (attempt %d): %s; retrying in %s", j, attempt, reason, delay)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay *= 2
	}
}

func (c *config) alert(text string) {
	if c.tgToken == "" || c.tgChat == "" {
		return
	}
	form := url.Values{"chat_id": {c.tgChat}, "text": {text}}
	resp, err := client.PostForm("https://api.telegram.org/bot"+c.tgToken+"/sendMessage", form)
	if err != nil {
		// A *url.Error quotes the URL, and the bot token is in it.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		logf("!", "telegram alert failed: %v", err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		logf("!", "telegram alert failed: HTTP %d", resp.StatusCode)
	}
}

// maxCatchUp is how far back missed minutes are still fired, e.g. after the VM was paused.
const maxCatchUp = 10 * time.Minute

func run(ctx context.Context, c *config) {
	last := time.Now().In(c.loc).Truncate(time.Minute)
	for {
		next := last.Add(time.Minute)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(next)):
		}
		now := time.Now().In(c.loc).Truncate(time.Minute)
		if !now.After(last) {
			continue // the wall clock went back: never fire a minute twice
		}
		from := last.Add(time.Minute)
		if now.Sub(from) > maxCatchUp {
			logf("!", "clock jumped from %s to %s; skipping minutes older than %s", last.Format("15:04"), now.Format("15:04"), maxCatchUp)
			from = now.Add(-maxCatchUp)
		}
		for m := from; !m.After(now); m = m.Add(time.Minute) {
			for _, j := range c.jobs {
				if j.sched.matches(m) {
					go c.dispatch(ctx, j, m)
				}
			}
		}
		last = now
	}
}

func main() {
	check := flag.Bool("check", false, "validate the configuration, print each job's next run, and exit")
	flag.Parse()

	c, err := loadConfig()
	if err != nil {
		logf("x", "config: %v", err)
		os.Exit(2)
	}
	now := time.Now().In(c.loc)
	for _, j := range c.jobs {
		next := "never"
		if t := j.sched.next(now); !t.IsZero() {
			next = t.Format("2006-01-02 15:04 MST")
		}
		logf("*", "%-14s %s  (next %s)", j.spec, j, next)
	}
	if *check {
		return
	}
	if c.token == "" {
		logf("x", "config: WORKFLOW_CRON_GITHUB_TOKEN is not set")
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := c.verify(ctx); err != nil {
		logf("x", "%v", err)
		os.Exit(1)
	}
	logf("+", "ready: %d job(s) for %s@%s, times in %s", len(c.jobs), c.repo, c.ref, c.loc)
	run(ctx, c)
	logf("*", "stopping")
}
