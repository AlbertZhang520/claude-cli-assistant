#!/usr/bin/env bash

redact_stream() {
  sed -E \
    -e 's#([A-Za-z_]*(BASE_URL|base_url)=)[^[:space:];]+#\1<configured>#g' \
    -e 's#([A-Za-z_]*(API_KEY|api_key|AUTH_TOKEN|auth_token|BEARER_TOKEN|bearer_token|TOKEN|token|SECRET|secret|PASSWORD|password)=)[^[:space:];]+#\1<redacted>#g' \
    -e 's#(Authorization: Bearer )[A-Za-z0-9._~+\/=-]+#\1<redacted>#g' \
    -e 's#sk-[A-Za-z0-9_-]{12,}#<redacted-key>#g' \
    -e 's#(xai-|gsk_|github_pat_|ghp_)[A-Za-z0-9_-]{12,}#<redacted-key>#g' \
    -e 's#AKIA[0-9A-Z]{16}#<redacted-aws-key>#g' \
    -e 's#-----BEGIN [A-Z ]*PRIVATE KEY-----#<redacted-private-key>#g' \
    -e 's#eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+#<redacted-jwt>#g'
}
