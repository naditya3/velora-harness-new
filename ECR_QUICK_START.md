# ECR Quick Start

Quick reference for accessing Docker images from AWS ECR.

## TL;DR - Get Started in 3 Steps

```bash
# 1. Complete setup (checks everything and authenticates)
./setup_ecr_access.sh setup

# 2. Pull first 10 images
./setup_ecr_access.sh pull 10

# 3. List downloaded images
./setup_ecr_access.sh list
```

## Common Commands

| Task | Command |
|------|---------|
| Initial setup | `./setup_ecr_access.sh setup` |
| Authenticate only | `./setup_ecr_access.sh auth` |
| Pull all images | `./setup_ecr_access.sh pull` |
| Pull N images | `./setup_ecr_access.sh pull 10` |
| Pull specific image | `./setup_ecr_access.sh pull-image IMAGE_URI` |
| List local images | `./setup_ecr_access.sh list` |
| Verify access | `./setup_ecr_access.sh verify` |

## Using Python Script

```bash
# Authenticate
python3 ecr_image_manager.py auth

# Pull all images
python3 ecr_image_manager.py pull-all

# Pull 10 images
python3 ecr_image_manager.py pull-all --max-images 10
```

## What You Need

✅ AWS CLI installed (`aws --version`)
✅ Docker installed (`docker --version`)
✅ AWS credentials configured (`aws configure`)
✅ ECR permissions (see [ECR_SETUP_GUIDE.md](ECR_SETUP_GUIDE.md))

## Files

- **[setup_ecr_access.sh](setup_ecr_access.sh)** - Shell script for ECR operations
- **[ecr_image_manager.py](ecr_image_manager.py)** - Python script for ECR operations
- **[image_mapping.csv](image_mapping.csv)** - Image URI mappings (297 images)
- **[ECR_SETUP_GUIDE.md](ECR_SETUP_GUIDE.md)** - Complete documentation
- **[readme_aws.txt](readme_aws.txt)** - Original ECR instructions

## Registry Information

- **Registry**: `004669175958.dkr.ecr.us-east-1.amazonaws.com`
- **Region**: `us-east-1`
- **Total Images**: 297

## Token Expiration

⚠️ ECR authentication tokens expire after **12 hours**

Re-authenticate when you see token errors:
```bash
./setup_ecr_access.sh auth
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Authentication failed | Run `aws configure` and verify credentials |
| Token expired | Run `./setup_ecr_access.sh auth` again |
| Access denied | Check IAM permissions with your AWS admin |
| Docker daemon error | Run `sudo systemctl start docker` |
| Permission denied | Run `sudo usermod -aG docker $USER` and re-login |

## Full Documentation

See [ECR_SETUP_GUIDE.md](ECR_SETUP_GUIDE.md) for complete documentation, examples, and advanced usage.
