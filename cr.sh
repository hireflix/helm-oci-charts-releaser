#!/usr/bin/env bash

# Copyright The Helm Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

# Add debug functionality
DEBUG=${DEBUG:-false}
debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "DEBUG: $*" >&2
  fi
}

debug "Script started with arguments: $*"

DEFAULT_HELM_VERSION=v3.13.2
ARCH=$(uname)
ARCH="${ARCH,,}-amd64" # Official helm is available only for x86_64

released_charts=()
dry_run="${DRY_RUN:-false}"

show_help() {
  cat <<EOF
Usage: $(basename "$0") <options>

    -h, --help                    Display help
    -v, --version                 The helm version to use (default: $DEFAULT_HELM_VERSION)"
    -d, --charts-dir              The charts directory (default either: helm, chart or charts)
    -u, --oci-username            The username used to login to the OCI registry
    -r, --oci-registry            The OCI registry
    -p, --oci-path                The OCI path to construct full path as {{oci-registry}}/{{oci-path}}
    -t, --tag-name-pattern        Specifies GitHub repository release naming pattern (ex. '{chartName}-chart')
        --install-dir             Specifies custom install dir
        --skip-helm-install       Skip helm installation (default: false)
        --skip-dependencies       Skip dependencies update from "Chart.yaml" to dir "charts/" before packaging (default: false)
        --skip-existing           Skip the chart push if the GitHub release exists
        --skip-oci-login          Skip the OCI registry login (default: false)
    -l, --mark-as-latest          Mark the created GitHub release as 'latest' (default: true)
        --skip-gh-release         Skip the GitHub release creation
        --debug                   Enable debug logging
EOF
}

errexit() {
  >&2 echo "$*"
  exit 1
}

main() {
  local version="$DEFAULT_HELM_VERSION"
  local charts_dir=
  local oci_username=
  local oci_registry=
  local oci_path=
  local oci_host=
  local install_dir=
  local skip_helm_install=false
  local skip_dependencies=false
  local skip_existing=true
  local skip_oci_login=false
  local mark_as_latest=true
  local tag_name_pattern=
  local skip_gh_release=
  local repo_root=

  debug "Starting main function"
  parse_command_line "$@"

  debug "After parse_command_line - variable values:"
  debug "  version: $version"
  debug "  charts_dir: $charts_dir"
  debug "  oci_username: $oci_username"
  debug "  oci_registry: $oci_registry"
  debug "  skip_oci_login: $skip_oci_login"
  debug "  GITHUB_TOKEN set: $([ -n "${GITHUB_TOKEN:-}" ] && echo true || echo false)"
  debug "  OCI_PASSWORD set: $([ -n "${OCI_PASSWORD:-}" ] && echo true || echo false)"

  : "${GITHUB_TOKEN:?Environment variable GITHUB_TOKEN must be set}"
  if ( ! $skip_oci_login ) then
    : "${OCI_PASSWORD:?Environment variable OCI_PASSWORD must be set unless you skip oci login.}"
  fi

  (! $dry_run) || echo "===> DRY-RUN: TRUE"

  repo_root=$(git rev-parse --show-toplevel)
  pushd "$repo_root" >/dev/null

  find_charts_dir
  echo 'Looking up latest tag...'

  local latest_tag
  latest_tag=$(lookup_latest_tag)

  echo "Discovering changed charts since '$latest_tag'..."
  local changed_charts=()
  readarray -t changed_charts <<<"$(lookup_changed_charts "$latest_tag")"

  debug "Changed charts: ${changed_charts[*]}"
  
  if [[ -n "${changed_charts[*]}" ]]; then
    install_helm
    helm_login

    for chart in "${changed_charts[@]}"; do
      local desc name version info=()
      readarray -t info <<<"$(chart_info "$chart")"
      desc="${info[0]}"
      name="${info[1]}"
      version="${info[2]}"

      debug "Processing chart: $chart (name: $name, version: $version)"
      package_chart "$chart"
      release_chart "$chart" "$name" "$version" "$desc"
    done

    echo "released_charts=$(
      IFS=,
      echo "${released_charts[*]}"
    )" >released_charts.txt
  else
    echo "Nothing to do. No chart changes detected."
    echo "released_charts=" >released_charts.txt
  fi

  echo "chart_version=${latest_tag}" >chart_version.txt
  popd >/dev/null
}

parse_command_line() {
  debug "Parsing command line: $*"
  
  while [ "${1:-}" != "-" ]; do
    case "${1:-}" in
    -h | --help)
      show_help
      exit
      ;;
    -v | --version)
      if [[ -n "${2:-}" ]]; then
        version="$2"
        debug "Set version=$version"
        shift
      else
        echo "ERROR: '-v|--version' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -d | --charts-dir)
      if [[ -n "${2:-}" ]]; then
        charts_dir="$2"
        debug "Set charts_dir=$charts_dir"
        shift
      else
        echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -p | --oci-path)
      if [[ -n "${2:-}" ]]; then
        oci_path="$2"
        debug "Set oci_path=$oci_path"
        shift
      else
        echo "ERROR: '-p|--oci-path' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -u | --oci-username)
      if [[ -n "${2:-}" ]]; then
        oci_username="$2"
        debug "Set oci_username=$oci_username"
        shift
      else
        echo "ERROR: '--oci-username' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -r | --oci-registry)
      if [[ -n "${2:-}" ]]; then
        oci_registry="$2"
        debug "Set oci_registry=$oci_registry"
        shift
      else
        echo "ERROR: '--oci-registry' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --install-dir)
      if [[ -n "${2:-}" ]]; then
        install_dir="$2"
        debug "Set install_dir=$install_dir"
        shift
      fi
      ;;
    --skip-helm-install)
      if [[ -n "${2:-}" ]]; then
        skip_helm_install="$2"
        debug "Set skip_helm_install=$skip_helm_install"
        shift
      fi
      ;;
    --skip-dependencies)
      if [[ -n "${2:-}" ]]; then
        skip_dependencies="$2"
        debug "Set skip_dependencies=$skip_dependencies"
        shift
      fi
      ;;
    --skip-existing)
      if [[ -n "${2:-}" ]]; then
        skip_existing="$2"
        debug "Set skip_existing=$skip_existing"
        shift
      fi
      ;;
    --skip-oci-login)
      if [ "${2}" == "true" ]; then
        skip_oci_login=true
        debug "Set skip_oci_login=true"
        shift
      fi
      ;;
    -l | --mark-as-latest)
      if [[ -n "${2:-}" ]]; then
        mark_as_latest="$2"
        debug "Set mark_as_latest=$mark_as_latest"
        shift
      fi
      ;;
    -t | --tag-name-pattern)
      if [[ -n "${2:-}" ]]; then
        tag_name_pattern="$2"
        debug "Set tag_name_pattern=$tag_name_pattern"
        shift
      fi
      ;;
    --skip-gh-release)
      if [[ -n "${2:-}" ]]; then
        skip_gh_release="$2"
        debug "Set skip_gh_release=$skip_gh_release"
        shift
      fi
      ;;
    --debug)
      DEBUG=true
      debug "Debug logging enabled via command line"
      ;;
    *)
      break
      ;;
    esac

    shift
  done

  debug "Final validation of parameters"
  
  if ( ! $skip_oci_login ) then
    if [[ -z "$oci_username"  ]]; then
      debug "ERROR: oci_username is empty and skip_oci_login is false"
      echo "ERROR: '-u|--oci-username' is required unless you skip oci login." >&2
      show_help
      exit 1
    fi
  fi

  if [[ -z "$oci_registry" ]]; then
    debug "ERROR: oci_registry is empty"
    echo "ERROR: '-r|--oci-registry' is required." >&2
    show_help
    exit 1
  fi

  if [[ -n $tag_name_pattern && $tag_name_pattern != *"{chartName}"* ]]; then
    debug "ERROR: Invalid tag_name_pattern=$tag_name_pattern"
    echo "ERROR: Name pattern must contain '{chartName}' field." >&2
    show_help
    exit 1
  fi

  if [[ -z "$install_dir" ]]; then
    # use /tmp or RUNNER_TOOL_CACHE in GitHub Actions
    install_dir="${RUNNER_TOOL_CACHE:-/tmp}/cra/$ARCH"
    debug "Setting default install_dir=$install_dir"

    export HELM_CACHE_HOME="${install_dir}/.cache"
    export HELM_CONFIG_HOME="${install_dir}/.config"
    export HELM_DATA_HOME="${install_dir}.share"
    debug "Set HELM_* environment variables"
  fi
}

install_helm() {
  debug "In install_helm function"
  if ( "$skip_helm_install" ) && ( which helm &> /dev/null ); then
    echo "Skipng helm install. Using existing helm..."
    debug "Skip helm install - found existing helm at $(which helm 2>/dev/null || echo 'not found')"
    return
  elif ( "$skip_helm_install" ); then
    debug "ERROR: skip_helm_install=true but helm not found"
    errexit "ERROR: Remove --skip-helm-install or preinstall!"
  fi

  if [[ ! -x "$install_dir/helm" ]]; then
    debug "Need to install helm to $install_dir"
    mkdir -p "$install_dir"

    echo "Installing Helm ($version) to $install_dir..."
    curl -sSLo helm.tar.gz "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz"
    curl -sSL "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz.sha256sum" | \
      sed 's/helm-.*/helm.tar.gz/' > helm.sha256sum

    if ( ! sha256sum -c helm.sha256sum ); then
      rm -f helm.tar.gz helm.sha256sum
      errexit "ERROR: Aborting helm checksum is invalid"
    fi

    tar -C "$install_dir/.." -xzf helm.tar.gz "$ARCH/helm"
    rm -f helm.tar.gz helm.sha256sum
  else
    debug "Helm binary already exists at $install_dir/helm"
    echo "Helm is found in the install directory"
  fi

  echo 'Setting PATH to use helm from the install directory...'
  export PATH="$install_dir:$PATH"
  debug "Updated PATH=$PATH"
  debug "Helm version: $(helm version 2>/dev/null || echo 'not available')"
}

lookup_latest_tag() {
  debug "In lookup_latest_tag function"
  git fetch --tags >/dev/null 2>&1

  local tag
  tag=$(git describe --tags --abbrev=0 HEAD~ 2>/dev/null || git rev-list --max-parents=0 --first-parent HEAD)
  debug "Found latest tag: $tag"
  echo "$tag"
}

filter_charts() {
  debug "In filter_charts function"
  local charts=()
  while read -r path; do
    if [[ -f "${path}/Chart.yaml" ]]; then
      charts+=("$path")
    fi
  done
  debug "Filtered charts: ${charts[*]}"
  printf "%s\n" "${charts[@]}"
}

find_charts_dir() {
  debug "In find_charts_dir function (current charts_dir=$charts_dir)"
  local cdirs=()
  if [ -n "$charts_dir" ]; then 
    debug "Using existing charts_dir=$charts_dir"
    return
  fi
  if [ -f "helm/Chart.yaml" ]; then 
    debug "Found helm/Chart.yaml"
    cdirs+=(".")
  fi
  if [ -f "chart/Chart.yaml" ]; then 
    debug "Found chart/Chart.yaml"
    cdirs+=(".")
  fi
  if (( "${#cdirs[@]}" > 1 )); then
    debug "ERROR: Found multiple chart directories: ${cdirs[*]}"
    errexit "ERROR: Can't use both helm and chart directory."
  fi
  charts_dir="${cdirs[0]:-charts/}"
  debug "Set charts_dir=$charts_dir"
}

lookup_changed_charts() {
  debug "In lookup_changed_charts function, commit=$1"
  local commit="$1"

  local changed_files
  changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")
  debug "Changed files: $changed_files"

  local depth=$(($(tr "/" "\n" <<<"$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1))
  local fields="1-${depth}"
  debug "Depth=$depth, fields=$fields"

  local changed_dirs
  changed_dirs=$(cut -d '/' -f "$fields" <<<"$changed_files" | uniq)
  debug "Changed directories: $changed_dirs"
  
  local filtered_charts
  filtered_charts=$(filter_charts <<<"$changed_dirs")
  debug "Filtered charts: $filtered_charts"
  
  echo "$filtered_charts"
}

package_chart() {
  local chart="$1" flags=
  debug "In package_chart function, chart=$chart"
  ( $skip_dependencies ) || flags="-u"
  debug "Package flags: $flags"

  echo "Packaging chart '$chart'..."
  dry_run helm package "$chart" $flags -d "${install_dir}/package/$chart"
}

dry_run() {
  debug "In dry_run function, dry_run=$dry_run"
  # dry-run on
  if ($dry_run); then
    debug "Executing in dry-run mode: $*"
    { set -x; echo "$@" >/dev/null; set +x; } 2>&1 | sed '/set +x/d' >&2; return
  else
    debug "Executing: $*"
    "$@"
  fi
}

chart_info() {
  local chart_dir="$1"
  debug "In chart_info function, chart_dir=$chart_dir"
  # use readarray with the returned line
  local info
  info=$(helm show chart "$chart_dir" | sed -En '/^(description|name|version)/p' | sort | sed 's/^.*: //')
  debug "Chart info: $info"
  echo "$info"
}

# get github release tag
release_tag() {
  local name="$1" version="$2"
  debug "In release_tag function, name=$name, version=$version"
  local tag
  if [ -n "$tag_name_pattern" ]; then
    tag="${tag_name_pattern//\{chartName\}/$name}"
    debug "Using tag name pattern: $tag_name_pattern -> $tag"
  fi
  local result="${tag:-$name}-$version"
  debug "Release tag: $result"
  echo "$result"
}

release_exists() {
  local tag="$1"
  debug "In release_exists function, tag=$tag"
  # fields: release tagName date
  local exists
  exists=$(dry_run gh release ls | tr -s '[:blank:]' | sed -E 's/\sLatest//' | cut -f 1 | grep -q "$tag" && echo true || echo false)
  debug "Release exists: $exists"
  echo "$exists"
}

release_chart() {
  local releaseExists flags tag chart_package chart="$1" name="$2" version="$3" desc="$4"
  debug "In release_chart function, chart=$chart, name=$name, version=$version"
  
  tag=$(release_tag "$name" "$version")
  chart_package="${install_dir}/package/${chart}/${name}-${version}.tgz"
  debug "Tag: $tag, chart_package: $chart_package"
  
  releaseExists=$(release_exists "$tag")
  debug "Release exists: $releaseExists, skip_existing: $skip_existing"

  if ($releaseExists && $skip_existing); then
    echo "Release tag '$tag' is present. Skip chart push (skip_existing=true)..."
    return
  fi

  debug "Pushing chart to OCI registry: $oci_registry"
  # Use the oci_path when pushing to create the full repository path
  if [[ -n "$oci_path" ]]; then
    dry_run helm push "${chart_package}" "oci://${oci_registry#oci://}/${oci_path}/${name}"
  else
    dry_run helm push "${chart_package}" "oci://${oci_registry#oci://}/${name}"
  fi

  if (! $releaseExists && ! $skip_gh_release); then
    debug "Creating GitHub release"
    # shellcheck disable=SC2086
    (! $mark_as_latest) || flags="--latest"
    dry_run gh release create "$tag" $flags --title "$tag" --notes "$desc"
  fi

  # (re)upload package, i.e. overwrite, since skip_existing is not provided.
  if (! $skip_gh_release); then
    debug "Uploading chart package to GitHub release"
    dry_run gh release upload "$tag" "$chart_package" --clobber
    released_charts+=("$chart")
    debug "Added $chart to released_charts: ${released_charts[*]}"
  fi
}

helm_login() {
  debug "In helm_login function, skip_oci_login=$skip_oci_login"
  if ( $skip_oci_login ) then
    echo "Skipping helm login. Using existing credentials..."
    return
  fi
  # Get the cleared host url
  oci_registry="${oci_registry#oci://}"
  oci_host="${oci_registry%%/*}"
  debug "OCI registry: $oci_registry, OCI host: $oci_host"
  
  debug "Executing helm login with username: $oci_username"
  echo "$OCI_PASSWORD" | dry_run helm registry login -u "${oci_username}" --password-stdin "${oci_host}"
}

# If --debug CLI flag is provided, enable debugging
for arg in "$@"; do
  if [[ "$arg" == "--debug" ]]; then
    DEBUG=true
    debug "Debug logging enabled via command line argument"
    break
  fi
done

main "$@"
