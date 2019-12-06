#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

function wait_ready() {
    local status="${2:-Ready}"
    local out="$(ssh "$1" 'exit 0' 2>&1 && oc get node "${1%%.*}" 2>&1)" ||:
    [[ -n "${out:-}" ]] && printf '%s\n' "${out:-}"
    grep -q "\<$status\>" <<<"${out:-}"
}

for node in worker{1,2,3}.alcyone.ocp.local; do
    ssh "$node" '
sudo lvs --noheadings | awk '"'"'{print $2"/"$1}'"'"'   | xargs -r sudo lvremove -f
sudo vgs --noheadings | awk '"'"'{print $1}'"'"'        | xargs -r sudo vgremove -f
sudo pvs --noheadings | awk '"'"'{print $1}'"'"'        | xargs -r sudo pvremove -f
sudo wipefs -a /dev/vdb
sudo rm -rf /var/lib/rook
sudo reboot
#sudo shutdown -h now
' ||:
    printf 'Waiting for node %s to become not ready\n' "$node"
    out="$(wait_ready "$node")" && rc=$? || rc=$?
    while [[ $rc == 0 ]]; do
        [[ -n "${out:-}" ]] && printf '%s\n' "${out:-}"
        sleep 1
        new="$(wait_ready "$node")" && rc=$? || rc=$?
        [[ -n "${out:-}" ]] && echo -en "\e[$(awk 'END {print NR-1}' <<<"${out:-}")A\e[0K\r"
        out="${new:-}"
    done
    printf 'Waiting for node %s to become ready again\n' "$node"
    out="$(wait_ready "$node")" && rc=$? || rc=$?
    until [[ $rc == 0 ]]; do
        [[ -n "${out:-}" ]] && printf '%s\n' "${out:-}"
        sleep 1
        new="$(wait_ready "$node")" && rc=$? || rc=$?
        [[ -n "${out:-}" ]] && echo -en "\e[$(awk 'END {print NR-1}' <<<"${out:-}")A\e[0K\r"
        out="${new:-}"
    done
done

printf 'Block devices wiped.\n'
