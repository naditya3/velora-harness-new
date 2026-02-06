def sanitize_ecr_repo_name(name: str) -> tuple[str, bool]:
    """Sanitize repo name to comply with ECR naming rules.

    ECR allows: lowercase letters, numbers, hyphens, underscores, forward slashes, periods
    But NOT: double underscores (__), leading/trailing special chars

    Returns (sanitized_name, was_modified) - only modifies if necessary.
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
