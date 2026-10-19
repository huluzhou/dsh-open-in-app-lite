/**
 * dsh-open-in-app is a profile bundle, not a plugin: this module exists so the
 * package resolves as a regular ESM entry, while the composition lives in
 * `cordis.patch.yml` (declared through `dsh.bundle.patch`).
 */
export const name = 'dsh-open-in-app';
