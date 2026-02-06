#!/usr/bin/env python3
"""
ECR Image Manager
Handles AWS ECR authentication and Docker image pulling for Velora Trajectories
"""

import argparse
import csv
import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class ECRImageManager:
    """Manages ECR authentication and Docker image operations"""

    def __init__(
        self,
        registry: str = "004669175958.dkr.ecr.us-east-1.amazonaws.com",
        region: str = "us-east-1",
        mapping_file: str = "image_mapping.csv"
    ):
        self.registry = registry
        self.region = region
        self.mapping_file = mapping_file
        self.image_mapping: Dict[str, str] = {}

    def authenticate(self) -> bool:
        """
        Authenticate with AWS ECR using AWS CLI

        Returns:
            bool: True if authentication successful, False otherwise
        """
        logger.info(f"Authenticating with ECR registry: {self.registry}")

        try:
            # Get ECR login password
            get_password_cmd = [
                "aws", "ecr", "get-login-password",
                "--region", self.region
            ]

            password_result = subprocess.run(
                get_password_cmd,
                capture_output=True,
                text=True,
                check=True
            )

            # Docker login
            docker_login_cmd = [
                "docker", "login",
                "--username", "AWS",
                "--password-stdin",
                self.registry
            ]

            login_result = subprocess.run(
                docker_login_cmd,
                input=password_result.stdout,
                capture_output=True,
                text=True,
                check=True
            )

            logger.info("Successfully authenticated with ECR")
            return True

        except subprocess.CalledProcessError as e:
            logger.error(f"Authentication failed: {e}")
            logger.error(f"Error output: {e.stderr}")
            return False
        except FileNotFoundError:
            logger.error("AWS CLI or Docker not found. Please ensure both are installed.")
            return False

    def load_image_mapping(self) -> bool:
        """
        Load image mapping from CSV file

        Returns:
            bool: True if mapping loaded successfully
        """
        mapping_path = Path(self.mapping_file)

        if not mapping_path.exists():
            logger.error(f"Mapping file not found: {self.mapping_file}")
            return False

        try:
            with open(mapping_path, 'r') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    internal_uri = row.get('internal_uri', '')
                    ecr_uri = row.get('ecr_uri', '')
                    if internal_uri and ecr_uri:
                        self.image_mapping[internal_uri] = ecr_uri

            logger.info(f"Loaded {len(self.image_mapping)} image mappings")
            return True

        except Exception as e:
            logger.error(f"Failed to load image mapping: {e}")
            return False

    def pull_image(self, image_uri: str, retry: int = 3) -> bool:
        """
        Pull a Docker image from ECR

        Args:
            image_uri: Full ECR image URI
            retry: Number of retry attempts

        Returns:
            bool: True if pull successful
        """
        logger.info(f"Pulling image: {image_uri}")

        for attempt in range(1, retry + 1):
            try:
                result = subprocess.run(
                    ["docker", "pull", image_uri],
                    capture_output=True,
                    text=True,
                    check=True
                )
                logger.info(f"Successfully pulled: {image_uri}")
                return True

            except subprocess.CalledProcessError as e:
                logger.warning(f"Pull attempt {attempt}/{retry} failed: {e.stderr}")
                if attempt == retry:
                    logger.error(f"Failed to pull image after {retry} attempts: {image_uri}")
                    return False

        return False

    def pull_images_from_file(self, file_path: str, max_images: int = None) -> Tuple[int, int]:
        """
        Pull multiple images from a text file (one per line)

        Args:
            file_path: Path to file containing image URIs
            max_images: Maximum number of images to pull (None = all)

        Returns:
            Tuple of (successful_pulls, total_images)
        """
        file_path_obj = Path(file_path)

        if not file_path_obj.exists():
            logger.error(f"Image list file not found: {file_path}")
            return (0, 0)

        with open(file_path_obj, 'r') as f:
            images = [line.strip() for line in f if line.strip() and not line.startswith('#')]

        if max_images:
            images = images[:max_images]

        total = len(images)
        successful = 0

        logger.info(f"Starting to pull {total} images")

        for idx, image in enumerate(images, 1):
            logger.info(f"[{idx}/{total}] Processing: {image}")
            if self.pull_image(image):
                successful += 1

        logger.info(f"Completed: {successful}/{total} images pulled successfully")
        return (successful, total)

    def pull_all_mapped_images(self, max_images: int = None) -> Tuple[int, int]:
        """
        Pull all images from the mapping file

        Args:
            max_images: Maximum number of images to pull (None = all)

        Returns:
            Tuple of (successful_pulls, total_images)
        """
        if not self.image_mapping:
            if not self.load_image_mapping():
                return (0, 0)

        images = list(self.image_mapping.values())

        if max_images:
            images = images[:max_images]

        total = len(images)
        successful = 0

        logger.info(f"Starting to pull {total} mapped images")

        for idx, image in enumerate(images, 1):
            logger.info(f"[{idx}/{total}] Processing: {image}")
            if self.pull_image(image):
                successful += 1

        logger.info(f"Completed: {successful}/{total} images pulled successfully")
        return (successful, total)

    def verify_access(self) -> bool:
        """
        Verify ECR access by attempting to list repositories

        Returns:
            bool: True if access verified
        """
        logger.info("Verifying ECR access...")

        try:
            result = subprocess.run(
                [
                    "aws", "ecr", "describe-repositories",
                    "--registry-id", self.registry.split('.')[0],
                    "--region", self.region,
                    "--max-items", "1"
                ],
                capture_output=True,
                text=True,
                check=True
            )
            logger.info("ECR access verified successfully")
            return True

        except subprocess.CalledProcessError as e:
            logger.error(f"ECR access verification failed: {e.stderr}")
            return False

    def list_local_images(self, filter_ecr: bool = True) -> List[str]:
        """
        List locally available Docker images

        Args:
            filter_ecr: Only show images from ECR registry

        Returns:
            List of image names
        """
        try:
            result = subprocess.run(
                ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                capture_output=True,
                text=True,
                check=True
            )

            images = result.stdout.strip().split('\n')

            if filter_ecr:
                images = [img for img in images if self.registry in img]

            return images

        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to list local images: {e}")
            return []


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="ECR Image Manager for Velora Trajectories",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Authenticate with ECR
  python ecr_image_manager.py auth

  # Verify ECR access
  python ecr_image_manager.py verify

  # Pull all images from mapping file
  python ecr_image_manager.py pull-all

  # Pull specific number of images
  python ecr_image_manager.py pull-all --max-images 10

  # Pull images from custom file
  python ecr_image_manager.py pull-from-file images.txt

  # List local ECR images
  python ecr_image_manager.py list-local
        """
    )

    parser.add_argument(
        "command",
        choices=["auth", "verify", "pull-all", "pull-from-file", "list-local"],
        help="Command to execute"
    )

    parser.add_argument(
        "file",
        nargs="?",
        help="File path (for pull-from-file command)"
    )

    parser.add_argument(
        "--registry",
        default="004669175958.dkr.ecr.us-east-1.amazonaws.com",
        help="ECR registry URL"
    )

    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region"
    )

    parser.add_argument(
        "--mapping-file",
        default="image_mapping.csv",
        help="Path to image mapping CSV file"
    )

    parser.add_argument(
        "--max-images",
        type=int,
        help="Maximum number of images to pull"
    )

    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging"
    )

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    # Initialize manager
    manager = ECRImageManager(
        registry=args.registry,
        region=args.region,
        mapping_file=args.mapping_file
    )

    # Execute command
    if args.command == "auth":
        if manager.authenticate():
            logger.info("Authentication successful")
            sys.exit(0)
        else:
            logger.error("Authentication failed")
            sys.exit(1)

    elif args.command == "verify":
        if manager.verify_access():
            logger.info("ECR access verified")
            sys.exit(0)
        else:
            logger.error("ECR access verification failed")
            sys.exit(1)

    elif args.command == "pull-all":
        # Authenticate first
        if not manager.authenticate():
            logger.error("Authentication required before pulling images")
            sys.exit(1)

        successful, total = manager.pull_all_mapped_images(max_images=args.max_images)
        logger.info(f"Pull complete: {successful}/{total} successful")
        sys.exit(0 if successful == total else 1)

    elif args.command == "pull-from-file":
        if not args.file:
            logger.error("File path required for pull-from-file command")
            sys.exit(1)

        # Authenticate first
        if not manager.authenticate():
            logger.error("Authentication required before pulling images")
            sys.exit(1)

        successful, total = manager.pull_images_from_file(args.file, max_images=args.max_images)
        logger.info(f"Pull complete: {successful}/{total} successful")
        sys.exit(0 if successful == total else 1)

    elif args.command == "list-local":
        images = manager.list_local_images()
        if images:
            logger.info(f"Found {len(images)} local ECR images:")
            for img in images:
                print(img)
        else:
            logger.info("No local ECR images found")
        sys.exit(0)


if __name__ == "__main__":
    main()
