#!/bin/bash
# Measurements inside the simulated board (copied in and run as root by simulate.sh). Prints
# key=value lines (collected into metrics.json) and '#' lines (shown in the log for analysis).
#
#   sim-metrics.sh mem <prefix>     memory, running services and processes
#   sim-metrics.sh boot             boot timing of the current boot (systemd's own timestamps)
#   sim-metrics.sh idle <seconds>   CPU busy %, interrupts and context switches per second
#   sim-metrics.sh disk <seconds>   writes to the root disk (the SD card on the board)

set -euo pipefail

mode="$1"
case "$mode" in
  mem)
    p="$2"
    awk -v p="$p" '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
      END { printf "%s_mem_available_mib=%d\n%s_mem_used_mib=%d\n", p, a / 1024, p, (t - a) / 1024 }' /proc/meminfo
    echo "${p}_services_running=$(systemctl list-units --type=service --state=running --no-legend --plain | wc -l)"
    # Userspace processes only (kernel threads are children of kthreadd, pid 2)
    echo "${p}_processes=$(ps -e -o pid=,ppid= | awk '$1 != 2 && $2 != 2' | wc -l)"
    echo "# ${p}: running services: $(systemctl list-units --type=service --state=running --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
    echo "# ${p}: largest processes (RSS KiB):"
    { ps -e -o rss=,comm= --sort=-rss | head -n 12 | sed "s/^/#   /"; } || true
    free -m | sed 's/^/#   /'
    { zramctl 2>/dev/null || true; } | sed 's/^/#   /'
    ;;
  boot)
    us() { systemctl show -P "$1" ${2:+"$2"}; }
    awk -v k="$(us UserspaceTimestampMonotonic)" -v m="$(us ActiveEnterTimestampMonotonic multi-user.target)" \
        -v f="$(us FinishTimestampMonotonic)" 'BEGIN {
      printf "boot_kernel_s=%.1f\nboot_multi_user_s=%.1f\nboot_finished_s=%.1f\n", k / 1e6, m / 1e6, f / 1e6 }'
    systemd-analyze time 2>/dev/null | sed 's/^/# /' || true
    echo "# critical chain to multi-user.target:"
    systemd-analyze critical-chain --no-pager multi-user.target 2>/dev/null | sed 's/^/#   /' || true
    echo "# slowest units:"
    systemd-analyze blame --no-pager 2>/dev/null | head -n 15 | sed 's/^/#   /' || true
    echo "# timers:"
    systemctl list-timers --all --no-pager --no-legend 2>/dev/null | sed 's/^/#   /' || true
    ;;
  idle)
    secs="$2"
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    intr1="$(awk '/^intr/ { print $2 }' /proc/stat)"; ctxt1="$(awk '/^ctxt/ { print $2 }' /proc/stat)"
    top -b -n 2 -d "$secs" -w 160 > /tmp/sim-top.txt 2>/dev/null &
    sleep "$secs"
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
    intr2="$(awk '/^intr/ { print $2 }' /proc/stat)"; ctxt2="$(awk '/^ctxt/ { print $2 }' /proc/stat)"
    wait || true
    busy=$(( (u2 + n2 + s2 + q2 + sq2 + st2) - (u1 + n1 + s1 + q1 + sq1 + st1) ))
    idle=$(( (i2 + w2) - (i1 + w1) ))
    awk -v b="$busy" -v i="$idle" -v in1="$intr1" -v in2="$intr2" -v c1="$ctxt1" -v c2="$ctxt2" -v s="$secs" 'BEGIN {
      printf "idle_cpu_busy_pct=%.2f\nidle_interrupts_per_s=%.1f\nidle_context_switches_per_s=%.1f\n",
        (b + i) ? 100 * b / (b + i) : 0, (in2 - in1) / s, (c2 - c1) / s }'
    echo "# busiest processes over ${secs} s:"
    awk '/^top -/ { n++ } n == 2' /tmp/sim-top.txt | sed -n '7,22p' | sed 's/^/#   /'
    rm -f /tmp/sim-top.txt
    ;;
  disk)
    secs="$2"
    dev="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)"
    io() { for f in /proc/[0-9]*/io; do
             pid="${f#/proc/}"; pid="${pid%/io}"
             wb="$(awk '/^write_bytes/ { print $2 }' "$f" 2>/dev/null)" || continue
             if [ -n "$wb" ]; then echo "$pid $wb $(cat "/proc/${pid}/comm" 2>/dev/null)"; fi
           done; }
    read -r w1 s1 < <(awk -v d="$dev" '$3 == d { print $8, $10 }' /proc/diskstats)
    io > /tmp/sim-io1.txt
    sleep "$secs"
    read -r w2 s2 < <(awk -v d="$dev" '$3 == d { print $8, $10 }' /proc/diskstats)
    io > /tmp/sim-io2.txt
    echo "idle_disk_write_kib=$(( (s2 - s1) / 2 ))"
    echo "idle_disk_write_ops=$(( w2 - w1 ))"
    echo "# writers to ${dev} over ${secs} s (KiB, by process):"
    awk 'NR == FNR { a[$1] = $2; next } { d = $2 - ($1 in a ? a[$1] : 0); if (d > 0) printf "%d %s\n", d / 1024, $3 }' \
      /tmp/sim-io1.txt /tmp/sim-io2.txt | sort -rn | head -n 10 | sed 's/^/#   /'
    echo "# mounts: $(findmnt -no TARGET,FSTYPE,OPTIONS / | tr -s ' ')"
    findmnt -rno TARGET,SOURCE,FSTYPE /var/log 2>/dev/null | sed 's/^/# \/var\/log: /' || true
    rm -f /tmp/sim-io1.txt /tmp/sim-io2.txt
    ;;
  *) echo "unknown mode ${mode}" >&2; exit 2 ;;
esac
