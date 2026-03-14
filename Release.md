# Release Process

This repository ships Debian package artifacts and publishes them on GitHub releases.

The examples below use release `v1.1.0` and Debian package version `1.1.0-1`. Replace those values for the next release.

## Preconditions

- `gh auth status` succeeds
- `make test` passes
- `make build` works on the current branch
- you are on the branch you want to release from

Optional but recommended before updating the changelog:

```bash
export DEBEMAIL="aok@stein.ispnet"
export DEBFULLNAME="Alex O. Karasulu"
```

## 1. Update the Debian changelog

Create or update the top changelog entry:

```bash
dch -v 1.1.0-1 "Release v1.1.0."
```

Set the Debian distribution explicitly. For this project, use `trixie`:

```bash
sed -i '1s/ jammy; / trixie; /' debian/changelog
```

If needed, fix the maintainer email on the top entry:

```bash
sed -i '5s#<aok@localhost>#<aok@stein.ispnet>#' debian/changelog
```

Verify:

```bash
sed -n '1,8p' debian/changelog
```

Expected top line:

```text
raid-drive-validator (1.1.0-1) trixie; urgency=medium
```

## 2. Run tests

```bash
make test
```

## 3. Build release artifacts

```bash
make build
```

Verify that the artifacts exist in the repository root:

```bash
ls -1 raid-drive-validator_1.1.0-1_all.deb \
      raid-drive-validator_1.1.0-1_amd64.buildinfo \
      raid-drive-validator_1.1.0-1_amd64.changes
```

## 4. Commit the release

```bash
git add debian/changelog README.md Makefile bin/ dashboard/ debian/ examples/ lib/ tests/ tools/ .gitignore Release.md
git commit -m "Release v1.1.0"
```

## 5. Tag the release

```bash
git tag -a v1.1.0 -m "raid-drive-validator v1.1.0"
```

## 6. Push branch and tag

```bash
git push origin main
git push origin v1.1.0
```

## 7. Create the GitHub release and upload artifacts

```bash
gh release create v1.1.0 \
  ./raid-drive-validator_1.1.0-1_all.deb \
  ./raid-drive-validator_1.1.0-1_amd64.buildinfo \
  ./raid-drive-validator_1.1.0-1_amd64.changes \
  --verify-tag \
  --title "v1.1.0" \
  --generate-notes
```

## 8. Verify release state

Check local git state:

```bash
git log --oneline --decorate -n 5
git status --short
```

Check the GitHub release:

```bash
gh release view v1.1.0 --json tagName,targetCommitish,assets,url
```

## Notes

- Any change to `debian/changelog` or packaged source files requires a rebuild before release.
- `make build` copies artifacts into the repository root.
- Each burn-in batch run writes into its own timestamped report directory under `drive_test_reports/`.
