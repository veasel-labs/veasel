module main

// Platform-independent ACL policy for the Windows token file and data
// directory (the parsers are pure so they are unit-tested on every OS).
//
// Policy: an explicit ALLOWLIST by SID. Only the current user, LocalSystem
// and BUILTIN\Administrators may appear in the DACL. SYSTEM and
// administrators can reach the file regardless (an administrator can take
// ownership, SYSTEM is the OS), so they are outside the threat model; every
// other principal (Everyone, Users, Authenticated Users, other users or
// groups, ANONYMOUS, NETWORK, ...) is refused. Trustees are compared as SIDs
// or SDDL aliases from `icacls /save`, never as localized display names.

const acl_allowed_trustees = ['SY', 'BA', 'S-1-5-18', 'S-1-5-32-544']

// Extracts the trustee (6th field) of every ACE in the DACL of an SDDL
// string such as `D:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;;FA;;;SY)`.
// Parsing stops at the SACL (`S:`). A malformed ACE yields an empty
// trustee, which the policy rejects (fail closed).
fn parse_sddl_trustees(sddl string) []string {
	mut dacl := sddl
	if idx := dacl.index('D:') {
		dacl = dacl[idx + 2..]
	}
	if idx := dacl.index('S:') {
		dacl = dacl[..idx]
	}
	mut trustees := []string{}
	mut depth := 0
	mut start := 0
	for i, c in dacl {
		if c == `(` {
			if depth == 0 {
				start = i + 1
			}
			depth++
		} else if c == `)` && depth > 0 {
			depth--
			if depth == 0 {
				fields := dacl[start..i].split(';')
				trustees << if fields.len >= 6 { fields[5].trim_space() } else { '' }
			}
		}
	}
	return trustees
}

// Returns the first trustee that is neither the current user nor an
// allowlisted principal, or none when the ACL is acceptable.
fn first_disallowed_trustee(trustees []string, user_sid string) ?string {
	if trustees.len == 0 {
		return 'an empty or unreadable ACL'
	}
	user := user_sid.to_upper()
	for trustee in trustees {
		t := trustee.to_upper()
		if t.len == 0 || (t != user && t !in acl_allowed_trustees) {
			return if trustee.len == 0 { 'a malformed entry' } else { trustee }
		}
	}
	return none
}

// `icacls /save` writes UTF-16 on Windows; SDDL is ASCII, so dropping NUL
// bytes and the BOM yields the text.
fn decode_icacls_save(raw []u8) string {
	mut text := []u8{cap: raw.len}
	for b in raw {
		if b != 0 && b != 0xff && b != 0xfe {
			text << b
		}
	}
	return text.bytestr()
}

// SID for an SDDL trustee, so `icacls /remove *<SID>` can drop it. Returns
// an empty string for an alias this table does not know (the caller then
// fails closed instead of guessing).
fn sddl_trustee_sid(trustee string) string {
	if trustee.starts_with('S-1-') {
		return trustee
	}
	return match trustee.to_upper() {
		'WD' { 'S-1-1-0' }
		'AN' { 'S-1-5-7' }
		'NU' { 'S-1-5-2' }
		'IU' { 'S-1-5-4' }
		'AU' { 'S-1-5-11' }
		'BU' { 'S-1-5-32-545' }
		'BG' { 'S-1-5-32-546' }
		'PU' { 'S-1-5-32-547' }
		'CO' { 'S-1-3-0' }
		else { '' }
	}
}
