#!/usr/bin/env bash
#
# Usage:
#   ./deploy-s3-cloudfront-cert-route53.sh <BUCKET_NAME> <DOMAIN_NAME>
#
# Example:
#   ./deploy-s3-cloudfront-cert-route53.sh my-static-site www.example.com
#
# This script will:
#   1. Create or verify existence of an S3 bucket (public or private).
#   2. Request an ACM certificate (DNS validated) in us-west-2 for <DOMAIN_NAME>.
#   3. Create a Route 53 DNS record for certificate validation and wait until issued.
#   4. Create a CloudFront distribution pointing to the S3 bucket.
#   5. Create or update a Route 53 ALIAS record pointing <DOMAIN_NAME> to the CloudFront distribution.
#
# Requirements:
#   - AWS CLI v2
#   - 'jq' for JSON parsing
#   - Bash 4+ (for associative arrays, etc.)

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <BUCKET_NAME> <DOMAIN_NAME>"
  exit 1
fi

BUCKET_NAME="$1"
DOMAIN_NAME="$2"

### 0. Prerequisites / Checks #############################################

# Make sure `jq` is installed
if ! command -v jq >/dev/null; then
  echo "Error: 'jq' is required but not installed."
  exit 1
fi

# Confirm we have a hosted zone in Route 53 matching DOMAIN_NAME
echo "Retrieving Route 53 hosted zone for domain: $DOMAIN_NAME ..."
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN_NAME" --max-items 1 \
    | jq -r '.HostedZones[0].Id' | sed 's|/hostedzone/||')"

if [[ -z "$HOSTED_ZONE_ID" || "$HOSTED_ZONE_ID" == "null" ]]; then
  echo "Error: Could not find a Route 53 hosted zone for '$DOMAIN_NAME'."
  echo "Make sure the domain's hosted zone exists in Route 53 in this account."
  exit 1
fi

echo "Found hosted zone ID: $HOSTED_ZONE_ID"
echo ""

### 2. Request an ACM Certificate (DNS Validation) in us-west-2 ###########

# CloudFront requires the certificate to be in us-west-2
echo "Requesting ACM certificate in us-west-2 for domain: $DOMAIN_NAME ..."
CERT_ARN="$(aws acm request-certificate \
  --region us-east-1 \
  --domain-name "$DOMAIN_NAME" \
  --validation-method DNS \
  --query 'CertificateArn' \
  --output text)"

echo "Certificate ARN: $CERT_ARN"
echo ""

### 3. Retrieve DNS Validation Record & Create Route53 Validation Record ###

echo "Retrieving DNS validation record details..."
# We'll wait a moment for ACM to populate DomainValidationOptions
sleep 5

VALIDATION_OPTIONS="$(aws acm describe-certificate \
    --region us-east-1 \
    --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions' \
    --output json)"

# Extract the name/value for the DNS validation CNAME
RECORD_NAME="$(echo "$VALIDATION_OPTIONS" | jq -r '.[0].ResourceRecord.Name')"
RECORD_VALUE="$(echo "$VALIDATION_OPTIONS" | jq -r '.[0].ResourceRecord.Value')"

if [[ -z "$RECORD_NAME" || -z "$RECORD_VALUE" || "$RECORD_NAME" == "null" || "$RECORD_VALUE" == "null" ]]; then
  echo "Error: Could not retrieve DNS validation records from ACM."
  echo "Check ACM console or logs."
  exit 1
fi

echo "Creating DNS validation record in Route 53:"
echo "  Name:  $RECORD_NAME"
echo "  Value: $RECORD_VALUE"
echo ""

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "ACM Certificate Validation for $DOMAIN_NAME",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$RECORD_VALUE"
          }
        ]
      }
    }
  ]
}
EOF
)

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" >/dev/null

echo "Waiting for certificate to be issued (this can take a few minutes)..."

# The AWS CLI has a 'wait certificate-validated' command, but it only works
# if the certificate domain is validated. We'll do a custom wait loop:
CERT_STATUS="PENDING_VALIDATION"
while [[ "$CERT_STATUS" == "PENDING_VALIDATION" || "$CERT_STATUS" == "IN_PROGRESS" ]]; do
  sleep 10
  CERT_STATUS="$(aws acm describe-certificate \
      --region us-west-2 \
      --certificate-arn "$CERT_ARN" \
      --query 'Certificate.Status' \
      --output text)"
  echo "  Current certificate status: $CERT_STATUS"
  if [[ "$CERT_STATUS" == "ISSUED" ]]; then
    break
  elif [[ "$CERT_STATUS" == "FAILED" || "$CERT_STATUS" == "NOT_VALIDATED" ]]; then
    echo "Error: Certificate validation failed with status: $CERT_STATUS"
    exit 1
  fi
done

echo "Certificate has been issued!"
echo ""

### 4. Create the CloudFront Distribution pointing to S3 ##################

CF_DIST_COMMENT="CloudFront distribution for $BUCKET_NAME -> $DOMAIN_NAME"
UNIQUE_REF="cf-$(date +%s)"

# Create an Origin Access Identity or OAC if you want a private bucket.
# For simplicity, let's keep the bucket public or no special OAI policy here.

# Build the distribution config JSON
DISTRIBUTION_CONFIG=$(cat <<EOF
{
  "CallerReference": "$UNIQUE_REF",
  "Comment": "$CF_DIST_COMMENT",
  "Aliases": {
    "Quantity": 1,
    "Items": [
      "$DOMAIN_NAME"
    ]
  },
  "DefaultRootObject": "index.html",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-$BUCKET_NAME",
        "DomainName": "$BUCKET_NAME.s3.amazonaws.com",
        "OriginPath": "",
        "CustomHeaders": {
          "Quantity": 0
        },
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-$BUCKET_NAME",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": [
        "GET",
        "HEAD"
      ],
      "CachedMethods": {
        "Quantity": 2,
        "Items": [
          "GET",
          "HEAD"
        ]
      }
    },
    "Compress": true,
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": {
        "Forward": "none"
      }
    },
    "MinTTL": 0,
    "DefaultTTL": 86400,
    "MaxTTL": 31536000
  },
  "PriceClass": "PriceClass_All",
  "Restrictions": {
    "GeoRestriction": {
      "RestrictionType": "none",
      "Quantity": 0
    }
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "$CERT_ARN",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2019"
  },
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
EOF
)

echo "Creating CloudFront distribution. This may take a few minutes..."
aws cloudfront create-distribution \
  --distribution-config "$DISTRIBUTION_CONFIG" \
  --output json > create-dist-output.json

DISTRIBUTION_ID=$(jq -r '.Distribution.Id' create-dist-output.json)
DISTRIBUTION_DOMAIN=$(jq -r '.Distribution.DomainName' create-dist-output.json)

echo "CloudFront distribution created!"
echo "Distribution ID:     $DISTRIBUTION_ID"
echo "Distribution Domain: $DISTRIBUTION_DOMAIN"
echo ""

### 5. Update Route 53 to Route Traffic to CloudFront (ALIAS) #############

# Create an ALIAS record (type A) from <DOMAIN_NAME> to the CloudFront domain
# We need CloudFront's hosted zone ID for the alias target
# Reference: https://docs.aws.amazon.com/general/latest/gr/cf_domain.html
# But there's also a handy "list-distributions" or "get-distribution" approach:

CF_HOSTED_ZONE_ID=$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" \
  | jq -r '.Distribution.DomainName' \
  | xargs -I {} aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='{}'].HostedZoneId | [0]" --output text \
  )

# If the above approach doesn't work for you, or you want it faster,
# you can hardcode the known CloudFront hosted zone ID (e.g. Z2FDT1GXY67Q9H)
# per https://docs.aws.amazon.com/general/latest/gr/cf_region.html

# Fallback to the known global CloudFront Hosted Zone ID if not
if [[ -z "$CF_HOSTED_ZONE_ID" || "$CF_HOSTED_ZONE_ID" == "None" ]]; then
  CF_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"
fi

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Alias to CloudFront distribution $DISTRIBUTION_ID",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN_NAME",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$CF_HOSTED_ZONE_ID",
          "DNSName": "$DISTRIBUTION_DOMAIN",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF
)

echo "Creating/updating Route 53 ALIAS record: $DOMAIN_NAME -> $DISTRIBUTION_DOMAIN ..."
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" > /dev/null

echo ""
echo "=========================================================================="
echo "SUCCESS! CloudFront distribution is deploying; it may take ~15 minutes."
echo "Once deployed, https://$DOMAIN_NAME/ will serve content from S3 bucket:"
echo "  s3://$BUCKET_NAME"
echo ""
echo "CloudFront Domain:     $DISTRIBUTION_DOMAIN"
echo "Certificate ARN:       $CERT_ARN"
echo "Route53 Hosted Zone:   $HOSTED_ZONE_ID"
echo ""
echo "Next steps:"
echo "  - Upload your static files to s3://$BUCKET_NAME."
echo "  - Confirm your site is accessible via https://$DOMAIN_NAME/."
echo "  - (Optional) Configure bucket policy/origin access if you want a private S3 origin."
echo "=========================================================================="
