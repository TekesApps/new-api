#!/usr/bin/env bash
set -euo pipefail

version="v1.0.0-rc.38-tekes.1"
archive="new-api-${version}-linux-amd64.tar.gz"
checksum="new-api-${version}-linux-amd64.sha256"
release_base="https://github.com/TekesApps/new-api/releases/download/${version}"
container="${1:-}"

if [[ -z "$container" ]]; then
    mapfile -t candidates < <(docker ps --filter publish=3000 --format '{{.Names}}')
    if [[ "${#candidates[@]}" -ne 1 ]]; then
        echo "Expected exactly one running container publishing port 3000; pass its name as the first argument." >&2
        docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' >&2
        exit 1
    fi
    container="${candidates[0]}"
fi

if ! docker container inspect "$container" >/dev/null 2>&1; then
    echo "Container not found: $container" >&2
    exit 1
fi

work_dir="$(mktemp -d)"
replacement_container=""
cleanup() {
    if [[ -n "$replacement_container" ]]; then
        docker rm -f "$replacement_container" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

curl --fail --location --retry 3 --output "$work_dir/$archive" "$release_base/$archive"
curl --fail --location --retry 3 --output "$work_dir/$checksum" \
    "$release_base/$checksum"
(
    cd "$work_dir"
    sha256sum --check "$checksum"
)
gzip --decompress --stdout "$work_dir/$archive" | docker load

replacement_container="$(docker create "tekesapps/new-api:${version}")"
docker cp "$replacement_container:/new-api" "$work_dir/new-api"
docker rm "$replacement_container" >/dev/null
replacement_container=""

docker cp "$container:/new-api" "$work_dir/new-api.previous"
docker stop "$container" >/dev/null

rollback() {
    echo "Upgrade health check failed; restoring the previous binary." >&2
    docker cp "$work_dir/new-api.previous" "$container:/new-api"
    docker start "$container" >/dev/null
}

if ! docker cp "$work_dir/new-api" "$container:/new-api"; then
    rollback
    exit 1
fi
docker start "$container" >/dev/null

healthy=false
for _ in {1..30}; do
    if curl --fail --silent --show-error http://127.0.0.1:3000/api/status >/dev/null; then
        healthy=true
        break
    fi
    sleep 1
done
if [[ "$healthy" != true ]]; then
    docker stop "$container" >/dev/null || true
    rollback
    exit 1
fi

echo "Upgraded $container to $version and verified /api/status."
