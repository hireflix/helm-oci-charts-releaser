#!/usr/bin/env bash

set -e

# Default type is patch
BUMP_TYPE=${1:-patch}
DRY_RUN=${DRY_RUN:-false}

# Check if gh CLI is available
HAS_GH_CLI=$(command -v gh >/dev/null 2>&1 && echo true || echo false)

# Validate bump type
if [[ ! $BUMP_TYPE =~ ^(major|minor|patch)$ ]]; then
    echo "Error: Bump type must be one of: major, minor, patch"
    echo "Usage: $0 [major|minor|patch]"
    exit 1
fi

# Get all version tags and sort them
ALL_TAGS=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V)
LATEST_TAG=$(echo "$ALL_TAGS" | tail -n 1)

# Debug information
echo "All existing version tags:"
echo "$ALL_TAGS"
echo "Latest tag found: $LATEST_TAG"

# If no tags exist, start with v0.0.0
if [ -z "$LATEST_TAG" ]; then
    VERSION="0.0.0"
    echo "No existing version tags found, starting with v0.0.0"
else
    # Remove 'v' prefix for version calculations
    VERSION=${LATEST_TAG#v}
    echo "Found latest version: $VERSION"
fi

MAJOR=$(echo $VERSION | cut -d. -f1)
MINOR=$(echo $VERSION | cut -d. -f2)
PATCH=$(echo $VERSION | cut -d. -f3)

echo "Current version components: major=$MAJOR, minor=$MINOR, patch=$PATCH"

# Calculate new version
case $BUMP_TYPE in
    major)
        NEW_MAJOR=$((MAJOR + 1))
        NEW_MINOR=0
        NEW_PATCH=0
        ;;
    minor)
        NEW_MAJOR=$MAJOR
        NEW_MINOR=$((MINOR + 1))
        NEW_PATCH=0
        ;;
    patch)
        NEW_MAJOR=$MAJOR
        NEW_MINOR=$MINOR
        NEW_PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="v$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
MAJOR_VERSION="v$NEW_MAJOR"

echo "Calculated new version: $NEW_VERSION"

# Update version in README.md if it exists
if [[ -f README.md ]]; then
    echo "Updating version in README.md..."
    if ($DRY_RUN); then
        echo "[DRY RUN] Would update version in README.md"
    else
        # Update the specific line with helm version
        sed -i.bak 's/version`: The helm version to use (default: v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*)/version`: The helm version to use (default: '"$NEW_VERSION"')/g' README.md
        rm -f README.md.bak
    fi
fi

# Get release notes
if [ -z "$LATEST_TAG" ]; then
    RELEASE_NOTES=$(git log --pretty=format:"- %s" | grep -v "Merge" || echo "Initial release")
else
    RELEASE_NOTES=$(git log ${LATEST_TAG}..HEAD --pretty=format:"- %s" | grep -v "Merge" || echo "No changes")
fi

echo "Current version: ${LATEST_TAG:-none}"
echo "New version: $NEW_VERSION"
echo "Major version tag: $MAJOR_VERSION"
echo -e "\nRelease notes:\n$RELEASE_NOTES"

if ($DRY_RUN); then
    echo -e "\n[DRY RUN] Would execute:"
    echo "git tag -a $NEW_VERSION -m \"Release $NEW_VERSION\""
    echo "git tag -fa $MAJOR_VERSION -m \"Update $MAJOR_VERSION tag\""
    echo "git push origin $NEW_VERSION"
    echo "git push -f origin $MAJOR_VERSION"
    if ($HAS_GH_CLI); then
        echo "gh release create $NEW_VERSION"
    fi
    exit 0
fi

# Confirm with user
read -p "Do you want to proceed with the release? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Release cancelled"
    exit 1
fi

# Create and push tags
echo "Creating version tag..."
git tag -a $NEW_VERSION -m "Release $NEW_VERSION

$RELEASE_NOTES"

echo "Updating major version tag..."
git tag -fa $MAJOR_VERSION -m "Update $MAJOR_VERSION tag"

echo "Pushing tags..."
git push origin $NEW_VERSION
git push -f origin $MAJOR_VERSION

# Create GitHub release if gh CLI is available
if ($HAS_GH_CLI); then
    echo "Creating GitHub release..."
    gh release create $NEW_VERSION \
        --title "Release $NEW_VERSION" \
        --notes "$RELEASE_NOTES" \
        --latest
else
    echo "Note: GitHub CLI (gh) is not installed. Skipping GitHub release creation."
    echo "To create GitHub releases, install the GitHub CLI from: https://cli.github.com/"
fi

echo "Release $NEW_VERSION completed successfully!" 