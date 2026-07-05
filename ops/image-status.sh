#!/usr/bin/env bash
# ops/image-status.sh
#
# Print a table of running containers with, for each:
#   SERVICE  – container name
#   CURRENT  – tag (and short digest if pinned) the container is running
#   CREATED  – container creation date
#   LATEST   – latest version tag available upstream
#   STATUS   – up to date / behind / update available / unknown
#
# HOW IT DECIDES
#   • Channel tags (latest, stable, release, nightly, …): compares the digest
#     the image was pulled with (docker image inspect .RepoDigests) against the
#     digest that tag currently points at upstream. Different => "update
#     available". This is the authoritative "your tag moved" signal.
#   • Version tags (3.4.4, v1.13.3, 1.36.0-alpine, 14-vectorchord…, …): lists
#     ALL upstream tags (following registry pagination), filters to version-like
#     tags (dropping arch/os/junk tags), picks the highest by `sort -V`. If that
#     differs from the running tag => "behind". If equal, checks whether the
#     same tag's digest has moved => "tag updated".
#
# CAVEATS
#   • "Latest" is best-effort: it may surface a pre-release or a different
#     variant/edge tag. Treat it as a hint — read the actual tags before
#     bumping, especially for digest-pinned images (immich-postgres).
#   • Hits docker hub / ghcr.io / gcr.io anonymously; rate limits apply.
#   • RepoDigests stores the manifest-list digest as pulled; comparing it to the
#     upstream tag's current list digest is accurate for "has the tag moved".
#
# Requires: docker, curl, jq, column, awk, sed, sort, grep
set -euo pipefail

for dep in docker curl jq column awk sed sort grep; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
done

CHANNEL_RE='^(latest|stable|release|nightly|main|master)$'
# tags to discard when hunting for the latest version tag. Patterns are kept
# specific (anchored / hyphenated) so they don't match substrings of real
# version names — e.g. bare "rc" would otherwise hit "ve**rc**hord",
# "pgve**rc**tor", etc. and nuke every immich-postgres tag.
JUNK_RE='(windows|windowsservercore|nanoserver|ltsc|servercore|amd64|aarch64|arm64|arm32|armv[0-9]|armhf|s390x?|ppc64le|i386|x86|webauthn|[-.]rc[0-9]|[-.]beta[0-9]|[-.]alpha[0-9]|[-.]pre[0-9]|^dev$|[-.]dev|[-.]test|^[0-9a-f]{6,})'

# ── registry auth + API ──────────────────────────────────────────────
get_token() {
  local registry=$1 repo=$2
  case "$registry" in
    registry-1.docker.io)
      curl -fsS --max-time 10 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        | jq -r '.token'
      ;;
    ghcr.io)
      curl -fsS --max-time 10 \
        "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
        | jq -r '.token'
      ;;
    gcr.io|*.gcr.io)
      curl -fsS --max-time 10 \
        "https://${registry}/v2/token?scope=repository:${repo}:pull" \
        | jq -r '.token'
      ;;
    *)
      echo ""
      ;;
  esac
}

# List ALL tags for a repo, following registry pagination. Prints tags, one per line.
list_all_tags() {
  local registry=$1 repo=$2 token=$3
  local url="https://${registry}/v2/${repo}/tags/list"
  local last="" pages=0
  # hard cap on pages so a misbehaving registry can't loop forever
  while [[ -n "$url" && "$url" != "$last" && $pages -lt 30 ]]; do
    last="$url"; pages=$((pages+1))
    local hdr
    hdr=$(mktemp) || break
    local body
    body=$(curl -fsS --max-time 15 -D "$hdr" \
            -H "Authorization: Bearer ${token}" "$url" 2>/dev/null) || { rm -f "$hdr"; break; }
    printf '%s' "$body" | jq -r '.tags[]?' 2>/dev/null || true
    # follow Link: </path>; rel="next"
    local next
    next=$(awk 'tolower($1)=="link:"{print $2}' "$hdr" | sed -e 's/[<>]//g' -e 's/;.*//' | head -1)
    rm -f "$hdr"
    if [[ -z "$next" ]]; then
      url=""
    elif [[ "$next" == /* ]]; then
      url="https://${registry}${next}"
    else
      url="$next"
    fi
  done
}

# HEAD the manifest for a tag, return its Docker-Content-Digest
tag_digest() {
  local registry=$1 repo=$2 tag=$3 token=$4
  curl -fsSI --max-time 15 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://${registry}/v2/${repo}/manifests/${tag}" \
    | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# ── image ref parsing ────────────────────────────────────────────────
# Echoes: registry<TAB>repo<TAB>tag<TAB>digest  (digest empty if not pinned)
parse_image() {
  local img=$1 digest=""
  if [[ "$img" == *@sha256:* ]]; then
    digest="${img##*@}"; img="${img%@*}"
  fi

  # split off the last path segment (it may carry :tag)
  local last prefix
  last="${img##*/}"            # immich-server:v2 | traefik:3.4.4 | deluge:2.1.1
  prefix="${img%"$last"}"      # ghcr.io/immich-app/ | (empty) | linuxserver/
  prefix="${prefix%/}"         # drop trailing slash

  local tag="latest"
  if [[ "$last" == *:* ]]; then
    tag="${last##*:}"
    last="${last%%:*}"
  fi

  # reconstruct the untagged name
  local name
  if [[ -n "$prefix" ]]; then
    name="${prefix}/${last}"
  else
    name="$last"
  fi

  # registry / repo split
  local registry repo first
  first="${name%%/*}"
  if [[ "$first" == *.* || "$first" == *:* ]]; then
    registry="$first"
    repo="${name#*/}"
    [[ "$registry" == "docker.io" ]] && registry="registry-1.docker.io"
  else
    registry="registry-1.docker.io"
    if [[ "$name" == */* ]]; then
      repo="$name"
    else
      repo="library/$name"
    fi
  fi

  printf '%s\t%s\t%s\t%s\n' "$registry" "$repo" "$tag" "$digest"
}

# ── per-container work ───────────────────────────────────────────────
process() {
  local name=$1 image=$2
  local created cfg
  created=$(docker inspect -f '{{.Created}}' "$name" 2>/dev/null | cut -dT -f1 || true)
  [[ -z "$created" ]] && created="?"

  # Config.Image is the exact ref used to create the container (resolves env vars)
  cfg=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
  [[ -n "$cfg" ]] && image="$cfg"

  local registry repo tag digest
  IFS=$'\t' read -r registry repo tag digest < <(parse_image "$image")

  local current="$tag"
  [[ -n "$digest" ]] && current="${tag}@${digest:7:12}..."

  # digest the image was pulled with (RepoDigests is on the IMAGE, not the container)
  local img_id run_digest=""
  img_id=$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)
  if [[ -n "$img_id" ]]; then
    run_digest=$(docker image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$img_id" 2>/dev/null \
      | awk '{print $1}' | sed 's/.*@//' || true)
  fi

  local token tags latest="" status="?"
  token=$(get_token "$registry" "$repo" 2>/dev/null || true)

  if [[ -z "$token" ]]; then
    latest="-"; status="no auth"
  else
    tags=$(list_all_tags "$registry" "$repo" "$token" 2>/dev/null || true)

    if [[ -z "$tags" ]]; then
      latest="-"; status="no tags"
    elif [[ "$tag" =~ $CHANNEL_RE ]]; then
      latest="${tag} (channel)"
      local up_digest
      up_digest=$(tag_digest "$registry" "$repo" "$tag" "$token" 2>/dev/null || true)
      if [[ -n "$run_digest" && -n "$up_digest" ]]; then
        [[ "$run_digest" == "$up_digest" ]] && status="up to date" || status="update available"
      else
        status="unknown"
      fi
    else
      # keep only genuine version tags: start with [v]?<digit> (or "version-v?…"),
      # drop arch / os / pre-release / commit-sha junk. `|| true` so an empty
      # filter result (no version tags) doesn't abort under set -e + pipefail.
      latest=$(printf '%s\n' "$tags" \
        | grep -vEi "$JUNK_RE" \
        | grep -E '^[vV]?[0-9]|^version-v?[0-9]' \
        | grep -vE "$CHANNEL_RE" \
        | sort -V | tail -1 || true)
      [[ -z "$latest" ]] && latest="$tag"
      if [[ "$latest" == "$tag" ]]; then
        local up_digest
        up_digest=$(tag_digest "$registry" "$repo" "$tag" "$token" 2>/dev/null || true)
        if [[ -n "$run_digest" && -n "$up_digest" ]]; then
          [[ "$run_digest" == "$up_digest" ]] && status="up to date" || status="tag updated"
        else
          status="up to date?"
        fi
      else
        status="behind"
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$current" "$created" "$latest" "$status"
}

# ── main ─────────────────────────────────────────────────────────────
main() {
  mapfile -t CONTAINERS < <(docker ps --format '{{.Names}}\t{{.Image}}')
  if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "no running containers" >&2; exit 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
  TMPDIR_CLEANUP="$tmpdir"   # global so the EXIT trap sees it under `set -u`
  trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT

  local i=0 line name image
  local pids=()
  for line in "${CONTAINERS[@]}"; do
    name="${line%%	*}"; image="${line#*	}"
    ( process "$name" "$image" > "$tmpdir/$i.out" 2>/dev/null ) &
    pids+=( $! )
    ((++i))
  done

  # Progress indicator: each registry call is bounded, but with ~18 containers
  # and pagination the whole run can take a couple of minutes. Poll finished
  # PIDs so the user sees it's working, not hung.
  local total=${#pids[@]} finished=0
  while [[ $finished -lt $total ]]; do
    finished=0
    for pid in "${pids[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then finished=$((finished+1)); fi
    done
    printf '\rchecking upstream registries... %d/%d' "$finished" "$total" >&2
    sleep 0.5
  done
  printf '\n' >&2
  wait || true

  local rows=()
  i=0
  for line in "${CONTAINERS[@]}"; do
    if [[ -s "$tmpdir/$i.out" ]]; then
      rows+=( "$(cat "$tmpdir/$i.out")" )
    else
      name="${line%%	*}"
      rows+=( "$(printf '%s\t%s\t%s\t%s\t%s' "$name" '?' '?' '?' 'error')" )
    fi
    ((++i))
  done

  {
    printf 'SERVICE\tCURRENT\tCREATED\tLATEST\tSTATUS\n'
    printf '%s\n' "${rows[@]}" | sort
  } | column -t -s$'\t'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
