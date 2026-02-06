# ARM64 Build Issue - Solutions and Fixes

## Problem Summary

You encountered a **Docker build failure (exit code 139)** when running evaluations on an ARM64 EC2 instance. This happens because:

1. ✓ Your `image_mapping.csv` is working correctly
2. ✓ ECR images are being translated properly
3. ✗ **But**: OpenHands tries to build AMD64 runtime images on ARM64
4. ✗ **Result**: QEMU emulation crashes with segmentation fault

## What We Fixed

✅ **Applied stabilization measures:**
- Installed/updated QEMU binfmt handlers
- Increased system limits (vm.max_map_count, fs.file-max)
- Configured Docker for better stability
- Verified cross-platform emulation works

## Solutions (Choose One)

### Option 1: Continue on ARM64 (Current Setup)

**Status:** Stabilization applied, but builds may still be slow/unstable

**Pros:**
- No instance change needed
- Works for light testing

**Cons:**
- Slower build times (3-5x)
- Occasional segfaults may still occur
- Not recommended for production

**Next Steps:**
```bash
# Just retry your evaluation
cd /home/ec2-user/VeloraTrajectories
# Run your evaluation script here
```

### Option 2: Switch to AMD64 Instance (Recommended)

**Status:** Best for production and reliable runs

**Pros:**
- Native AMD64 builds (no emulation)
- Faster and more stable
- No QEMU overhead

**Cons:**
- Requires launching a new instance

**Recommended Instance Types:**
- `m5.2xlarge` - General purpose (8 vCPU, 32GB RAM)
- `c5.2xlarge` - Compute optimized (8 vCPU, 16GB RAM)
- `m5.4xlarge` - For parallel evaluation (16 vCPU, 64GB RAM)

**Migration Steps:**
1. Create AMI from current instance (optional, for backup)
2. Launch new AMD64 instance with same setup
3. Copy your data and configuration
4. Run evaluations on the new instance

### Option 3: Pre-build Runtime Images

**Status:** Script created at `prebuild_runtime_images.sh`

**Pros:**
- One-time build cost
- Reusable across machines
- Can build on AMD64, use on ARM64

**Cons:**
- Requires AMD64 machine for building
- Need to rebuild if base images change

**Steps:**
```bash
# On an AMD64 instance:
bash prebuild_runtime_images.sh

# This creates cached runtime images
# Then sync Docker images to your ARM64 instance
```

## Verification

Test that QEMU is working:
```bash
sudo docker run --rm --platform linux/amd64 alpine uname -m
# Should output: x86_64
```

## Current Status

✅ QEMU emulation is configured and verified
✅ System limits increased
✅ Docker stabilized
✅ Image mapping working correctly

⚠️ **Recommendation:** For production evaluations, switch to an AMD64 instance type

## Files Created

1. `stabilize_qemu_builds.sh` - Applied (makes ARM64 builds more stable)
2. `prebuild_runtime_images.sh` - Ready to use (for pre-building on AMD64)
3. `ARM64_BUILD_SOLUTION.md` - This guide

## Quick Retry

Your environment is now optimized. Try running your evaluation again:

```bash
cd /home/ec2-user/VeloraTrajectories
# Your original evaluation command here
```

If you still encounter segfaults, consider switching to an AMD64 instance for reliable execution.
