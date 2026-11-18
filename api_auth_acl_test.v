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
	assert first_disallowed_trustee([user], user) == none
	assert first_disallowed_trustee([user, 'SY', 'BA'], user) == none
	assert first_disallowed_trustee([user.to_lower(), 'S-1-5-18', 'S-1-5-32-544'], user) == none
	// Everyone, BUILTIN\Users, Authenticated Users, ANONYMOUS, NETWORK, INTERACTIVE.
	for broad in ['WD', 'S-1-1-0', 'BU', 'S-1-5-32-545', 'AU', 'S-1-5-11', 'AN', 'NU', 'IU'] {
		assert (first_disallowed_trustee([user, 'SY', broad], user) or { '' }) == broad
	}
	// Another local user, and an empty/garbled ACL, fail closed.
	other := 'S-1-5-21-1111111111-2222222222-3333333333-1002'
	assert (first_disallowed_trustee([user, other], user) or { '' }) == other
	assert first_disallowed_trustee([user, ''], user) != none
	assert first_disallowed_trustee([]string{}, user) != none
}

fn test_icacls_save_output_is_decoded_from_utf16() {
	mut raw := [u8(0xff), 0xfe]
	for c in 'D:P(A;;FA;;;SY)'.bytes() {
		raw << c
		raw << u8(0)
	}
	assert decode_icacls_save(raw) == 'D:P(A;;FA;;;SY)'
}
