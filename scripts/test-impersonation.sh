
#!/usr/bin/env bash
set -euo pipefail

PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
SCOPE="https://www.googleapis.com/auth/cloud-platform"

# Temporary files containing sensitive responses
RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE"' EXIT

# Register secret for GitHub Actions log masking
mask_secret() {
  echo "::add-mask::$1"
}

# Print JSON, replacing known tokens with placeholders
print_json() {
  jq \
    --arg github "${GITHUB_TOKEN:-}" \
    --arg sts "${STS_TOKEN:-}" \
    --arg sa "${SA_TOKEN:-}" \
    '
    walk(
      if type == "string" then
        (if $github != "" then
          split($github) | join("<MASKED>")
        else . end)
        | (if $sts != "" then
          split($sts) | join("<MASKED>")
        else . end)
        | (if $sa != "" then
          split($sa) | join("<MASKED>")
        else . end)
      else . end
    )
    '
}

# Print HTTP status and safely sanitized response
show_response() {
  local status="$1"

  echo "HTTP Status: ${status}"
  echo "Response Body:"

  if jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
    print_json < "$RESPONSE_FILE"
  else
    echo "(Non-JSON response; body omitted)"
  fi

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    echo "Request failed"
    exit 1
  fi
}

# --------------------------------------------------
# Step 1: GitHub OIDC ID Token
# --------------------------------------------------
echo "::group::Step 1 - GitHub OIDC ID Token"

# Omit query string from printed URL
GITHUB_ENDPOINT="${ACTIONS_ID_TOKEN_REQUEST_URL%%\?*}"
GITHUB_AUDIENCE="https://iam.googleapis.com/${PROVIDER}"

echo "Request:"
echo "  Method: GET"
echo "  Endpoint: ${GITHUB_ENDPOINT}"
echo "  Query:"
echo "    audience: ${GITHUB_AUDIENCE}"
echo "    (GitHub-provided query parameters omitted)"
echo "  Headers:"
echo "    Authorization: Bearer <MASKED>"

HTTP_STATUS=$(curl -sS -G \
  -o "$RESPONSE_FILE" \
  -w "%{http_code}" \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${GITHUB_AUDIENCE}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}")

echo "Response:"
echo "HTTP Status: ${HTTP_STATUS}"

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "GitHub OIDC request failed"
  exit 1
fi

GITHUB_TOKEN=$(jq -er '.value' "$RESPONSE_FILE")
mask_secret "$GITHUB_TOKEN"

echo "Response Body:"
jq '{value:"<MASKED>"}' "$RESPONSE_FILE"
echo "::endgroup::"

# --------------------------------------------------
# Step 2: Google Cloud STS
# --------------------------------------------------
echo "::group::Step 2 - Google Cloud STS"

STS_ENDPOINT="https://sts.googleapis.com/v1/token"
STS_AUDIENCE="//iam.googleapis.com/${PROVIDER}"

echo "Request:"
echo "  Method: POST"
echo "  Endpoint: ${STS_ENDPOINT}"
echo "  Headers:"
echo "    Content-Type: application/x-www-form-urlencoded"
echo "  Body:"

jq -n \
  --arg audience "$STS_AUDIENCE" \
  --arg scope "$SCOPE" \
  '{
    audience: $audience,
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
    scope: $scope,
    subject_token: "<MASKED>"
  }'

HTTP_STATUS=$(curl -sS \
  -o "$RESPONSE_FILE" \
  -w "%{http_code}" \
  -X POST "$STS_ENDPOINT" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "audience=${STS_AUDIENCE}" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "scope=${SCOPE}" \
  --data-urlencode "subject_token=${GITHUB_TOKEN}")

if [[ "$HTTP_STATUS" == "200" ]]; then
  STS_TOKEN=$(jq -er '.access_token' "$RESPONSE_FILE")
  mask_secret "$STS_TOKEN"
fi

echo "Response:"
show_response "$HTTP_STATUS"
echo "::endgroup::"

# --------------------------------------------------
# Step 3: Service Account Impersonation
# --------------------------------------------------
echo "::group::Step 3 - Service Account Impersonation"

SA_ENDPOINT="https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SERVICE_ACCOUNT}:generateAccessToken"

SA_REQUEST=$(jq -n --arg scope "$SCOPE" '{
  scope: [$scope],
  lifetime: "3600s"
}')

echo "Request:"
echo "  Method: POST"
echo "  Endpoint: ${SA_ENDPOINT}"
echo "  Headers:"
echo "    Authorization: Bearer <MASKED:STS_TOKEN>"
echo "    Content-Type: application/json"
echo "  Body:"
echo "$SA_REQUEST" | jq .

HTTP_STATUS=$(curl -sS \
  -o "$RESPONSE_FILE" \
  -w "%{http_code}" \
  -X POST "$SA_ENDPOINT" \
  -H "Authorization: Bearer ${STS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$SA_REQUEST")

if [[ "$HTTP_STATUS" == "200" ]]; then
  SA_TOKEN=$(jq -er '.accessToken' "$RESPONSE_FILE")
  mask_secret "$SA_TOKEN"
fi

echo "Response:"
show_response "$HTTP_STATUS"
echo "::endgroup::"

# --------------------------------------------------
# Step 4: Cloud Resource Manager API
# --------------------------------------------------
echo "::group::Step 4 - Cloud Resource Manager API"

RESOURCE_ENDPOINT="https://cloudresourcemanager.googleapis.com/v3/projects/${PROJECT_ID}"

echo "Request:"
echo "  Method: GET"
echo "  Endpoint: ${RESOURCE_ENDPOINT}"
echo "  Headers:"
echo "    Authorization: Bearer <MASKED:SA_TOKEN>"

HTTP_STATUS=$(curl -sS \
  -o "$RESPONSE_FILE" \
  -w "%{http_code}" \
  -X GET "$RESOURCE_ENDPOINT" \
  -H "Authorization: Bearer ${SA_TOKEN}")

echo "Response:"
show_response "$HTTP_STATUS"
echo "::endgroup::"

echo "All steps succeeded"
