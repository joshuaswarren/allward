/* SwiftPM needs a compilable translation unit to treat this as a C target and
 * expose `include/` to Swift. The SSH implementation itself lives in
 * rust/allward-ssh and arrives as a static archive, so there is nothing to
 * compile here.
 *
 * Declaring an unused static keeps the translation unit non-empty without adding
 * a symbol to the link.
 */
static const int allward_ssh_shim_placeholder = 0;
