#!/bin/bash

cd "$WORKING_DIR" || {
  echo "Error moving to the application's root directory."
  exit 1
}

echo ""
read -r -p 'Enter the <DNS Name> to request the certificate: ' dns_name
if [ -z "$dns_name" ]; then
  echo "Error: <DNS Name> is required."
  exit 1
fi

read -r -p 'Enter the <Idempotency Token> for the ACM request: ' idempotency_token
if [ -z "$idempotency_token" ]; then
  echo "Error: <Idempotency Token> is required."
  exit 1
fi

echo ""
echo "REQUESTING ACM CERTIFICATE..."
aws acm request-certificate                                       \
  --domain-name                   "$dns_name"                     \
  --subject-alternative-names     "$AWS_WORKLOADS_ENV.$dns_name"  \
  --idempotency-token             "$idempotency_token"            \
  --validation-method             DNS                             \
  --profile                       "$AWS_WORKLOADS_PROFILE"
echo "DONE!"

echo ""
echo "GETTING CERTIFICATE ARN..."
acm_arn=$(aws acm list-certificates --profile "$AWS_WORKLOADS_PROFILE" | \
  jq -r '.CertificateSummaryList[] | select(.DomainName == '"$dns_name"') | .CertificateArn')
echo "Certificate ARN: $acm_arn"

echo ""
echo "DONE!"
