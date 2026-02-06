# ECR Cross-Account Access Setup Guide

## Your Setup
- **EC2 Instance**: Account `426628337772`, Region `ap-south-1`
- **IAM Role**: `AstraIAMRole`
- **ECR Registry**: Account `004669175958`, Region `us-east-1`
- **Status**: ✅ AWS CLI working, ❌ ECR permissions missing

---

## What You Need to Do

### Step 1: Add ECR Permissions to AstraIAMRole

**Via AWS Console (Easiest)**

1. Go to https://console.aws.amazon.com/iam/
2. Click **"Roles"** in the left sidebar
3. Search for `AstraIAMRole` and click on it
4. Under **"Permissions"**, click **"Add permissions"** → **"Create inline policy"**
5. Click the **"JSON"** tab
6. Paste the policy from `/home/ec2-user/VeloraTrajectories/ecr-policy.json`
7. Click **"Review policy"**, name it `ECRReadAccess`, click **"Create policy"**

---

### Step 2: Configure ECR Repository Policy (Cross-Account Access)

**IMPORTANT**: The ECR registry is in account `004669175958`. Someone with access to that AWS account needs to add a repository policy.

**They need to**:
1. Go to ECR Console in us-east-1
2. Select repository: `repomate_image_activ_go_test/meroxa_cli`
3. Click **"Permissions"** → **"Edit policy JSON"**
4. Add cross-account policy allowing account `426628337772` to pull

**Repeat for ALL 297 repositories** in your image mapping.

---

## Testing After Setup

Once Step 1 is complete:
```bash
aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin 004669175958.dkr.ecr.us-east-1.amazonaws.com
```

Then run:
```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_instance_wise_trajectories.sh 1
```

---

## Summary

✅ **Code Fixes**: Complete
✅ **AWS Config**: Fixed  
✅ **Instance Role**: Working
✅ **Policy Created**: ecr-policy.json
❌ **Step 1**: Add ECR policy to AstraIAMRole (AWS Console)
❌ **Step 2**: Cross-account ECR policy in account 004669175958

**Action Required**: Complete Step 1 via AWS Console, then contact owner of account 004669175958 for Step 2.
