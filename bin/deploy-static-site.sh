#!/usr/bin/env bash
#
# Usage: ./deploy-static-site.sh <DOMAIN_NAME> <BUCKET_NAME> <LOCAL_BUILD_DIR>
#
# Example:
#   ./deploy-static-site.sh example.com my-awesome-static-site ./build
#
# This script will:
#   1. Create an S3 bucket
#   2. Turn off block public access
#   3. Add a bucket policy to allow public reads
#   4. Sync the local directory to the bucket
#   5. Enable static website hosting
#
# After this script completes, you can access your site at:
#   http://<BUCKET_NAME>.s3-website-<REGION>.amazonaws.com
#
# (Optional) You can then configure Route 53 (or another DNS provider)
# to point a custom domain (e.g., example.com) to your S3 website endpoint.

set -euo pipefail

# --- 0. Parse Inputs ---
if [ $# -lt 3 ]; then
  echo "Usage: $0 <DOMAIN_NAME> <BUCKET_NAME> <LOCAL_BUILD_DIR>"
  exit 1
fi

DOMAIN_NAME="$1"
BUCKET_NAME="$2"
LOCAL_BUILD_DIR="$3"

# --- 1. Create S3 Bucket ---
echo "Creating S3 bucket: s3://$BUCKET_NAME ..."
aws s3 mb "s3://$BUCKET_NAME" || {
  echo "Error creating bucket. It might already exist or the name is not unique."
  exit 1
}

# --- 2. Disable Block Public Access (all four settings) ---
echo "Disabling block public access on bucket $BUCKET_NAME ..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

# --- 3. Apply Bucket Policy to Allow Public Reads ---
echo "Applying bucket policy to allow public reads ..."
BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$BUCKET_POLICY" 

# --- 4. Sync Local Directory to S3 ---
echo "Syncing local directory '$LOCAL_BUILD_DIR' to s3://$BUCKET_NAME ..."
aws s3 sync "$LOCAL_BUILD_DIR" "s3://$BUCKET_NAME" \
  --delete

# --- 5. Enable Static Website Hosting ---
echo "Enabling static website hosting on $BUCKET_NAME ..."
aws s3api put-bucket-website \
  --bucket "$BUCKET_NAME" \
  --website-configuration '{
    "IndexDocument": { "Suffix": "index.html" },
    "ErrorDocument": { "Key": "error.html" }
  }'

# --- Summary / Next Steps ---
echo ""
echo "==========================================="
echo "Static site deployed to s3://$BUCKET_NAME/"
echo "Website endpoint (region-dependent):"
echo "http://$BUCKET_NAME.s3-website-<REGION>.amazonaws.com"
echo "==========================================="
echo ""
echo "Optional: Point your domain ($DOMAIN_NAME) to the above endpoint using Route 53 or your DNS provider."
