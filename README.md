# README

Helps deploy a collection of static HTML files to a S3 backed site fronted by global CDN (cloudfront) and published under custom domain for cents per month.

## Usage
./bin/deploy-static-site.sh <DOMAIN_NAME> <BUCKET_NAME> <LOCAL_BUILD_DIR>
./bin/deploy-s3-cloudfront-cert-route53.sh <BUCKET_NAME> <DOMAIN_NAME>