#!/usr/bin/env bash
# Ships the database and the server together, and only from a green build:
#
#   1. flutter analyze + flutter test + server pytest — any failure stops here
#   2. lists the Supabase migrations that would apply, and asks (--yes skips)
#   3. pushes them, then deploys the server to Cloud Run
#   4. points api.mise.bengid.dev at it and checks it answers
#
# Migrations go first because new server code may need the new schema. That
# only works while every migration is additive — a dropped column breaks the
# server still running until the deploy finishes.
#
# Once per machine:
#   supabase login && supabase link --project-ref mpaulmfgrdnerbepehnt
#   gcloud auth login
# and server/.env holding SUPABASE_SECRET_KEY (and PEXELS_KEY, optional), which
# become Secret Manager secrets the first time they're missing.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=mise-bengid
REGION=us-central1 # one of the regions Cloud Run domain mappings support
SERVICE=mise-api
DOMAIN=api.mise.bengid.dev
SUPABASE_URL=https://mpaulmfgrdnerbepehnt.supabase.co

yes=false
[[ "${1:-}" == "--yes" ]] && yes=true

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

step "Tests"
flutter analyze
flutter test --timeout 45s
(cd server && uv run pytest -q)

step "Pending migrations"
supabase db push --linked --dry-run ||
  die "Supabase isn't linked: supabase login && supabase link --project-ref mpaulmfgrdnerbepehnt"

if ! $yes; then
  read -r -p "Migrate Supabase and deploy $SERVICE to $DOMAIN? [y/N] " answer
  [[ "$answer" == [yY]* ]] || die "Stopped; nothing was changed."
fi

step "Migrating Supabase"
supabase db push --linked --yes

step "Preparing $PROJECT"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com --project "$PROJECT"

# The runtime identity Cloud Run uses unless told otherwise; it needs to read
# the secrets it is handed.
number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
runtime="$number-compute@developer.gserviceaccount.com"

# A secret that doesn't exist yet is created from server/.env, so a fresh
# project needs no hand-run gcloud. One that exists is left alone — rotating a
# key is `gcloud secrets versions add`, on purpose not a side effect of a deploy.
#
# Each secret that ends up in place is appended to `secrets`, the list handed to
# the deploy. Returns 1 when it has nothing to make one from.
secrets=()
ensure_secret() {
  local secret=$1 variable=$2
  if ! gcloud secrets describe "$secret" --project "$PROJECT" >/dev/null 2>&1; then
    local value
    value=$(grep -E "^$variable=" server/.env 2>/dev/null | cut -d= -f2-) || true
    [[ -n "$value" ]] || return 1
    printf '%s' "$value" | gcloud secrets create "$secret" --project "$PROJECT" \
      --replication-policy automatic --data-file=-
  fi
  gcloud secrets add-iam-policy-binding "$secret" --project "$PROJECT" \
    --member "serviceAccount:$runtime" --role roles/secretmanager.secretAccessor \
    >/dev/null
  secrets+=("$variable=$secret:latest")
}
ensure_secret supabase-secret SUPABASE_SECRET_KEY ||
  die "Secret supabase-secret is missing and server/.env has no SUPABASE_SECRET_KEY."
# Optional: without it /photos is a 503 the app reads as "no photos", and the
# Wikipedia fallback carries on. Pexels wasn't issuing keys when this was written.
ensure_secret pexels-key PEXELS_KEY ||
  echo "No Pexels key: deploying without photo search."

step "Deploying $SERVICE"
# --max-instances also caps the per-instance photo rate limit's multiplier;
# see server/app/main.py.
gcloud run deploy "$SERVICE" --source server --project "$PROJECT" \
  --region "$REGION" --allow-unauthenticated --max-instances 2 \
  --set-env-vars "SUPABASE_URL=$SUPABASE_URL" \
  --set-secrets "$(IFS=,; echo "${secrets[*]}")" \
  --quiet

step "Domain"
if ! gcloud beta run domain-mappings describe --domain "$DOMAIN" \
  --project "$PROJECT" --region "$REGION" >/dev/null 2>&1; then
  gcloud beta run domain-mappings create --service "$SERVICE" --domain "$DOMAIN" \
    --project "$PROJECT" --region "$REGION"
fi
# The DNS record to add at bengid.dev's DNS host, once; the certificate is
# issued after it resolves, which can take a while.
gcloud beta run domain-mappings describe --domain "$DOMAIN" \
  --project "$PROJECT" --region "$REGION" \
  --format='table(status.resourceRecords[].type,status.resourceRecords[].name,status.resourceRecords[].rrdata)'

step "Smoke test"
# 401 is the right answer: the server is up and refuses an unsigned caller.
url=$(gcloud run services describe "$SERVICE" --project "$PROJECT" \
  --region "$REGION" --format='value(status.url)')
for base in "https://$DOMAIN" "$url"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/me" || true)
  echo "$base/me → $code"
  [[ "$code" == 401 ]] && { echo "Deployed."; exit 0; }
done
die "The service didn't answer /me with 401; check the logs."
