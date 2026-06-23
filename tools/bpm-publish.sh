#!/bin/sh
# bpm-publish.sh — pull built .bpm from the cloud builder, index+sign, deploy to
# the repo server, and verify over HTTP. EXPERIMENTAL (.bpm production flip).
#
# Usage: tools/bpm-publish.sh
# Env (override as needed):
set -eu
VM_KEY=${VM_KEY:-/home/mmzs/.ssh/blueberry.pem}
VM=${VM:-admin@13.48.84.20}
VM_OUT=${VM_OUT:-/home/admin/bpm-out}
STAGE=${STAGE:-/home/mmzs/projects/blueberry-build/bpm-stage}
REPO_HOST=${REPO_HOST:-root@192.168.0.79}
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}
ASKPASS=${ASKPASS:-/tmp/askpass.sh}

mkdir -p "$STAGE"
echo "==> pulling .bpm from $VM"
rsync -az -e "ssh -i $VM_KEY -o StrictHostKeyChecking=no" "$VM:$VM_OUT/"'*.bpm' "$STAGE/"
echo "    pulled $(ls "$STAGE"/*.bpm 2>/dev/null | wc -l) packages"

echo "==> indexing + signing (bpmrepo.sh)"
sh "$(dirname "$0")/bpmrepo.sh" "$STAGE"

echo "==> deploying to $REPO_HOST:$REPO_DIR"
SSH="setsid -w ssh -o StrictHostKeyChecking=no"
SCP="setsid -w scp -o StrictHostKeyChecking=no"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
$SCP "$STAGE"/*.bpm "$STAGE/bpm.index" "$STAGE/bpm.index.sig" "$REPO_HOST:$REPO_DIR/"
echo "==> verifying over Cloudflare"
curl -fsSL -H 'Cache-Control: no-cache' https://repo.mmzsigmond.me/bpm.index | grep -c '|' \
  | sed 's/^/    index entries: /'
echo "==> done"
