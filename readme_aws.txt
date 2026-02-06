# ECR Image Pull Instructions

## Registry Information

- **Registry**: `004669175958.dkr.ecr.us-east-1.amazonaws.com`
- **Region**: `us-east-1`
- **Total Images**: 297

## Authentication

Before pulling images, authenticate to ECR using your AWS credentials:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 004669175958.dkr.ecr.us-east-1.amazonaws.com
```

## Pulling Images

### Pull a single image

```bash
docker pull 004669175958.dkr.ecr.us-east-1.amazonaws.com/<repository>:<tag>
```

### Example

```bash
docker pull 004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c
```

### Pull all images (batch script)

```bash
# Authenticate first
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 004669175958.dkr.ecr.us-east-1.amazonaws.com

# Pull all images from the list
while read -r image; do
  docker pull "$image"
done < ecr_images.txt
```

- `image_mapping.csv` - Tab-separated mapping of original repo names to ECR names

## Image Name Mapping

Some repository names were sanitized to comply with ECR naming rules:
- Double underscores (`__`) were replaced with single underscores (`_`)
- Invalid characters were replaced with hyphens

## Troubleshooting

### Access Denied

If you receive an "access denied" error, ensure:
1. Your AWS account ID is in the authorized list above
2. You have authenticated using `aws ecr get-login-password`
3. Your IAM role/user has `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, and `ecr:BatchCheckLayerAvailability` permissions

### Token Expired

ECR tokens expire after 12 hours. Re-authenticate if you see token expiration errors:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 004669175958.dkr.ecr.us-east-1.amazonaws.com
