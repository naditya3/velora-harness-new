"""
Image mapping and ECR utilities for VeloraHarness.

This module provides utilities for:
1. Mapping internal Docker registry URIs to AWS ECR URIs
2. Sanitizing ECR repository names according to AWS ECR naming rules
"""

import csv
import os
import re
from pathlib import Path
from typing import Dict, Optional, Tuple

from openhands.core.logger import openhands_logger as logger


# Cache for image mappings to avoid reloading CSV on every call
_IMAGE_MAPPING_CACHE: Optional[Dict[str, str]] = None


def sanitize_ecr_repo_name(name: str) -> Tuple[str, bool]:
    """Sanitize repo name to comply with ECR naming rules.

    ECR allows: lowercase letters, numbers, hyphens, underscores, forward slashes, periods
    But NOT: double underscores (__), leading/trailing special chars

    Args:
        name: The repository name to sanitize

    Returns:
        Tuple of (sanitized_name, was_modified) - only modifies if necessary.
    """
    original = name

    # First lowercase (ECR requires lowercase)
    name = name.lower()

    # Replace double underscores with single (ECR rejects __)
    while "__" in name:
        name = name.replace("__", "_")

    # Replace any invalid chars (not in allowed set) with hyphen
    name = re.sub(r'[^a-z0-9/_.-]', '-', name)

    # Remove leading/trailing special chars from each path segment
    parts = name.split("/")
    cleaned_parts = [p.strip("._-") for p in parts if p.strip("._-")]
    name = "/".join(cleaned_parts)

    was_modified = (name != original.lower())  # Compare lowercase since ECR is case-insensitive
    return name, was_modified


def load_image_mapping(csv_path: Optional[str] = None) -> Dict[str, str]:
    """Load image mapping from CSV file.

    The CSV should have two columns:
    - internal_uri: The internal registry URI (e.g., vmvm-registry.fbinfra.net/...)
    - ecr_uri: The corresponding ECR URI (e.g., 004669175958.dkr.ecr.us-east-1.amazonaws.com/...)

    Args:
        csv_path: Path to the image_mapping.csv file. If None, uses the default location.

    Returns:
        Dictionary mapping internal URIs to ECR URIs
    """
    global _IMAGE_MAPPING_CACHE

    # Return cached mapping if already loaded
    if _IMAGE_MAPPING_CACHE is not None:
        return _IMAGE_MAPPING_CACHE

    # Default path: look for image_mapping.csv in project root
    if csv_path is None:
        # Try to find the project root by looking for jaeger/VeloraHarness
        current_file = Path(__file__).resolve()
        project_root = current_file.parent.parent.parent.parent.parent
        csv_path = project_root / 'image_mapping.csv'

    # Check if file exists
    if not os.path.exists(csv_path):
        logger.warning(
            f'Image mapping file not found at {csv_path}. '
            'Image URI translation will be disabled.'
        )
        _IMAGE_MAPPING_CACHE = {}
        return _IMAGE_MAPPING_CACHE

    # Load the CSV
    mapping = {}
    try:
        with open(csv_path, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                internal_uri = row.get('internal_uri', '').strip()
                ecr_uri = row.get('ecr_uri', '').strip()
                if internal_uri and ecr_uri:
                    mapping[internal_uri] = ecr_uri

        logger.info(f'Loaded {len(mapping)} image mappings from {csv_path}')
        _IMAGE_MAPPING_CACHE = mapping
        return mapping

    except Exception as e:
        logger.error(f'Failed to load image mapping from {csv_path}: {e}')
        _IMAGE_MAPPING_CACHE = {}
        return _IMAGE_MAPPING_CACHE


def translate_image_uri(
    image_uri: str,
    mapping: Optional[Dict[str, str]] = None,
    sanitize: bool = True
) -> str:
    """Translate an internal image URI to an ECR URI.

    Args:
        image_uri: The image URI to translate
        mapping: Optional pre-loaded mapping dictionary. If None, loads from default location.
        sanitize: Whether to sanitize ECR repo names according to AWS rules

    Returns:
        The translated ECR URI, or the original URI if no mapping found
    """
    # Load mapping if not provided
    if mapping is None:
        mapping = load_image_mapping()

    # Return original if no mapping available
    if not mapping:
        return image_uri

    # Direct lookup
    if image_uri in mapping:
        ecr_uri = mapping[image_uri]
        logger.debug(f'Translated image URI: {image_uri} -> {ecr_uri}')

        if sanitize:
            # Extract repo name and sanitize
            # ECR URI format: registry/repository:tag
            if ':' in ecr_uri:
                registry_repo, tag = ecr_uri.rsplit(':', 1)
            else:
                registry_repo = ecr_uri
                tag = None

            if '/' in registry_repo:
                registry, repo = registry_repo.split('/', 1)
                sanitized_repo, was_modified = sanitize_ecr_repo_name(repo)

                if was_modified:
                    logger.info(
                        f'Sanitized ECR repo name: {repo} -> {sanitized_repo}'
                    )
                    ecr_uri = f'{registry}/{sanitized_repo}'
                    if tag:
                        ecr_uri += f':{tag}'

        return ecr_uri

    # No mapping found - return original
    logger.debug(f'No mapping found for image URI: {image_uri}')
    return image_uri


def get_ecr_image_uri(
    internal_uri: Optional[str] = None,
    fallback_image: Optional[str] = None,
    sanitize: bool = True
) -> str:
    """Get ECR image URI with fallback handling.

    This is a convenience function that combines translation and fallback logic.

    Args:
        internal_uri: The internal image URI to translate
        fallback_image: Fallback image to use if translation fails
        sanitize: Whether to sanitize ECR repo names

    Returns:
        The ECR image URI to use
    """
    # If no internal URI provided, use fallback
    if not internal_uri:
        if fallback_image:
            logger.info(f'No internal URI provided, using fallback: {fallback_image}')
            return fallback_image
        else:
            raise ValueError('Either internal_uri or fallback_image must be provided')

    # Try to translate
    ecr_uri = translate_image_uri(internal_uri, sanitize=sanitize)

    # If translation returned the same URI (no mapping found), use fallback if available
    if ecr_uri == internal_uri and fallback_image:
        logger.warning(
            f'No translation available for {internal_uri}, '
            f'using fallback: {fallback_image}'
        )
        return fallback_image

    return ecr_uri


def preload_image_mapping(csv_path: Optional[str] = None) -> int:
    """Preload image mapping into cache.

    This is useful to load the mapping once at startup rather than on first use.

    Args:
        csv_path: Optional path to the CSV file

    Returns:
        Number of mappings loaded
    """
    mapping = load_image_mapping(csv_path)
    return len(mapping)
