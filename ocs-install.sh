#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_OSD_PV_SIZE="200Gi"
readonly DEFAULT_OCS_RELEASE=4.2
readonly DELETE_TIMEOUT=10s

USAGE="$(basename "${BASH_SOURCE[0]}") [-h]

Deploy OCS 4.X using particular existing storage class.
It creates and consumes openshift-storage namespace that is expected not to exist.

Options:
  (-h | help)   Show this message and exit.
  (-s | --osd-pv-size) SIZE
                Size of persistent volumes for ODS pods. Defaults to ${DEFAULT_OSD_PV_SIZE}.
                Three PVs of this size will be claimed.
  (-r | --ocs-release) RELEASE
                OCS release to deploy. Defaults to ${DEFAULT_OCS_RELEASE}.
  (-u | --uninstall)
                Uninstall existing OCS deployment.
  (-t | --timeout) DELETE_TIMEOUT
                Timeout for oc delete. Defaults to ${DELETE_TIMEOUT}
"

readonly longOptions=(
    osd-pv-size:
    ocs-release:
    uninstall
    timeout:
)

function join() { local IFS="$1"; shift 1; echo "$*"; }

function log()  {
    local v
    local red green reset
    red="$(tput setaf 1)"
    green="$(tput setaf 2)"
    reset="$(tput sgr0)"
    if [[ $# == 2 && "${1:-}" == "export" && ! "${2:-}" =~ "=" ]]; then
        eval "v=\$${2:-}"
        echo "${green}export $2='${v:-}'${reset}" >&2
    else
        ( echo -n "$green"; echo -n "$@"; echo "${reset}"; ) >&2
    fi
    "$@";
}

function die() {
    local red reset
    red="$(tput setaf 1)"
    reset="$(tput sgr0)"
    ( echo -n "$red"; echo -n "FATAL: "; echo -n "$@"; echo "${reset}"; ) >&2
    exit 1
}

function getStorageClass() {
    local name_filter="${1:-}"
    local scs
    if [[ -n "${name_filter:-}" ]]; then
        scs="$(oc get sc -o name | grep "${name_filter}" | grep -v ocs)"
    else
        scs="$(oc get sc | sed -n 's/^\([^[:space:]]\+\)\s\+(default).*/\1/p' | grep -v ocs)"
    fi
    local sc
    sc="$(head -n 1 <<<"${scs}")"
    if [[ -z "${sc:-}" ]]; then
        sc="$(oc get sc -o name | grep -v ocs | head -n 1 ||:)"
    fi

    sc="${sc##*/}"

    if [[ -z "${sc:-}" ]]; then
        printf 'Failed to determine storage class!\n' >&2
        return 1
    fi
    printf '%s\n' "${sc:-}"
}

function forceDeleteResource() {
    local crd="$1"
    local nm="$2"
    local name="$3"
    oc patch -n "$nm" "$crd/$name" --type merge -p '{"metadata":{"finalizers":null}}'
    oc delete --timeout 21s --wait -n "$nm" "$crd/$name" ||:
    if ! oc get -n "$nm" "$crd/$name" >/dev/null 2>&1; then
        return 0
    fi
    oc delete --timeout 21s --wait --force --grace-period=0 -n "$nm" "$crd/$name"
}
export -f forceDeleteResource

function deleteCRD() {
    set -x
    local crd="$1"
    local resources=()
    local rsnm nm name

    # we expect all the resources to be namespaces
    readarray -t resources <<<"$(oc get --all-namespaces "$crd" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' ||:)"
    if [[ "${#resources[@]}" -gt 1 || ( "${#resources[@]}" == 1 && -n "${resources[0]:-}" ) ]]; then
        for rsnm in "${resources[@]}"; do
            if [[ -z "${rsnm:-}" ]]; then
                printf 'empty rsnm!\n' >&2
                continue
            fi
            IFS=/ read -r nm name <<<"${rsnm}"
            parallel --semaphore --id "del-$crd" \
                oc delete --timeout 21s --wait -n "$nm" "$crd/$name"
        done
        parallel --semaphore --id "del-$crd" --wait ||:

        readarray -t resources <<<"$(oc get --all-namespaces "$crd" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' ||:)"
        if [[ "${#resources[@]}" -gt 1 || ( "${#resources[@]}" == 1 && -n "${resources[0]:-}" ) ]]; then
            for rsnm in "${resources[@]}"; do
                if [[ -z "${rsnm:-}" ]]; then
                    printf 'empty rsnm!\n' >&2
                    continue
                fi
                IFS=/ read -r nm name <<<"${rsnm}"
                parallel --semaphore --id "del-$crd" forceDeleteResource "$crd" "$nm" "$name"
            done
            parallel --semaphore --id "del-$crd" --wait ||:
        fi
    fi

    oc delete --timeout 21s --wait "crd/$crd"
}
export -f deleteCRD

function uninstall() {
    local crds=()
    oc delete -n openshift-storage     --timeout=10s  subscription/ocs-subscription            ||:
    oc delete -n openshift-marketplace --timeout=10s  catalogsource ocs-catalogsource          ||:
    parallel oc patch "{}" --type=merge -p '{"metadata": {"finalizers":null}}' \
        <<<"$(oc get cephclusters.ceph.rook.io -o name)" ||:

    readarray -t crds <<<"$(oc get crd | awk '/ceph|ocs|rook|noobaa|objectbucket/ {print $1}')"
    if [[ "${#crds[@]}" -gt 0 ]]; then
        parallel deleteCRD ::: "${crds[@]}"
    fi

    while oc get project openshift-storage 2>/dev/null; do
        printf 'Waiting for openshift-storage project to get deleted.\n' >&2
        sleep 1
    done ||:
}


function getStorageClass() {
    local name_filter="${1:-}"
    local scs
    if [[ -n "${name_filter:-}" ]]; then
        scs="$(oc get sc -o name | grep "${name_filter}" | grep -v ocs)"
    else
        scs="$(oc get sc | sed -n 's/^\([^[:space:]]\+\)\s\+(default).*/\1/p' | grep -v ocs)"
    fi
    local sc="$(head -n 1 <<<"${scs}")"
    if [[ -z "${sc:-}" ]]; then
        sc="$(oc get sc -o name | grep -v ocs | head -n 1 ||:)"
    fi

    sc="${sc##*/}"

    if [[ -z "${sc:-}" ]]; then
        printf 'Failed to determine storage class!\n' >&2
        return 1
    fi
    printf '%s\n' "${sc:-}"
}

function checkPrerequisites() {
    local out cnt
    out="$(oc get -o name nodes -l cluster.ocs.openshift.io/openshift-storage)"
    cnt="$(wc -l <<<"$out")"
    if [[ "$cnt" -lt 3 ]]; then
        die "Number of ocs nodes is less than needed: $cnt < 3! Make sure to label at least 3" \
            "nodes with cluster.ocs.openshift.io/openshift-storage=''"
    fi
}


OSD_PV_SIZE="$DEFAULT_OSD_PV_SIZE"

TMPARGS="$(getopt -o t:ur:s:h --long "$(join , "${longOptions[@]}")" \
                      -n "$(basename "${BASH_SOURCE[@]}")" -- "$@")"

eval set -- "${TMPARGS}"

while true; do
    case "$1" in
    -s | --osd-pv-size)
        OSD_PV_SIZE="$2"
        shift 2
        ;;
    -u | --uninstall)
        UNINSTALL=1
        shift 1
        ;;
    -h | --help)
        printf '%s\n' "${USAGE}"
        shift
        exit 0
        ;;
    -r | --ocs-release)
        OCS_RELEASE="$2"
        shift 2
        ;;
    -t | --timeout)
        DELETE_TIMEOUT="$2"
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        printf 'Unsupported option "%s"!\n' "$1" >&2
        exit 1
        ;;
    esac
done

if [[ "${UNINSTALL:-0}" == 1 ]]; then
    uninstall
    exit 0
fi

[[ -z "${OCS_RELEASE:-}" ]] && OCS_RELEASE="${DEFAULT_OCS_RELEASE}"

branch=master
if [[ "${OCS_RELEASE:-latest}" =~ ^(latest|master)$ ]]; then
    branch=master
else
    branch="release-${OCS_RELEASE}"
fi

checkPrerequisites

oc get crd ocsinitializations.ocs.openshift.io 2>/dev/null || \
    oc create -f https://raw.githubusercontent.com/openshift/ocs-operator/$branch/deploy/crds/ocs_v1_ocsinitialization_crd.yaml
oc get crd storageclusterinitializations.ocs.openshift.io 2>/dev/null || \
    oc create -f https://raw.githubusercontent.com/openshift/ocs-operator/$branch/deploy/crds/ocs_v1_storageclusterinitialization_crd.yaml
oc get crd storageclusters.ocs.openshift.io 2>/dev/null || \
    oc create -f https://raw.githubusercontent.com/openshift/ocs-operator/$branch/deploy/crds/ocs_v1_storagecluster_crd.yaml
oc create -f - < \
    <(curl -s https://raw.githubusercontent.com/openshift/ocs-operator/$branch/deploy/deploy-with-olm.yaml | \
        oc create -f - --dry-run -o json | \
    jq 'select([.kind != "CatalogSource", .metadata.name != "local-storage-manifests"] | any) |
        select([.kind != "Namespace",     .metadata.name != "local-storage"]           | any) |
        select([.kind != "OperatorGroup", .metadata.name != "local-operator-group"]    | any)')

monsc="$(getStorageClass 'filesystem\|fs')"
blocksc="$(getStorageClass 'block')"
if [[ -z "${blocksc:-}" ]]; then
    blocksc="$(getStorageClass)"
fi
if [[ -z "${monsc:-}" ]]; then
    monsc="$(getStorageClass)"
fi

printf 'Block Storage Class:\t%s\nMonitor Storage Class:\t%s\n' "$blocksc" "$monsc"

counter=0
until \
    oc get csv -n openshift-storage |& grep 'ocs-operator.*Succeeded' || \
        [[ ${counter:-0} -gt 60 ]]
do
    out="$(oc get csv -n openshift-storage 2>&1)"
    if [[ $counter -gt 0 ]]; then
        echo -en "\e[${lc}A"
        echo -en "\e[0K\r"
    fi
    echo -e "${out:-}"
    lc="$(wc -l <<<"${out:-}")"
    sleep 0.5
    counter="$(($counter + 1))"
done

set -x

curl --silent \
    https://raw.githubusercontent.com/openshift/ocs-operator/$branch/deploy/crds/ocs_v1_storagecluster_cr.yaml | \
    oc create -f - -o json --dry-run | jq '.metadata.name |= "lsosc"
            | .spec.monPVCTemplate.spec.storageClassName |= "'"${monsc}"'"
            | .spec.storageDeviceSets[0] |= (.name |= "lsods"
                | .dataPVCTemplate.spec |= (.storageClassName |= "'"${blocksc}"'"
                | .resources.requests.storage |= "'"${OSD_PV_SIZE}"'"))' | \
    oc create -f -

watch 'oc get pods -n openshift-storage -o wide;
oc get pvc -n openshift-storage 2>/dev/null;
oc get pv'
