#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_OSD_PV_SIZE="200Gi"
readonly DEFAULT_OCS_RELEASE=4.2

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
"

readonly long_options=(
    osd-pv-size:
    ocs-release:
    uninstall
)

function join() { local IFS="$1"; shift 1; echo "$*"; }

function log()  {
    local v
    local red=`tput setaf 1`
    local green=`tput setaf 2`
    local reset=`tput sgr0`
    if [[ $# == 2 && "${1:-}" == "export" && ! "${2:-}" =~ "=" ]]; then
        eval "v=\$${2:-}"
        echo "${green}export $2='${v:-}'${reset}" >&2
    else
        ( echo -n "$green"; echo -n "$@"; echo "${reset}"; ) >&2
    fi
    "$@";
}

function die() {
    local red=`tput setaf 1`
    local reset=`tput sgr0`
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

function uninstall() {
    oc delete -n openshift-storage     subscription/ocs-subscription            ||:
    oc delete -n openshift-marketplace catalogsource ocs-catalogsource          ||:
    for cc in `oc get cephclusters.ceph.rook.io -o name`; do
        oc patch $cc --type=merge -p '{"metadata": {"finalizers":null}}' ||:
    done ||:
    oc get storagecluster --all-namespaces -o name | xargs -n 1 -r oc delete    ||:
    oc get cephcluster --all-namespaces -o name    | xargs -n 1 -r oc delete    ||:
    sleep 1
    oc get csv -o name --all-namespaces -o name | grep ocs-oper | xargs -n 1 -r oc delete ||:
    sleep 1
    oc delete --all ds -n openshift-storage         ||:
    oc delete --all deploy -n openshift-storage     ||:
    sleep 1
    oc get pods -o name -n openshift-storage | xargs -n 1 -r oc delete --force --grace-period=0 ||:
    oc delete --wait project openshift-storage      ||:
    sleep 1
    oc get sc | awk '/\.csi\.ceph\.com/{print $1}'  | xargs -n 1 -r -i oc delete 'sc/{}' ||:
    oc get pv | awk '/noobaa/{print $1}'            | xargs -n 1 -r -i oc delete 'pv/{}' ||:

    for r in `oc get crd | awk '/ceph|ocs|rook|noobaa|object/{print $1}' ||:`; do
        oc get $r --all-namespaces -o name | xargs -n 1 -r oc delete ||:
    done ||:

    while oc get project openshift-storage 2>/dev/null; do
        printf 'Waiting for openshift-storage project to get deleted.\n' >&2
        sleep 1
    done ||:

    for crd in `oc get crd -o name | grep 'ceph\|ocs\|rook\|noobaa\|object' ||:`; do
        oc delete $crd ||:
    done
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

function uninstall() {
    oc delete -n openshift-storage     subscription/ocs-subscription            ||:
    oc delete -n openshift-marketplace catalogsource ocs-catalogsource          ||:
    for cc in `oc get cephclusters.ceph.rook.io -o name`; do
        oc patch $cc --type=merge -p '{"metadata": {"finalizers":null}}' ||:
    done ||:
    oc get storagecluster --all-namespaces -o name | xargs -n 1 -r oc delete    ||:
    oc get cephcluster --all-namespaces -o name    | xargs -n 1 -r oc delete    ||:
    oc delete project openshift-storage &
    oc get csv -o name --all-namespaces -o name | grep ocs-oper | xargs -n 1 -r oc delete ||:
    oc delete --all ds -n openshift-storage         ||:
    oc delete --all deploy -n openshift-storage     ||:
    oc get pods -o name -n openshift-storage | xargs -n 1 -r oc delete --force --grace-period=0 ||:
    oc get pvcs -o name -n openshift-storage | xargs -n 1 -r oc delete ||:
    oc delete --wait project openshift-storage      ||:
    oc get sc | awk '/\.csi\.ceph\.com/{print $1}'  | xargs -n 1 -r -i oc delete 'sc/{}' ||:
    oc get pv | awk '/noobaa/{print $1}'            | xargs -n 1 -r -i oc delete 'pv/{}' ||:

    for r in `oc get crd | awk '/ceph|ocs|rook|noobaa|object/{print $1}' ||:`; do
        oc get $r --all-namespaces -o name | xargs -n 1 -r oc delete ||:
    done ||:

    while oc get project openshift-storage 2>/dev/null; do
        printf 'Waiting for openshift-storage project to get deleted.\n' >&2
        sleep 1
    done ||:

    for crd in `oc get crd -o name | grep 'ceph\|ocs\|rook\|noobaa\|object' ||:`; do
        oc delete $crd ||:
    done
}

function checkPrerequisites() {
    local out="$(oc get -o name nodes -l cluster.ocs.openshift.io/openshift-storage)"
    local cnt="$(wc -l <<<"$out")"
    if [[ "$cnt" -lt 3 ]]; then
        die "Number of ocs nodes is less than needed: $cnt < 3! Make sure to label at least 3" \
            "nodes with cluster.ocs.openshift.io/openshift-storage=''"
    fi
}


OSD_PV_SIZE="$DEFAULT_OSD_PV_SIZE"

TMPARGS="$(getopt -o ur:s:h --long "$(join , "${long_options[@]}")" \
                      -n "$(basename ${BASH_SOURCE[@]})" -- "$@")"

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
