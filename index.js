/**
 * Host half of the task dock bundle.
 *
 * The dock is a Client-only surface: the bottom bar and the floating panel read
 * the Client projections (workspaces, sessions, session status), and quick
 * capture goes through the Client `uiWorkspace` and `sessions` services. No
 * Host routes, commands or background work are registered.
 */
export function apply() {}
