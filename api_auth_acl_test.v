module main

// Pure ACL policy tests (SDDL parsing and the SID allowlist); run on every OS.

const sample_user_sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'

fn test_sddl_trustees_are_extracted_from_every_ace() {
	sddl := 'D:PAI(A;OICIID;FA;;;${sample_user_sid})(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BA)(A;;0x1200a9;;;WD)S:AI(ML;;NW;;;LW)'
	assert parse_sddl_trustees(sddl) == [sample_user_sid, 'SY', 'BA', 'WD']
	assert parse_sddl_trustees('D:P(A;;FA;;;${sample_user_sid})') == [sample_user_sid]
	assert parse_sddl_trustees('') == []string{}
}

fn test_allowlist_accepts_user_system_and_administrators_only() {
	user := sample_user_sid
	assert first_disallowed_trustee([user], user, true) == none
	assert first_disallowed_trustee([user, 'SY', 'BA'], user, true) == none
	assert first_disallowed_trustee([user.to_lower(), 'S-1-5-18', 'S-1-5-32-544'], user, true) == none
	// Everyone, BUILTIN\Users, Authenticated Users, ANONYMOUS, NETWORK, INTERACTIVE.
	for broad in ['WD', 'S-1-1-0', 'BU', 'S-1-5-32-545', 'AU', 'S-1-5-11', 'AN', 'NU', 'IU'] {
		assert (first_disallowed_trustee([user, 'SY', broad], user, true) or { '' }) == broad
	}
	// Another local user, and an empty/garbled ACL, fail closed.
	other := 'S-1-5-21-1111111111-2222222222-3333333333-1002'
	assert (first_disallowed_trustee([user, other], user, true) or { '' }) == other
	assert first_disallowed_trustee([user, ''], user, true) != none
	assert first_disallowed_trustee([]string{}, user, true) != none
}

fn test_icacls_save_output_is_decoded_from_utf16() {
	mut raw := [u8(0xff), 0xfe]
	for c in 'D:P(A;;FA;;;SY)'.bytes() {
		raw << c
		raw << u8(0)
	}
	assert decode_icacls_save(raw) == 'D:P(A;;FA;;;SY)'
}

fn test_machine_relative_aliases_expand_from_the_users_own_sid() {
	machine := 'S-1-5-21-1111111111-2222222222-3333333333'
	// The runner user IS the local Administrator account (RID 500): LA is the user.
	admin := '${machine}-500'
	assert resolve_sddl_trustee('LA', admin, true) or { '' } == admin
	assert first_disallowed_trustee([admin.to_lower(), 'LA', 'SY', 'BA'], admin, true) == none
	// A different local user: LA expands to -500, which is NOT allowed.
	user := '${machine}-1001'
	assert resolve_sddl_trustee('LA', user, true) or { '' } == '${machine}-500'
	assert resolve_sddl_trustee('LG', user, true) or { '' } == '${machine}-501'
	assert (first_disallowed_trustee([user, 'LA'], user, true) or { '' }) == 'LA'
	// A domain user cannot resolve machine-relative aliases: fail closed.
	assert resolve_sddl_trustee('LA', user, false) == none
	assert (first_disallowed_trustee([user, 'LA'], user, false) or { '' }) == 'LA'
	// Unknown aliases (domain admins, ...) fail closed everywhere.
	for alias in ['DA', 'DU', 'ZZ', 'xx'] {
		assert resolve_sddl_trustee(alias, user, true) == none
		assert (first_disallowed_trustee([user, alias], user, true) or { '' }) == alias
	}
	// Fixed aliases resolve to their well-known SIDs.
	assert resolve_sddl_trustee('SY', user, true) or { '' } == 'S-1-5-18'
	assert resolve_sddl_trustee('wd', user, true) or { '' } == 'S-1-1-0'
	assert resolve_sddl_trustee('BA', user, false) or { '' } == 'S-1-5-32-544'
}
