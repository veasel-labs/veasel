module main

import os

// native_secret_backend picks the OS credential store. Tests never reach a
// real keyring unless VEASEL_NATIVE_KEYCHAIN_TEST=1 is set explicitly.
fn native_secret_backend() SecretBackend {
	$if test {
		if os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST') != '1' {
			return UnavailableSecretBackend{
				reason: 'native keychain is disabled under v test'
			}
		}
	}
	$if macos {
		return MacKeychainBackend{}
	} $else $if linux {
		return SecretToolBackend{}
	} $else {
		return UnavailableSecretBackend{
			reason: 'no native credential store is supported on this platform'
		}
	}
}
