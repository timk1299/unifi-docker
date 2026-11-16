#!/usr/bin/env bash
#
# EXPERIMENTAL: hide the "Upgrade to UniFi OS Server" modal that the Network
# Application (11.x+) shows to the owner after every login on standalone installs.
#
# The modal component keeps its open state in `useState(!dismissed)`; this patch
# makes it start closed (`useState(!1)`). The rest of the UI is untouched.
# By default the build fails if the modal exists but cannot be patched (e.g. after
# Ubiquiti changes the bundle). Set UNIFI_UPGRADE_MODAL_PATCH=optional to only warn.

set -euo pipefail

WEBROOT=${1:-/usr/lib/unifi/webapps/ROOT}
MODE=${UNIFI_UPGRADE_MODAL_PATCH:-required}

mapfile -t files < <(grep -rlF 'NETWORK_SERVER_UPGRADE_MODAL_DISMISSED}-' "${WEBROOT}" --include='*.js' || true)

if [ "${#files[@]}" -eq 0 ]; then
    echo "uos-webui-patch: upgrade modal component not found, nothing to patch"
    exit 0
fi

patched=0
for f in "${files[@]}"; do
    if perl -0777 -ne 'exit(/NETWORK_SERVER_UPGRADE_MODAL_DISMISSED\}-.{0,600}?useState\)\(!1\)/s ? 0 : 1)' "${f}"; then
        echo "uos-webui-patch: ${f#"${WEBROOT}"/} already patched"
        patched=$((patched + 1))
        continue
    fi
    # Within the modal component (anchored at the dismissed-key template literal),
    # replace the first `useState)(!<var>)` with `useState)(!1)`.
    if perl -0777 -i -pe '
        s{(NETWORK_SERVER_UPGRADE_MODAL_DISMISSED\}-.{0,600}?useState\)\()![A-Za-z_\$][\w\$]*\)}{$1!1)}s
            and $main::hit = 1;
        END { exit($main::hit ? 0 : 3) }
    ' "${f}"; then
        echo "uos-webui-patch: patched ${f#"${WEBROOT}"/}"
        patched=$((patched + 1))
    else
        echo "uos-webui-patch: pattern not found in ${f#"${WEBROOT}"/}" >&2
    fi
done

if [ "${patched}" -eq 0 ] && [ "${MODE}" = "required" ]; then
    echo "uos-webui-patch: failed to patch the upgrade modal" >&2
    exit 1
fi
