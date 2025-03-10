# Testing Instructions for helm-oci-charts-releaser

This document provides instructions for testing the `cr.sh` script locally to verify that it's working correctly, especially after fixes to the parameter handling.

## Prerequisites

- Git repository with Helm charts
- Docker (optional, for testing in an isolated environment)
- GitHub CLI (`gh`) (optional, only needed for GitHub release operations)
- Helm installed (optional, as the script can install it)

## Basic Testing

### 1. Running with Debug Enabled

Always enable debug logging when testing:

```bash
# Method 1: Use environment variable
DEBUG=true ./cr.sh --oci-registry ghcr.io --oci-path mypath --oci-username myuser

# Method 2: Use command-line flag
./cr.sh --debug --oci-registry ghcr.io --oci-path mypath --oci-username myuser
```

### 2. Testing Parameter Handling

Test the parameters that were previously causing issues:

```bash
# Test with all required parameters
./cr.sh --debug \
  --oci-registry ghcr.io \
  --oci-path myorg \
  --oci-username myuser \
  --charts-dir stable \
  --version v3.13.2 \
  --mark-as-latest true

# Expected result: Script should proceed past parameter validation
# Look for debug logs showing each parameter is properly set
```

### 3. Testing with Skip OCI Login

Test the case where you want to skip OCI login (which makes `oci_username` optional):

```bash
./cr.sh --debug \
  --oci-registry ghcr.io \
  --oci-path myorg \
  --skip-oci-login true \
  --charts-dir stable
```

### 4. Dry Run Mode

Use dry run mode to test without making actual changes:

```bash
DRY_RUN=true ./cr.sh --debug \
  --oci-registry ghcr.io \
  --oci-path myorg \
  --oci-username myuser \
  --charts-dir stable
```

## Testing in Docker

For isolated testing, you can use Docker:

```bash
# Create a temporary Dockerfile
cat > Dockerfile.test << EOF
FROM ubuntu:latest

RUN apt-get update && \
    apt-get install -y git curl

WORKDIR /app
COPY cr.sh /app/
RUN chmod +x /app/cr.sh

ENV DEBUG=true
ENV DRY_RUN=true
ENV GITHUB_TOKEN=dummy_token
ENV OCI_PASSWORD=dummy_password

CMD ["/app/cr.sh", "--oci-registry", "ghcr.io", "--oci-path", "myorg", "--oci-username", "myuser", "--charts-dir", "stable"]
EOF

# Build and run
docker build -t cr-test -f Dockerfile.test .
docker run cr-test
```

## Testing GitHub Action with act

You can test GitHub Actions locally using [act](https://github.com/nektos/act), a tool that allows you to run your GitHub Actions workflows locally.

### Installing act

There are several ways to install act:

**macOS (using Homebrew)**:
```bash
brew install act
```

**Linux (using Homebrew)**:
```bash
brew install act
```

**Using Go**:
```bash
go install github.com/nektos/act@latest
```

**Manual installation**:
1. Download the latest release from https://github.com/nektos/act/releases
2. Extract and add to your PATH

**Docker**:
```bash
docker pull nektos/act
alias act='docker run -it -v $(pwd):/github/workspace -v /var/run/docker.sock:/var/run/docker.sock nektos/act'
```

### Using act to test the GitHub Action

1. Create a test workflow file:

```yaml
# .github/workflows/test.yml
name: Test Workflow
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run helm-oci-charts-releaser
        uses: ./
        env:
          DEBUG: true
        with:
          oci_registry: ghcr.io
          oci_path: myorg
          oci_username: myuser
          oci_password: ${{ secrets.OCI_PASSWORD }}
          charts_dir: stable
          github_token: ${{ secrets.GITHUB_TOKEN }}
          version: v3.13.2
          mark_as_latest: true
```

2. Run with dummy secrets:
```bash
act -s GITHUB_TOKEN=dummy -s OCI_PASSWORD=dummy
```

### Advanced act usage

**List all actions in workflows**:
```bash
act -l
```

**Run specific jobs**:
```bash
act -j test
```

**Run specific events**:
```bash
act push
```

**Use a specific runner image**:
```bash
act -P ubuntu-latest=nektos/act-environments-ubuntu:18.04
```

**Use the default micro image (faster but fewer dependencies)**:
```bash
act -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

**Bind your local Docker socket**:
```bash
act --bind
```

**Get verbose output**:
```bash
act -v
```

### Common act issues and solutions

- **Error: No workflows found**: Make sure your workflow file is in `.github/workflows/`
- **Resource constraints**: Use `--container-daemon-socket /var/run/docker.sock` to use your host's Docker daemon
- **Missing secrets**: Use `-s SECRET_NAME=value` to pass secrets
- **Missing environment variables**: Use `-e ENV_NAME=value` to pass environment variables
- **Docker in Docker issues**: Use `--bind` to bind your local Docker socket

## Common Issues and Troubleshooting

- **Missing GITHUB_TOKEN**: Set with `export GITHUB_TOKEN=dummy` for testing
- **Missing OCI_PASSWORD**: Set with `export OCI_PASSWORD=dummy` for testing
- **Git issues**: Make sure you're running in a git repository with proper permissions
- **Chart detection**: If no charts are found, check your charts directory structure
- **GitHub CLI not installed**: If you're getting errors about `gh` not found, you can:
  - Install GitHub CLI from https://cli.github.com/
  - Use `--skip-gh-release true` to skip GitHub release operations
  - Set `DRY_RUN=true` to simulate operations without executing them 