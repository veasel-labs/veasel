module main

import os

// Windows Credential Manager through advapi32 (no process, no argv).

#flag windows -ladvapi32
#include <windows.h>
#include <wincred.h>

@[typedef]
struct C.CREDENTIALW {
mut:
	Flags              u32
	Type               u32
	TargetName         &u16 = unsafe { nil }
	Comment            &u16 = unsafe { nil }
	LastWritten        u64 // FILETIME; never read or written here
	CredentialBlobSize u32
	CredentialBlob     &u8 = unsafe { nil }
	Persist            u32
	AttributeCount     u32
	Attributes         voidptr
	TargetAlias        &u16 = unsafe { nil }
	UserName           &u16 = unsafe { nil }
}

fn C.CredWriteW(credential &C.CREDENTIALW, flags u32) int
fn C.CredReadW(target_name &u16, typ u32, flags u32, credential &&C.CREDENTIALW) int
fn C.CredDeleteW(target_name &u16, typ u32, flags u32) int
fn C.CredFree(buffer voidptr)
fn C.GetLastError() u32

const cred_type_generic = u32(1)
const cred_persist_local_machine = u32(2)
const cred_error_not_found = u32(1168)
const cred_max_blob_size = 2560

struct WindowsCredentialBackend {}

fn windows_credential_target(account string) string {
	return '${secret_service_name}/${account}'
}

fn (mut b WindowsCredentialBackend) get(account string) !string {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	target := windows_credential_target(account).to_wide()
	mut stored := &C.CREDENTIALW(unsafe { nil })
	if C.CredReadW(target, cred_type_generic, 0, &stored) == 0 {
		code := C.GetLastError()
		if code == cred_error_not_found {
			return ''
		}
		return keychain_error('Credential Manager read failed (error ${code})')
	}
	size := int(stored.CredentialBlobSize)
	mut buffer := []u8{len: size}
	if size > 0 {
		unsafe { vmemcpy(buffer.data, stored.CredentialBlob, size) }
	}
	C.CredFree(stored)
	return buffer.bytestr()
}

fn (mut b WindowsCredentialBackend) set(account string, secret string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	if secret.len == 0 || secret.len > cred_max_blob_size {
		return error('key is too long for Windows Credential Manager (max ${cred_max_blob_size} bytes)')
	}
	target := windows_credential_target(account).to_wide()
	user := secret_service_name.to_wide()
	bytes := secret.bytes()
	mut credential := C.CREDENTIALW{}
	credential.Type = cred_type_generic
	credential.TargetName = target
	credential.UserName = user
	credential.CredentialBlobSize = u32(bytes.len)
	credential.CredentialBlob = bytes.data
	credential.Persist = cred_persist_local_machine
	if C.CredWriteW(&credential, 0) == 0 {
		return keychain_error('Credential Manager write failed (error ${C.GetLastError()})')
	}
}

fn (mut b WindowsCredentialBackend) delete(account string) ! {
	if !secret_account_is_safe(account) {
		return error('invalid secret account')
	}
	target := windows_credential_target(account).to_wide()
	if C.CredDeleteW(target, cred_type_generic, 0) == 0 {
		code := C.GetLastError()
		if code != cred_error_not_found {
			return keychain_error('Credential Manager delete failed (error ${code})')
		}
	}
}

fn native_secret_backend() SecretBackend {
	$if test {
		if os.getenv('VEASEL_NATIVE_KEYCHAIN_TEST') != '1' {
			return UnavailableSecretBackend{
				reason: 'native keychain is disabled under v test'
			}
		}
	}
	return WindowsCredentialBackend{}
}
