#!/usr/bin/env bash
# Slurm ResumeFailProgram: called when nodes did not register within ResumeTimeout.
# Removes whatever was half-provisioned so no orphaned VM keeps consuming Azure Local capacity.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/azlocal-common.sh"

HOSTLIST="$1"
log "resume-fail for: $HOSTLIST - cleaning up"
LIFECYCLE=ephemeral "$INSTALL_DIR/bin/azlocal-suspend.sh" "$HOSTLIST"
for node in $(expand_hosts "$HOSTLIST"); do
  set_node_down "$node" "azlocal: resume timeout, VM removed"
done
exit 0
