#!/usr/bin/env bash
# _lock.sh — Portable file locking (Linux flock + macOS Perl fallback)
# Sourced by nightcrawler.sh, start.sh, nightcrawler-list.sh, nightcrawler-remove.sh

# nc_flock_fd — Non-blocking lock on an already-opened file descriptor.
# Usage: exec 200>"$LOCKFILE"; nc_flock_fd 200
# Returns 0 if lock acquired, 1 if already held.
nc_flock_fd() {
    local fd="$1"
    if command -v flock &>/dev/null; then
        flock -n "$fd"
    else
        perl -e 'use Fcntl qw(:flock); open(my $fh, ">&='$fd'") or exit 1; flock($fh, LOCK_EX|LOCK_NB) or exit 1' 2>/dev/null
    fi
}

# nc_flock_test — Test if a lockfile can be locked (i.e., NOT currently held).
# Usage: nc_flock_test "$LOCKFILE" && echo "not locked" || echo "locked"
# Returns 0 if lock is FREE (can acquire), 1 if held by another process.
nc_flock_test() {
    local lockfile="$1"
    if command -v flock &>/dev/null; then
        flock -n "$lockfile" true 2>/dev/null
    else
        perl -e '
use Fcntl qw(:flock);
open(my $fh, ">", $ARGV[0]) or exit 0;
flock($fh, LOCK_EX|LOCK_NB) or exit 1;
exit 0;
' "$lockfile" 2>/dev/null
    fi
}
