# Building a receiver with its source revision

Xcode's existing iOS and tvOS SwiftFormat phases now use `--lint`. They inspect
formatting and never rewrite source during compilation. Format only the files
you changed, before capturing the revision, for example:

```sh
/opt/homebrew/bin/swiftformat path/to/Changed.swift
```

Use the wrapper for a stamped build. It computes `KIDS_EVIDENCE_REVISION`, passes
it to the single Xcode invocation, and checks for source drift after a successful
build. It does not install or launch an app and never automatically retries. Do
not pass a manual revision. Other compiler, signing and cache options remain
ordinary Xcode arguments.

```sh
python3 Scripts/Kids/build_with_revision.py -- \
  -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin tvOS' \
  -configuration Debug -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath /private/tmp/kids-receiver-tvos-build \
  -clonedSourcePackagesDirPath /private/tmp/kids-receiver-tvos-build/SourcePackages \
  -skipMacroValidation -skipPackagePluginValidation \
  -disableAutomaticPackageResolution -skipPackageUpdates -jobs 4 \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

For a release candidate, generate a Pacific `YYYYMMDD-HHMM` identifier and pass
it before `--`. The wrapper supplies the canonical release ID, marketing
version, build number, and source revision to the same Xcode invocation.

```sh
python3 Scripts/Kids/release_metadata.py version
python3 Scripts/Kids/build_with_revision.py --release-version 20261022-0937 -- \
  -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin tvOS' \
  -configuration Release -destination 'generic/platform=tvOS Simulator' build
```

The implementation digest covers both the tvOS child runtime and the iOS Parents app sources. Before release, both built bundles must expose the same `KidsEvidenceImplementationRevision` and `KidsReleaseVersion` values.

If another editor changes implementation inputs during the build, the wrapper
reports stale identity and exits unsuccessfully even if compilation passed. Keep
that result out of runtime acceptance. Resolve edits and use the next planned
build boundary, rather than repeatedly rebuilding just to update a stamp.
