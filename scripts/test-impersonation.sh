
#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------
PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

# --------------------------------------------------
# Step 1: GitHub OIDC ID Token
# --------------------------------------------------
echo "::group::Step 1 - GitHub OIDC ID Token"

GITHUB_RESPONSE=$(curl --fail-with-body -sS -G \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=https://iam.googleapis.com/${PROVIDER}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}")

GITHUB_TOKEN=$(jq -er '.value' <<< "$GITHUB_RESPONSE")
echo "::add-mask::${GITHUB_TOKEN}"

echo "GitHub OIDC ID Token obtained"
echo "::endgroup::"

# --------------------------------------------------
# Step 2: Google Cloud STS Token Exchange
# --------------------------------------------------
echo "::group::Step 2 - Google Cloud STS"

STS_RESPONSE=$(curl --fail-with-body -sS \
  -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "audience=//iam.googleapis.com/${PROVIDER}" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "scope=https://www.googleapis.com/auth/cloud-platform" \
  --data-urlencode "subject_token=${GITHUB_TOKEN}")

STS_TOKEN=$(jq -er '.access_token' <<< "$STS_RESPONSE")
echo "::add-mask::${STS_TOKEN}"

echo "STS response (token redacted):"
jq 'del(.access_token)' <<< "$STS_RESPONSE"

echo "::endgroup::"

# --------------------------------------------------
# Step 3: Service Account Impersonation
# --------------------------------------------------
echo "::group::Step 3 - Service Account Impersonation"

SA_RESPONSE=$(curl --fail-with-body -sS \
  -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SERVICE_ACCOUNT}:generateAccessToken" \
  -H "Authorization: Bearer ${STS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "scope": [
      "https://www.googleapis.com/auth/cloud-platform"
    ],
    "lifetime": "3600s"
  }')

SA_TOKEN=$(jq -er '.accessToken' <<< "$SA_RESPONSE")
echo "::add-mask::${SA_TOKEN}"

echo "Service Account response (token redacted):"
jq 'del(.accessToken)' <<< "$SA_RESPONSE"

echo "::endgroup::"

# --------------------------------------------------
# Step 4: Access Google Cloud API
# --------------------------------------------------
echo "::group::Step 4 - Cloud Resource Manager API"

PROJECT_RESPONSE=$(curl --fail-with-body -sS \
  "https://cloudresourcemanager.googleapis.com/v3/projects/${PROJECT_ID}" \
  -H "Authorization: Bearer ${SA_TOKEN}")

echo "Cloud Resource Manager response:"
jq '{name, projectId, displayName, state}' \
  <<< "$PROJECT_RESPONSE"

echo "::endgroup::"

echo "All steps succeeded"
