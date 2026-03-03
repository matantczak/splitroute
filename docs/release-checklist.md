# Release Checklist (GO/NO-GO)

Use this list before pushing and creating a GitHub release.

## 1. Build and basic integrity

- [ ] `bash scripts/build_menubar_app.sh` completes successfully.
- [ ] `sudo bash scripts/workflow_menubar_app.sh` completes successfully.
- [ ] `bash scripts/verify_menubar_install.sh` returns `OK`.
- [ ] `bash -n bin/splitroute scripts/*.sh` returns no syntax errors.
- [ ] App process runs from `/Applications/SplitrouteMenuBar.app/Contents/MacOS/SplitrouteMenuBar`.

## 2. Versioning and install target

- [ ] `CFBundleShortVersionString` is set to intended release version.
- [ ] `CFBundleVersion` is unique for this build.
- [ ] `/Applications/SplitrouteMenuBar.app` version/build matches `build/SplitrouteMenuBar.app`.
- [ ] Dock entry points to `/Applications/SplitrouteMenuBar.app`.

## 3. Core behavior

- [ ] `Turn ON` enables routing only when clicked manually.
- [ ] No Auto-OFF behavior is present in the menu.
- [ ] `Turn OFF` removes splitroute-managed routes and resolver state.
- [ ] Service files in `services/<service>/` remain unchanged after ON/OFF.

## 4. Startup/reset behavior

- [ ] After leaving splitroute ON, restarting app triggers stale-state cleanup prompt/action.
- [ ] After reboot/login and app start, stale state is cleaned (routes/resolvers), but service host files are still present.
- [ ] Status icon reflects ON/OFF based on active splitroute state, not only currently selected services.
- [ ] Launching from Dock starts the same updated build as `/Applications/SplitrouteMenuBar.app`.

## 5. Network-change and discovery UX

- [ ] Network change notification appears only when routing is active.
- [ ] Notification action `Refresh` works.
- [ ] `Add Service...` supports both:
  - [ ] basic create (no discovery),
  - [ ] Smart Host Discovery with explicit consent.

## 6. Documentation and repo hygiene

- [ ] Main docs are in English (`README.md`, `docs/*.md`).
- [ ] No accidental file mode noise in `git diff --summary`.
- [ ] `.gitignore` is present and excludes non-committable local artifacts.

## 7. Security and privacy checks

- [ ] No secrets, tokens, private keys, or credentials are included in tracked changes.
- [ ] No code path disables TLS verification or introduces MITM/proxy behavior.
- [ ] Cleanup routines do not delete user-managed service definitions.

## GO / NO-GO

- **GO**: all items above checked.
- **NO-GO**: any unchecked critical item in sections 1, 2, 3, 4, or 7.
