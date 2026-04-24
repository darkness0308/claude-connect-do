# claude-connect-do v1.0.2 Release Notes

## Summary

v1.0.2 is a release-quality patch focused on consistency, correctness, and publishing hygiene.

This version aligns all public version outputs and release artifacts so users see the same version across npm metadata, CLI version commands, README examples, and release documentation.

---

## What's New in 1.0.2

### 1. Version Consistency Fixes

Resolved mixed version reporting across repository artifacts:

- Updated package metadata to `1.0.2`
- Updated bash launcher runtime version string (`bin/claude-connect-do`)
- Updated PowerShell launcher runtime version string (`bin/claude-connect-do.ps1`)
- Updated lockfile package version metadata to match release version

Result: `claude-connect-do version`, package metadata, and release assets now consistently identify `1.0.2`.

---

### 2. Documentation and Release Artifact Corrections

- Corrected `RELEASE_NOTES_1.0.2.md` content (previously still labeled as `v1.0.1`)
- Updated README tarball installation example to use `claude-connect-do-<version>.tgz` instead of a stale hardcoded version
- Added explicit current stable release marker in README (`v1.0.2`)

Result: Users following docs no longer copy outdated version strings.

---

## Installation / Upgrade

```bash
npm install -g claude-connect-do@latest
claude-connect-do version
```

Expected output includes version `1.0.2`.

---

## Breaking Changes

None.

This is a patch release intended to be a safe drop-in upgrade from `1.0.1`.

---

## Validation Checklist

- Version in `package.json`: `1.0.2`
- Version in `package-lock.json`: `1.0.2`
- Version constant in bash launcher: `1.0.2`
- Version constant in PowerShell launcher: `1.0.2`
- Changelog includes `1.0.2` entry
- README examples no longer hardcode old tarball versions

---

## Support

- GitHub Repository: https://github.com/darkness0308/claude-connect-do
- npm Package: https://www.npmjs.com/package/claude-connect-do
- Issues: https://github.com/darkness0308/claude-connect-do/issues
