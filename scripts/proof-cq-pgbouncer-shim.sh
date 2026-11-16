#!/usr/bin/env bash
# pgbouncer <ini>: PgBouncer for proof-cq.sh's P3 on a box without the binary - scripts/proof-cq-box.sh puts this
# file on the PATH as 'pgbouncer'. The image proof-pooler.sh uses, on the host network. The ini and its users.txt are
# copied into a folder of this shim's own (readable by the image's user), never the proof's WORK folder (it holds the
# proof's passwords); the container stops on TERM and the folder goes.
set -u
ini=$(realpath "$1"); src=$(dirname "$ini"); nd=$(mktemp -d); name="cqpgb_$$"
trap 'docker stop -t 2 "$name" >/dev/null 2>&1; rm -rf "$nd"' EXIT
trap 'exit 0' TERM INT
sed "s#^auth_file = .*#auth_file = $nd/users.txt#" "$ini" > "$nd/pgb.ini"; cp "$src/users.txt" "$nd/users.txt"
chmod 755 "$nd"; chmod 644 "$nd/pgb.ini" "$nd/users.txt"
docker run --rm --name "$name" --network host -v "$nd:$nd:ro" --entrypoint pgbouncer "${PGB_IMAGE:-edoburu/pgbouncer:v1.26.1-p0}" "$nd/pgb.ini" &
wait $!
