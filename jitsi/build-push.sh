#!/usr/bin/env bash
# =============================================================================
# build-push.sh — Build and push OpenShift-compatible Jitsi images to Quay.io
#
# Usage:
#   ./build-push.sh                        # build + push all components
#   ./build-push.sh --component meet       # single component only
#   ./build-push.sh --version stable-9909  # pin a specific upstream tag
#   ./build-push.sh --skip-push            # local build only, no push
#   ./build-push.sh --setup-branch        # create git branch first, then build
#
# Prerequisites:
#   - podman >= 4.x  (or buildah >= 1.28)
#   - Logged into quay.io:  podman login quay.io
#   - Run from the root of the jitsi-openshift directory
#
# Quay.io target:  quay.io/ryan_nix/jitsi-openshift:<component>[-<version>]
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

REGISTRY="quay.io"
NAMESPACE="ryan_nix"
REPO="jitsi-openshift"

# Upstream Jitsi release tag. Override with:  VERSION=stable-9909 ./build-push.sh
# "stable" always resolves to the latest stable release.
VERSION="${VERSION:-stable}"

# Build platform — amd64 only. Add "linux/arm64" to PLATFORMS for multi-arch.
PLATFORMS=("linux/amd64")

# All four Jitsi components, in dependency order
ALL_COMPONENTS=("meet" "prosody" "jicofo" "jvb")

# Git branch name for the Jitsi port work
GIT_BRANCH="feat/jitsi-openshift-port"

# ── Argument parsing ──────────────────────────────────────────────────────────

COMPONENT=""
SKIP_PUSH=false
SETUP_BRANCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component|-c)
      COMPONENT="$2"; shift 2 ;;
    --version|-v)
      VERSION="$2"; shift 2 ;;
    --skip-push)
      SKIP_PUSH=true; shift ;;
    --setup-branch)
      SETUP_BRANCH=true; shift ;;
    --help|-h)
      sed -n '3,15p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${CYAN}[build]${RESET} $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error() { echo -e "${RED}[error]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# Detect container build tool: prefer podman, fall back to buildah raw CLI
detect_builder() {
  if command -v podman &>/dev/null; then
    echo "podman"
  elif command -v buildah &>/dev/null; then
    echo "buildah"
  else
    die "Neither podman nor buildah found. Install podman: dnf install podman"
  fi
}

BUILDER=$(detect_builder)
log "Using container builder: ${BOLD}${BUILDER}${RESET}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

# Verify we're in the right directory
[[ -f "Containerfile.meet" ]] || \
  die "Containerfile.meet not found. Run this script from the jitsi-openshift directory."

# Verify registry login
log "Verifying Quay.io login..."
if ! ${BUILDER} login --get-login "${REGISTRY}" &>/dev/null; then
  warn "Not logged into ${REGISTRY}."
  echo -e "${BOLD}Logging in to ${REGISTRY}...${RESET}"
  ${BUILDER} login "${REGISTRY}" || die "Login to ${REGISTRY} failed."
fi
ok "Authenticated to ${REGISTRY}"

# ── Git branch setup (optional) ───────────────────────────────────────────────

if [[ "${SETUP_BRANCH}" == "true" ]]; then
  log "Setting up git branch: ${BOLD}${GIT_BRANCH}${RESET}"

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository. Clone your repo first."
  fi

  CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
  log "Current branch: ${CURRENT_BRANCH}"

  if git show-ref --verify --quiet "refs/heads/${GIT_BRANCH}"; then
    warn "Branch '${GIT_BRANCH}' already exists — checking it out."
    git checkout "${GIT_BRANCH}"
  else
    log "Creating branch '${GIT_BRANCH}' from ${CURRENT_BRANCH}..."
    git checkout -b "${GIT_BRANCH}"
    ok "Branch '${GIT_BRANCH}' created."
  fi

  # Stage the Containerfiles if this is a fresh branch
  git add Containerfile.* build-push.sh 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -m "feat: add OpenShift-compatible Jitsi Containerfiles

    - Remap nginx from port 80 → 8080 (restricted SCC, no NET_BIND_SERVICE)
    - All writable paths: UID 1001 / GID 0 / chmod g=u (arbitrary UID pattern)
    - NSS wrapper entrypoints for Java components (jicofo, jvb)
    - Remove hostNetwork dependency from JVB
    - Build/push script targeting quay.io/ryan_nix/jitsi-openshift

    Resolves root filesystem SCC violations from upstream Helm chart."
    ok "Containerfiles committed to ${GIT_BRANCH}"
  else
    log "Nothing new to commit on this branch."
  fi
fi

# ── Build and push ────────────────────────────────────────────────────────────

COMPONENTS=("${ALL_COMPONENTS[@]}")
if [[ -n "${COMPONENT}" ]]; then
  # Validate the requested component
  valid=false
  for c in "${ALL_COMPONENTS[@]}"; do
    [[ "${COMPONENT}" == "${c}" ]] && valid=true
  done
  ${valid} || die "Unknown component '${COMPONENT}'. Valid: ${ALL_COMPONENTS[*]}"
  COMPONENTS=("${COMPONENT}")
fi

BUILD_START=$(date +%s)
BUILT=()
FAILED=()

for comp in "${COMPONENTS[@]}"; do
  CONTAINERFILE="Containerfile.${comp}"

  [[ -f "${CONTAINERFILE}" ]] || {
    warn "Skipping ${comp}: ${CONTAINERFILE} not found."
    continue
  }

  # Primary tag: quay.io/ryan_nix/jitsi-openshift:meet
  IMAGE_BASE="${REGISTRY}/${NAMESPACE}/${REPO}"
  TAG_COMPONENT="${IMAGE_BASE}:${comp}"
  # Versioned tag: quay.io/ryan_nix/jitsi-openshift:meet-stable
  TAG_VERSIONED="${IMAGE_BASE}:${comp}-${VERSION}"

  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Component : ${BOLD}${comp}${RESET}"
  log "Image     : ${TAG_COMPONENT}"
  log "Versioned : ${TAG_VERSIONED}"
  log "Platforms : ${PLATFORMS[*]}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  BUILD_OK=true

  for platform in "${PLATFORMS[@]}"; do
    PLATFORM_TAG="${TAG_COMPONENT}-$(echo "${platform}" | tr '/' '-')"

    log "Building for ${platform}..."

    if [[ "${BUILDER}" == "podman" ]]; then
      podman build \
        --platform "${platform}" \
        --build-arg JITSI_VERSION="${VERSION}" \
        --format oci \
        --pull=newer \
        -f "${CONTAINERFILE}" \
        -t "${PLATFORM_TAG}" \
        . || { error "Build failed for ${comp} (${platform})"; BUILD_OK=false; break; }

    elif [[ "${BUILDER}" == "buildah" ]]; then
      buildah build \
        --platform "${platform}" \
        --build-arg JITSI_VERSION="${VERSION}" \
        --format oci \
        -f "${CONTAINERFILE}" \
        -t "${PLATFORM_TAG}" \
        . || { error "Build failed for ${comp} (${platform})"; BUILD_OK=false; break; }
    fi

    ok "Built: ${PLATFORM_TAG}"
  done

  if [[ "${BUILD_OK}" == "false" ]]; then
    FAILED+=("${comp}")
    continue
  fi

  # For single-platform builds: retag platform image → component tag + versioned tag
  # For multi-platform: you'd use a manifest list here (see multi-arch note below)
  if [[ ${#PLATFORMS[@]} -eq 1 ]]; then
    PLATFORM_TAG="${TAG_COMPONENT}-$(echo "${PLATFORMS[0]}" | tr '/' '-')"
    ${BUILDER} tag "${PLATFORM_TAG}" "${TAG_COMPONENT}"
    ${BUILDER} tag "${PLATFORM_TAG}" "${TAG_VERSIONED}"
    ok "Tagged: ${TAG_COMPONENT}"
    ok "Tagged: ${TAG_VERSIONED}"
  fi

  if [[ "${SKIP_PUSH}" == "false" ]]; then
    log "Pushing ${TAG_COMPONENT}..."
    ${BUILDER} push "${TAG_COMPONENT}" || \
      { error "Push failed for ${TAG_COMPONENT}"; FAILED+=("${comp}"); continue; }
    ok "Pushed: ${TAG_COMPONENT}"

    log "Pushing ${TAG_VERSIONED}..."
    ${BUILDER} push "${TAG_VERSIONED}" || \
      { error "Push failed for ${TAG_VERSIONED}"; FAILED+=("${comp}"); continue; }
    ok "Pushed: ${TAG_VERSIONED}"
  else
    warn "Skipping push (--skip-push mode): ${TAG_COMPONENT}"
  fi

  BUILT+=("${comp}")
done

# ── Summary ───────────────────────────────────────────────────────────────────

BUILD_END=$(date +%s)
ELAPSED=$(( BUILD_END - BUILD_START ))

echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Build Summary${RESET}"
log "Elapsed   : ${ELAPSED}s"
log "Version   : ${VERSION}"
if [[ ${#BUILT[@]} -gt 0 ]]; then
  ok "Succeeded : ${BUILT[*]}"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  error "Failed    : ${FAILED[*]}"
fi
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Print the final image references for copy-paste into your OpenShift manifests
if [[ "${SKIP_PUSH}" == "false" && ${#BUILT[@]} -gt 0 ]]; then
  echo ""
  log "Image references for OpenShift manifests:"
  for comp in "${BUILT[@]}"; do
    echo "  ${REGISTRY}/${NAMESPACE}/${REPO}:${comp}"
  done
fi

# Exit with error if anything failed
[[ ${#FAILED[@]} -eq 0 ]] || exit 1

# =============================================================================
# MULTI-ARCH NOTE (when you're ready to add arm64):
#
# Uncomment arm64 in PLATFORMS at the top:
#   PLATFORMS=("linux/amd64" "linux/arm64")
#
# Then replace the single-platform retag block above with a manifest list:
#
#   ${BUILDER} manifest create "${TAG_COMPONENT}"
#   for platform in "${PLATFORMS[@]}"; do
#     PLATFORM_TAG="${TAG_COMPONENT}-$(echo "${platform}" | tr '/' '-')"
#     ${BUILDER} manifest add "${TAG_COMPONENT}" "${PLATFORM_TAG}"
#   done
#   ${BUILDER} manifest push --all "${TAG_COMPONENT}" \
#     "docker://${TAG_COMPONENT}"
#
# This mirrors the pattern in your containertools GitHub Actions workflow.
# =============================================================================
