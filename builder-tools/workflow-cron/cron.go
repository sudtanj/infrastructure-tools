package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// schedule is a parsed 5-field cron expression (minute hour day-of-month month day-of-week),
// one bit per allowed value. Supports *, n, a-b, */s, a-b/s, n/s and comma lists.
type schedule struct {
	min, hour, dom, month, dow uint64
	// A field starting with * leaves that day field unrestricted. As in Vixie cron, when both
	// day fields are restricted a day matches if EITHER does ("1 * 1 * 1": the 1st or Mondays).
	domStar, dowStar bool
}

func parseSchedule(fields []string) (*schedule, error) {
	if len(fields) != 5 {
		return nil, fmt.Errorf("want 5 cron fields, got %d", len(fields))
	}
	var s schedule
	var err error
	if s.min, err = parseField(fields[0], 0, 59); err != nil {
		return nil, fmt.Errorf("minute: %w", err)
	}
	if s.hour, err = parseField(fields[1], 0, 23); err != nil {
		return nil, fmt.Errorf("hour: %w", err)
	}
	if s.dom, err = parseField(fields[2], 1, 31); err != nil {
		return nil, fmt.Errorf("day of month: %w", err)
	}
	if s.month, err = parseField(fields[3], 1, 12); err != nil {
		return nil, fmt.Errorf("month: %w", err)
	}
	if s.dow, err = parseField(fields[4], 0, 7); err != nil {
		return nil, fmt.Errorf("day of week: %w", err)
	}
	// 7 is Sunday too.
	if s.dow&(1<<7) != 0 {
		s.dow = s.dow&^(1<<7) | 1
	}
	s.domStar = strings.HasPrefix(fields[2], "*")
	s.dowStar = strings.HasPrefix(fields[4], "*")
	return &s, nil
}

func parseField(field string, lo, hi int) (uint64, error) {
	var bits uint64
	for _, part := range strings.Split(field, ",") {
		rng, stepStr, hasStep := strings.Cut(part, "/")
		step := 1
		if hasStep {
			n, err := strconv.Atoi(stepStr)
			if err != nil || n < 1 {
				return 0, fmt.Errorf("bad step %q", part)
			}
			step = n
		}
		var a, b int
		if rng == "*" {
			a, b = lo, hi
		} else {
			first, last, isRange := strings.Cut(rng, "-")
			var err error
			if a, err = strconv.Atoi(first); err != nil {
				return 0, fmt.Errorf("bad value %q", part)
			}
			switch {
			case isRange:
				if b, err = strconv.Atoi(last); err != nil {
					return 0, fmt.Errorf("bad value %q", part)
				}
			case hasStep: // "5/15" means 5-hi/15
				b = hi
			default:
				b = a
			}
		}
		if a < lo || b > hi || a > b {
			return 0, fmt.Errorf("%q is outside %d-%d", part, lo, hi)
		}
		for i := a; i <= b; i += step {
			bits |= 1 << uint(i)
		}
	}
	return bits, nil
}

func (s *schedule) matches(t time.Time) bool {
	if s.min&(1<<uint(t.Minute())) == 0 || s.hour&(1<<uint(t.Hour())) == 0 || s.month&(1<<uint(t.Month())) == 0 {
		return false
	}
	dom := s.dom&(1<<uint(t.Day())) != 0
	dow := s.dow&(1<<uint(t.Weekday())) != 0
	if s.domStar || s.dowStar {
		return dom && dow
	}
	return dom || dow
}

// next is the first minute after t that matches, or the zero time if none does within
// about five years ("0 0 31 2 *" never does). Only used for the startup log.
func (s *schedule) next(t time.Time) time.Time {
	t = t.Truncate(time.Minute).Add(time.Minute)
	for end := t.AddDate(5, 0, 0); t.Before(end); t = t.Add(time.Minute) {
		if s.month&(1<<uint(t.Month())) == 0 {
			t = time.Date(t.Year(), t.Month()+1, 1, 0, 0, 0, 0, t.Location()).Add(-time.Minute)
			continue
		}
		if s.matches(t) {
			return t
		}
	}
	return time.Time{}
}
