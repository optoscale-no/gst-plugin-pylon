#!/bin/bash

# Function to parse the L4T version string and format it
parse_nvidia_version() {
    local version_string="$1"
    local major minor revision date formatted_date

    # Extract major version (e.g., 35)
    major=$(echo "$version_string" | grep -oP '(?<=# R)[0-9]+')

    # Extract minor version and revision (e.g., 4.1)
    minor_revision=$(echo "$version_string" | grep -oP '(?<=REVISION: )[0-9]+\.[0-9]+')
    minor=$(echo "$minor_revision" | cut -d. -f1)
    revision=$(echo "$minor_revision" | cut -d. -f2)

    # Extract date (e.g., Tue Aug  1 19:57:35 UTC 2023)
    date=$(echo "$version_string" | grep -oP '(?<=DATE: ).*')

    # Format date (e.g., 20230801195735)
    formatted_date=$(date -d "$date" +'%Y%m%d%H%M%S')

    # Combine into desired format (e.g., 35.4.1-20230801195735)
    echo "${major}.${minor}.${revision}-${formatted_date}"
}

# Function to detect the platform version from /etc/os-release
detect_os_version() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID}-${VERSION_ID}"
    else
        echo "unknown"
    fi
}

# Extract L4T version information from /etc/nv_tegra_release
if [[ -f /etc/nv_tegra_release ]]; then
    nvidia_version_string=$(head -n 1 /etc/nv_tegra_release)
    PLATFORM_VERSION=$(parse_nvidia_version "$nvidia_version_string")
else
    PLATFORM_VERSION=$(detect_os_version)
fi

echo "Platform version is: $PLATFORM_VERSION"

changelog_file="packaging/debian/changelog"

# Check if the changelog file exists
if [ ! -f "$changelog_file" ]; then
    echo "Error: Changelog file '$changelog_file' not found."
    exit 1
fi

# Create a temporary file
temp_file=$(mktemp)

# Extract the current version from the changelog
current_version=$(head -n 1 "$changelog_file" | sed -n 's/.*(\(.*\)).*/\1/p')

# Remove any existing suffix and create the new version with the platform and version suffix
base_version=$(echo "$current_version" | sed 's/-1~.*//')
new_version="${base_version}-1~${PLATFORM_VERSION}"

# Replace the version in the first line of the changelog
sed "1s/(${current_version})/(${new_version})/" "$changelog_file" > "$temp_file"

# Check if sed command was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to modify the changelog."
    rm "$temp_file"
    exit 1
fi

# Replace the original file with the modified version
mv "$temp_file" "$changelog_file"

echo "Changelog updated successfully to version ${new_version}"

# prepare patching the control file

# Check if pylon package is installed
if ! dpkg -s pylon &> /dev/null; then
    echo "Error: pylon package is not installed" >&2
    exit 1
fi

# Get the exact Pylon package version (e.g. 6.2.0.21487-deb0)
PYLON_VERSION=$(dpkg -s pylon | awk '/^Version:/ {print $2}')

if [[ -z "$PYLON_VERSION" ]]; then
    echo "Error: could not determine pylon version" >&2
    exit 1
fi

# Pin every pylon dependency (Build-Depends and Depends) to the exact version
sed -i "s/pylon,/pylon (= $PYLON_VERSION),/g" debian/control

echo "Pylon dependency set to ${PYLON_VERSION}"

# Embed the Pylon version into the package version string so the .deb
# filename and dpkg metadata make the build-time Pylon version obvious.
PYLON_MAJOR_MINOR=$(echo "$PYLON_VERSION" | awk -F. '{print $1"."$2}')
current_cl_version=$(head -n 1 "$changelog_file" | sed -n 's/.*(\(.*\)).*/\1/p')
new_cl_version="${current_cl_version}+pylon${PYLON_MAJOR_MINOR}"
sed -i "1s/(${current_cl_version})/(${new_cl_version})/" "$changelog_file"

echo "Package version set to ${new_cl_version}"

# Detect the system Python version and patch debian/rules and debian/control
# accordingly. On Ubuntu 18.04 (JetPack 4) the default python3 is 3.6, which
# is too old for meson; use python3.7 if available.
SYS_PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

if [[ "$(echo "$SYS_PYTHON_VERSION < 3.7" | bc)" -eq 1 ]]; then
    if command -v python3.7 &> /dev/null; then
        echo "System python3 is $SYS_PYTHON_VERSION (too old), using python3.7"
        sed -i 's/PYTHON_FOR_VENV := python3$/PYTHON_FOR_VENV := python3.7/' debian/rules
        sed -i 's/python3-dev,/python3.7-dev,/' debian/control
    else
        echo "Error: system python3 is $SYS_PYTHON_VERSION and python3.7 is not installed" >&2
        exit 1
    fi
else
    echo "Using system python3 ($SYS_PYTHON_VERSION)"
fi

