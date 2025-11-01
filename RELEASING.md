# Releasing SAI

This document describes how to create a new release of SAI.

## Prerequisites

- Push access to the GitHub repository
- All tests passing: `go test ./...`
- Updated CHANGELOG or release notes ready

## Release Process

### 1. Update Version (Optional)

If you maintain a version file or want to update any version strings in the code, do so now.

### 2. Create and Push a Tag

The release workflow is triggered by pushing a tag starting with `v`:

```bash
# Make sure you're on main and up to date
git checkout main
git pull

# Create a tag (use semantic versioning)
git tag v0.1.0

# Push the tag to GitHub
git push origin v0.1.0
```

### 3. Automated Build Process

Once the tag is pushed, GitHub Actions will automatically:

1. ✅ Run all tests
2. ✅ Build binaries for:
   - macOS ARM64 (Apple Silicon)
   - macOS AMD64 (Intel)
   - Linux ARM64
   - Linux AMD64
3. ✅ Generate SHA256 checksums
4. ✅ Create a GitHub Release with all binaries attached
5. ✅ Add installation instructions to the release notes

### 4. Verify the Release

1. Go to: https://github.com/slomin/sai/releases
2. Find your new release
3. Download a binary and test it
4. Verify checksums match:
   ```bash
   shasum -a 256 sai-darwin-arm64
   # Compare with checksums.txt
   ```

## Release Workflow Details

The release workflow (`.github/workflows/release.yml`) does the following:

- **Triggers on**: Any tag matching `v*` (e.g., v0.1.0, v1.0.0, v1.2.3-beta)
- **Runs on**: macOS (for cross-compilation)
- **Builds**: 4 platform binaries
- **Publishes**: GitHub Release with binaries and installation instructions

## Versioning Scheme

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR** version (v1.0.0): Incompatible API changes
- **MINOR** version (v0.1.0): Add functionality in a backward compatible manner
- **PATCH** version (v0.0.1): Backward compatible bug fixes

### Pre-releases

For beta/alpha releases, append a suffix:

```bash
git tag v0.2.0-beta.1
git push origin v0.2.0-beta.1
```

## Troubleshooting

### Release Failed to Build

1. Check the Actions tab: https://github.com/slomin/sai/actions
2. Click on the failed workflow
3. Review the logs
4. Fix the issue and create a new tag

### Need to Delete a Release

```bash
# Delete the tag locally
git tag -d v0.1.0

# Delete the tag remotely
git push origin :refs/tags/v0.1.0
```

Then delete the release from GitHub UI and re-create if needed.

## macOS Code Signing (Future Enhancement)

Currently, binaries are **not** code signed or notarized. Users need to remove the quarantine attribute manually (which our install script does automatically).

To add proper code signing in the future:

1. Get an Apple Developer certificate ($99/year)
2. Add the certificate to GitHub Secrets
3. Update the workflow to sign with `codesign`
4. Notarize with `xcrun notarytool`
5. Staple the notarization ticket

This would eliminate the need for users to bypass Gatekeeper.

## Installation Methods Available

After release, users can install via:

1. **Quick install script** (recommended):
   ```bash
   curl -sSL https://raw.githubusercontent.com/slomin/sai/main/install.sh | bash
   ```

2. **Manual download** from GitHub Releases

3. **Build from source**:
   ```bash
   go install github.com/slomin/sai/cmd/sai@latest
   ```
