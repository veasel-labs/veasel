module main

// Platform-independent ACL policy for the Windows token file and data
// directory (the parsers are pure so they are unit-tested on every OS).
//
// Policy: an explicit ALLOWLIST by SID. Only the current user, LocalSystem
// and BUILTIN\Administrators may appear in the DACL. SYSTEM and
// administrators can reach the file regardless (an administrator can take
// ownership, SYSTEM is the OS), so they are outside the threat model; every
// other principal (Everyone, Users, Authenticated Users, other users or
// groups, ANONYMOUS, NETWORK, ...) is refused. Every trustee from `icacls /save` is resolved to a
// real SID (aliases such as LA are machine-relative) and SIDs are compared,
// never display names.

const acl_allowed_sids = ['S-1-5-18', 'S-1-5-32-544']

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

// Resolves an SDDL trustee to a real SID. Some aliases are machine-relative
// (LA = <machine SID>-500, LG = <machine SID>-501), so they are expanded from
// the current user's own SID prefix and only when that user is a LOCAL
// account (its domain part is this machine). For a domain account, or any
// alias that cannot be resolved with certainty, there is no answer and the
// caller fails closed.
fn resolve_sddl_trustee(trustee string, user_sid string, user_is_local bool) ?string {
	if trustee.to_upper().starts_with('S-1-') {
		return trustee.to_upper()
	}
	fixed := match trustee.to_upper() {
		'WD' { 'S-1-1-0' }
		'AN' { 'S-1-5-7' }
		'NU' { 'S-1-5-2' }
		'IU' { 'S-1-5-4' }
		'SY' { 'S-1-5-18' }
		'AU' { 'S-1-5-11' }
		'BA' { 'S-1-5-32-544' }
		'BU' { 'S-1-5-32-545' }
		'BG' { 'S-1-5-32-546' }
		'PU' { 'S-1-5-32-547' }
		'CO' { 'S-1-3-0' }
		'OW' { 'S-1-3-4' }
		else { '' }
	}
	if fixed.len > 0 {
		return fixed
	}
	rid := match trustee.to_upper() {
		'LA' { '500' }
		'LG' { '501' }
		else { '' }
	}
	if rid.len == 0 || !user_is_local || !user_sid.to_upper().starts_with('S-1-5-21-') {
		return none
	}
	last := user_sid.last_index('-') or { return none }
	return '${user_sid[..last].to_upper()}-${rid}'
}

// Returns the first trustee (as printed) whose RESOLVED SID is neither the
// current user nor an allowlisted principal, or none when the ACL is
// acceptable. Unresolvable trustees are disallowed (fail closed).
fn first_disallowed_trustee(trustees []string, user_sid string, user_is_local bool) ?string {
	if trustees.len == 0 {
		return 'an empty or unreadable ACL'
	}
	user := user_sid.to_upper()
	for trustee in trustees {
		if trustee.len == 0 {
			return 'a malformed entry'
		}
		sid := resolve_sddl_trustee(trustee, user_sid, user_is_local) or { return trustee }
		if sid != user && sid !in acl_allowed_sids {
			return trustee
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
