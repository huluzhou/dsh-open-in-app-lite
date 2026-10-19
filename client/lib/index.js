/**
 * Open-in-app browsing surface, node half. Pure UI plugin: the empty apply
 * exists so the plugin appears in the host cordis.yml / Loader; the browser
 * half ships via exports["./client"], discovered through the package.json
 * dsh.client declaration. The routes it drives live in
 * `dsh-local-open-in-app`.
 */
export function apply() {}
