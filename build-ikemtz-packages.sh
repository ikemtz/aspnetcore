#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_output="$repo_root/artifacts/packages/Release/Shipping"
package_version="${1:-10.0.13.4}"
build_properties="$(mktemp "$repo_root/.build-ikemtz-packages.XXXXXX.props")"

cleanup() {
    rm -f "$build_properties"
}
trap cleanup EXIT

set +u
source "$repo_root/activate.sh"
set -u
mkdir -p "$package_output"

command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required to update the NuGet package manifests.\n' >&2
    exit 1
}

if ! dotnet --version >/dev/null 2>&1; then
    printf 'The repository-pinned .NET SDK is unavailable. Run %s/restore.sh first.\n' "$repo_root" >&2
    exit 1
fi

cat > "$build_properties" <<'XML'
<Project>
  <PropertyGroup Condition="'$(MSBuildProjectName)' == 'Microsoft.AspNetCore.Http.Results'">
    <PackageId>IkeMtz.AspNetCore.Http.Results</PackageId>
    <IsPackable>true</IsPackable>
  </PropertyGroup>
</Project>
XML

patch_package_manifest() {
    local package_path="$1"
    local expected_id="$2"
    local package_kind="$3"

    python3 - "$package_path" "$expected_id" "$package_kind" "$package_version" <<'PY'
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

package_path, expected_id, package_kind, package_version = sys.argv[1:]

with zipfile.ZipFile(package_path, "r") as source:
    nuspecs = [entry for entry in source.infolist() if entry.filename.endswith(".nuspec")]
    if len(nuspecs) != 1:
        raise RuntimeError(f"Expected one nuspec in {package_path}, found {len(nuspecs)}")

    nuspec_entry = nuspecs[0]
    root = ET.fromstring(source.read(nuspec_entry))
    namespace_uri = root.tag.partition("}")[0].lstrip("{")
    ET.register_namespace("", namespace_uri)
    namespace = {"nuspec": namespace_uri}
    metadata = root.find("nuspec:metadata", namespace)
    if metadata is None:
        raise RuntimeError(f"Missing package metadata in {package_path}")

    package_id = metadata.findtext("nuspec:id", namespaces=namespace)
    version = metadata.findtext("nuspec:version", namespaces=namespace)
    if package_id != expected_id or version != package_version:
        raise RuntimeError(f"Unexpected package identity in {package_path}: {package_id} {version}")

    dependencies = metadata.findall(".//nuspec:dependency", namespace)
    if not dependencies:
        raise RuntimeError(f"No dependencies found in {package_path}")

    if package_kind == "http-results":
        for dependency in dependencies:
            dependency.set("version", "2.3.13")
    else:
        http_results_dependencies = [
            dependency for dependency in dependencies
            if dependency.get("id", "").casefold() in {
                "microsoft.aspnetcore.http.results",
                "ikemtz.aspnetcore.http.results",
            }
        ]
        if len(http_results_dependencies) != 1:
            raise RuntimeError(
                f"Expected one Http.Results dependency in {package_path}, found {len(http_results_dependencies)}"
            )

        for dependency in dependencies:
            if dependency in http_results_dependencies:
                dependency.set("id", "IkeMtz.AspNetCore.Http.Results")
                dependency.set("version", package_version)
            elif dependency.get("id", "").casefold() == "microsoft.openapi":
                dependency.set("version", "2.12.2")
            else:
                dependency.set("version", "2.3.13")

        required_dependencies = {
            "Microsoft.AspNetCore.Http.Extensions": "2.3.13",
            "Microsoft.AspNetCore.Authentication.Abstractions": "2.3.13",
            "Microsoft.AspNetCore.Hosting.Abstractions": "2.3.13",
            "Microsoft.AspNetCore.Routing": "2.3.13",
        }
        for dependency_list in metadata.findall(".//nuspec:dependencies", namespace):
            groups = dependency_list.findall("nuspec:group", namespace)
            dependency_groups = groups or [dependency_list]
            for dependency_group in dependency_groups:
                present_ids = {
                    dependency.get("id", "").casefold()
                    for dependency in dependency_group.findall("nuspec:dependency", namespace)
                }
                for dependency_id, dependency_version in required_dependencies.items():
                    if dependency_id.casefold() not in present_ids:
                        ET.SubElement(
                            dependency_group,
                            f"{{{namespace_uri}}}dependency",
                            {"id": dependency_id, "version": dependency_version},
                        )

    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=os.path.dirname(package_path), suffix=".nupkg", delete=False) as temporary:
            temporary_path = temporary.name
        with zipfile.ZipFile(package_path, "r") as source, zipfile.ZipFile(temporary_path, "w") as destination:
            for entry in source.infolist():
                contents = (
                    ET.tostring(root, encoding="utf-8", xml_declaration=True)
                    if entry.filename == nuspec_entry.filename
                    else source.read(entry)
                )
                destination.writestr(entry, contents)
        os.replace(temporary_path, package_path)
    finally:
        if temporary_path is not None and os.path.exists(temporary_path):
            os.unlink(temporary_path)
PY
}

dotnet pack "$repo_root/src/Http/Http.Results/src/Microsoft.AspNetCore.Http.Results.csproj" \
    --configuration Release \
    --output "$package_output" \
    -p:CustomAfterMicrosoftCommonTargets="$build_properties" \
    -p:PackageVersion="$package_version"

shopt -s nullglob
http_results_packages=("$package_output/IkeMtz.AspNetCore.Http.Results.$package_version"*.nupkg)
if [ ! -f "$package_output/IkeMtz.AspNetCore.Http.Results.$package_version.nupkg" ]; then
    printf 'The Http.Results package was not created in %s.\n' "$package_output" >&2
    exit 1
fi

for package in "${http_results_packages[@]}"; do
    patch_package_manifest "$package" "IkeMtz.AspNetCore.Http.Results" "http-results"
done

dotnet pack "$repo_root/src/OpenApi/src/Microsoft.AspNetCore.OpenApi.csproj" \
    --configuration Release \
    --output "$package_output" \
    -p:CustomAfterMicrosoftCommonTargets="$build_properties" \
    -p:PackageVersion="$package_version"

openapi_packages=("$package_output/IkeMtz.AspNetCore.OpenApi.$package_version"*.nupkg)
if [ ! -f "$package_output/IkeMtz.AspNetCore.OpenApi.$package_version.nupkg" ]; then
    printf 'The OpenApi package was not created in %s.\n' "$package_output" >&2
    exit 1
fi

for package in "${openapi_packages[@]}"; do
    patch_package_manifest "$package" "IkeMtz.AspNetCore.OpenApi" "openapi"
done

for package in \
    "$package_output/IkeMtz.AspNetCore.Http.Results.$package_version.nupkg" \
    "$package_output/IkeMtz.AspNetCore.OpenApi.$package_version.nupkg"; do
    if [ ! -s "$package" ]; then
        printf 'Expected package file was not created: %s\n' "$package" >&2
        exit 1
    fi

    printf 'Package created: %s\n' "$package"
done
