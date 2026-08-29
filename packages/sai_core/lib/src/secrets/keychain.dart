import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'secret_store.dart';

/// The Keychain `service` every stable sai credential is filed under.
/// Both binaries of a flavor use the same one, so a key entered in the TUI
/// is the key the app reads; the dev flavor has its own service
/// (`SaiIdentity.keychainService`, ADR 0019) and never sees stable's.
const saiKeychainService = 'me.slominski.sai';

/// Secrets in the macOS file-based Keychain, one generic-password item
/// per account, through `Security.framework` (ADR 0008). Never the
/// `security` command: an item written by it trusts that tool, and any
/// process that runs it reads the item without a prompt.
///
/// Writes update in place — an item's access list and partition list
/// belong to the item, and delete-and-recreate would reset them.
///
/// By default items go to the user's default (login) keychain. A store
/// made with [KeychainSecretStore.file] confines every operation to one
/// keychain file — tests use a throwaway one under a temp directory, so
/// they never touch the login keychain and never prompt.
final class KeychainSecretStore implements SecretStore {
  /// The default keychain. Throws [UnsupportedError] off macOS.
  KeychainSecretStore({this.service = saiKeychainService})
    : _keychain = null,
      _sec = _Security.instance;

  /// A store confined to the keychain file at [path], created with
  /// [password] when it does not exist yet. Throws [UnsupportedError] off
  /// macOS and [SecretStoreException] when the file cannot be opened.
  KeychainSecretStore.file(
    String path, {
    required String password,
    this.service = saiKeychainService,
  }) : _sec = _Security.instance {
    _keychain = _sec.openOrCreate(path, password);
  }

  final String service;
  final _Security _sec;
  Pointer<Void>? _keychain;
  bool _destroyed = false;

  Pointer<Void>? get _where {
    if (_destroyed) {
      throw StateError('this keychain store was destroyed');
    }
    return _keychain;
  }

  @override
  String? read(String account) {
    checkAccount(account);
    return _sec.copy(service, account, _where, wantData: true);
  }

  @override
  bool has(String account) {
    checkAccount(account);
    return _sec.copy(service, account, _where, wantData: false) != null;
  }

  @override
  void write(String account, String value) {
    checkAccount(account);
    checkValue(value);
    _sec.write(service, account, value, _where);
  }

  @override
  bool delete(String account) {
    checkAccount(account);
    return _sec.delete(service, account, _where);
  }

  /// For a [KeychainSecretStore.file] store: removes the keychain file.
  /// The store is unusable afterwards — every operation throws
  /// [StateError] rather than silently falling back to the default
  /// keychain. A no-op for the default keychain.
  void destroy() {
    final keychain = _keychain;
    if (keychain == null) return;
    _keychain = null;
    _destroyed = true;
    _sec.destroyKeychain(keychain);
  }
}

// ---------------------------------------------------------------------------
// Bindings. Every CF object made here is released on the way out; secret
// bytes in native memory are zeroed before they are freed.

typedef _CFRef = Pointer<Void>;

typedef _CFStringCreateWithCStringC = _CFRef Function(
  _CFRef,
  Pointer<Utf8>,
  Uint32,
);
typedef _CFStringCreateWithCStringD = _CFRef Function(
  _CFRef,
  Pointer<Utf8>,
  int,
);
typedef _CFDataCreateC = _CFRef Function(_CFRef, Pointer<Uint8>, IntPtr);
typedef _CFDataCreateD = _CFRef Function(_CFRef, Pointer<Uint8>, int);
typedef _CFDataGetBytePtrC = Pointer<Uint8> Function(_CFRef);
typedef _CFDataGetLengthC = IntPtr Function(_CFRef);
typedef _CFDataGetLengthD = int Function(_CFRef);
typedef _CFGetTypeIDC = UintPtr Function(_CFRef);
typedef _CFGetTypeIDD = int Function(_CFRef);
typedef _CFDataGetTypeIDC = UintPtr Function();
typedef _CFDataGetTypeIDD = int Function();
typedef _CFDictionaryCreateC = _CFRef Function(
  _CFRef,
  Pointer<_CFRef>,
  Pointer<_CFRef>,
  IntPtr,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CFDictionaryCreateD = _CFRef Function(
  _CFRef,
  Pointer<_CFRef>,
  Pointer<_CFRef>,
  int,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CFArrayCreateC = _CFRef Function(
  _CFRef,
  Pointer<_CFRef>,
  IntPtr,
  Pointer<Void>,
);
typedef _CFArrayCreateD = _CFRef Function(
  _CFRef,
  Pointer<_CFRef>,
  int,
  Pointer<Void>,
);
typedef _CFReleaseC = Void Function(_CFRef);
typedef _CFReleaseD = void Function(_CFRef);

typedef _SecItemAddC = Int32 Function(_CFRef, Pointer<_CFRef>);
typedef _SecItemAddD = int Function(_CFRef, Pointer<_CFRef>);
typedef _SecItemCopyMatchingC = Int32 Function(_CFRef, Pointer<_CFRef>);
typedef _SecItemCopyMatchingD = int Function(_CFRef, Pointer<_CFRef>);
typedef _SecItemUpdateC = Int32 Function(_CFRef, _CFRef);
typedef _SecItemUpdateD = int Function(_CFRef, _CFRef);
typedef _SecItemDeleteC = Int32 Function(_CFRef);
typedef _SecItemDeleteD = int Function(_CFRef);
typedef _SecKeychainCreateC = Int32 Function(
  Pointer<Utf8>,
  Uint32,
  Pointer<Utf8>,
  Uint8,
  _CFRef,
  Pointer<_CFRef>,
);
typedef _SecKeychainCreateD = int Function(
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
  int,
  _CFRef,
  Pointer<_CFRef>,
);
typedef _SecKeychainOpenC = Int32 Function(Pointer<Utf8>, Pointer<_CFRef>);
typedef _SecKeychainOpenD = int Function(Pointer<Utf8>, Pointer<_CFRef>);
typedef _SecKeychainUnlockC = Int32 Function(
  _CFRef,
  Uint32,
  Pointer<Utf8>,
  Uint8,
);
typedef _SecKeychainUnlockD = int Function(_CFRef, int, Pointer<Utf8>, int);
typedef _SecKeychainDeleteC = Int32 Function(_CFRef);
typedef _SecKeychainDeleteD = int Function(_CFRef);

const _kCFStringEncodingUTF8 = 0x08000100;

const _errSecSuccess = 0;
const _errSecUserCanceled = -128;
const _errSecAuthFailed = -25293;
const _errSecDuplicateItem = -25299;
const _errSecItemNotFound = -25300;
const _errSecInteractionNotAllowed = -25308;
const _errSecDecode = -26275;

String _describe(int status) => switch (status) {
  _errSecUserCanceled => 'the user cancelled the keychain prompt',
  _errSecAuthFailed => 'the keychain refused access',
  _errSecDuplicateItem => 'the keychain already holds that item',
  _errSecItemNotFound => 'no such keychain item',
  _errSecInteractionNotAllowed => 'the keychain needs a prompt it cannot show',
  _errSecDecode => 'the keychain item could not be decoded',
  _ => 'the keychain returned an error',
};

final class _Security {
  _Security._() {
    if (!Platform.isMacOS) {
      throw UnsupportedError('the Keychain secret store is macOS only');
    }
    final cf = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
    );
    final sec = DynamicLibrary.open(
      '/System/Library/Frameworks/Security.framework/Security',
    );
    cfStringCreate = cf
        .lookupFunction<
          _CFStringCreateWithCStringC,
          _CFStringCreateWithCStringD
        >('CFStringCreateWithCString');
    cfDataCreate = cf.lookupFunction<_CFDataCreateC, _CFDataCreateD>(
      'CFDataCreate',
    );
    cfDataGetBytePtr = cf
        .lookupFunction<_CFDataGetBytePtrC, _CFDataGetBytePtrC>(
          'CFDataGetBytePtr',
        );
    cfDataGetLength = cf.lookupFunction<_CFDataGetLengthC, _CFDataGetLengthD>(
      'CFDataGetLength',
    );
    cfGetTypeID = cf.lookupFunction<_CFGetTypeIDC, _CFGetTypeIDD>(
      'CFGetTypeID',
    );
    cfDataGetTypeID = cf.lookupFunction<_CFDataGetTypeIDC, _CFDataGetTypeIDD>(
      'CFDataGetTypeID',
    );
    cfDictionaryCreate = cf
        .lookupFunction<_CFDictionaryCreateC, _CFDictionaryCreateD>(
          'CFDictionaryCreate',
        );
    cfArrayCreate = cf.lookupFunction<_CFArrayCreateC, _CFArrayCreateD>(
      'CFArrayCreate',
    );
    cfRelease = cf.lookupFunction<_CFReleaseC, _CFReleaseD>('CFRelease');
    keyCallBacks = cf.lookup<Void>('kCFTypeDictionaryKeyCallBacks');
    valueCallBacks = cf.lookup<Void>('kCFTypeDictionaryValueCallBacks');
    arrayCallBacks = cf.lookup<Void>('kCFTypeArrayCallBacks');
    kCFBooleanTrue = cf.lookup<_CFRef>('kCFBooleanTrue').value;

    secItemAdd = sec.lookupFunction<_SecItemAddC, _SecItemAddD>('SecItemAdd');
    secItemCopyMatching = sec
        .lookupFunction<_SecItemCopyMatchingC, _SecItemCopyMatchingD>(
          'SecItemCopyMatching',
        );
    secItemUpdate = sec.lookupFunction<_SecItemUpdateC, _SecItemUpdateD>(
      'SecItemUpdate',
    );
    secItemDelete = sec.lookupFunction<_SecItemDeleteC, _SecItemDeleteD>(
      'SecItemDelete',
    );
    secKeychainCreate = sec
        .lookupFunction<_SecKeychainCreateC, _SecKeychainCreateD>(
          'SecKeychainCreate',
        );
    secKeychainOpen = sec.lookupFunction<_SecKeychainOpenC, _SecKeychainOpenD>(
      'SecKeychainOpen',
    );
    secKeychainUnlock = sec
        .lookupFunction<_SecKeychainUnlockC, _SecKeychainUnlockD>(
          'SecKeychainUnlock',
        );
    secKeychainDelete = sec
        .lookupFunction<_SecKeychainDeleteC, _SecKeychainDeleteD>(
          'SecKeychainDelete',
        );
    _CFRef global(String name) => sec.lookup<_CFRef>(name).value;
    kSecClass = global('kSecClass');
    kSecClassGenericPassword = global('kSecClassGenericPassword');
    kSecAttrService = global('kSecAttrService');
    kSecAttrAccount = global('kSecAttrAccount');
    kSecValueData = global('kSecValueData');
    kSecReturnData = global('kSecReturnData');
    kSecReturnAttributes = global('kSecReturnAttributes');
    kSecMatchLimit = global('kSecMatchLimit');
    kSecMatchLimitOne = global('kSecMatchLimitOne');
    kSecUseKeychain = global('kSecUseKeychain');
    kSecMatchSearchList = global('kSecMatchSearchList');
  }

  static final instance = _Security._();

  late final _CFStringCreateWithCStringD cfStringCreate;
  late final _CFDataCreateD cfDataCreate;
  late final _CFDataGetBytePtrC cfDataGetBytePtr;
  late final _CFDataGetLengthD cfDataGetLength;
  late final _CFGetTypeIDD cfGetTypeID;
  late final _CFDataGetTypeIDD cfDataGetTypeID;
  late final _CFDictionaryCreateD cfDictionaryCreate;
  late final _CFArrayCreateD cfArrayCreate;
  late final _CFReleaseD cfRelease;
  late final Pointer<Void> keyCallBacks;
  late final Pointer<Void> valueCallBacks;
  late final Pointer<Void> arrayCallBacks;
  late final _CFRef kCFBooleanTrue;

  late final _SecItemAddD secItemAdd;
  late final _SecItemCopyMatchingD secItemCopyMatching;
  late final _SecItemUpdateD secItemUpdate;
  late final _SecItemDeleteD secItemDelete;
  late final _SecKeychainCreateD secKeychainCreate;
  late final _SecKeychainOpenD secKeychainOpen;
  late final _SecKeychainUnlockD secKeychainUnlock;
  late final _SecKeychainDeleteD secKeychainDelete;
  late final _CFRef kSecClass;
  late final _CFRef kSecClassGenericPassword;
  late final _CFRef kSecAttrService;
  late final _CFRef kSecAttrAccount;
  late final _CFRef kSecValueData;
  late final _CFRef kSecReturnData;
  late final _CFRef kSecReturnAttributes;
  late final _CFRef kSecMatchLimit;
  late final _CFRef kSecMatchLimitOne;
  late final _CFRef kSecUseKeychain;
  late final _CFRef kSecMatchSearchList;

  /// A CFString for [text]; the caller releases it.
  _CFRef string(String text) {
    final c = text.toNativeUtf8();
    try {
      return cfStringCreate(nullptr, c, _kCFStringEncodingUTF8);
    } finally {
      calloc.free(c);
    }
  }

  /// A CFData for [bytes]; the caller releases it. The native copy of the
  /// bytes is zeroed before it is freed.
  _CFRef data(List<int> bytes) {
    final buf = calloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      return cfDataCreate(nullptr, buf, bytes.length);
    } finally {
      buf.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(buf);
    }
  }

  /// A CFDictionary over [entries]; the keys are borrowed (globals) and
  /// the values are released once the dictionary holds them.
  _CFRef dictionary(Map<_CFRef, _CFRef> entries) {
    final n = entries.length;
    final keys = calloc<_CFRef>(n);
    final values = calloc<_CFRef>(n);
    try {
      var i = 0;
      for (final e in entries.entries) {
        keys[i] = e.key;
        values[i] = e.value;
        i++;
      }
      return cfDictionaryCreate(
        nullptr,
        keys,
        values,
        n,
        keyCallBacks,
        valueCallBacks,
      );
    } finally {
      calloc.free(keys);
      calloc.free(values);
    }
  }

  _CFRef array(List<_CFRef> items) {
    final values = calloc<_CFRef>(items.length);
    try {
      for (var i = 0; i < items.length; i++) {
        values[i] = items[i];
      }
      return cfArrayCreate(nullptr, values, items.length, arrayCallBacks);
    } finally {
      calloc.free(values);
    }
  }

  /// The class, service and account that address one item, plus the
  /// search-list or use-keychain entry confining it to [keychain].
  Map<_CFRef, _CFRef> address(
    String service,
    String account,
    _CFRef? keychain, {
    required bool forAdd,
  }) => {
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: string(service),
    kSecAttrAccount: string(account),
    if (keychain != null)
      if (forAdd)
        kSecUseKeychain: keychain
      else
        kSecMatchSearchList: array([keychain]),
  };

  /// Releases the values a query dictionary was built from. Globals
  /// (`kSec*`, `kCFBooleanTrue`) and the keychain ref are not released.
  void releaseValues(Map<_CFRef, _CFRef> entries, _CFRef? keychain) {
    for (final v in entries.values) {
      if (v == kCFBooleanTrue || v == kSecClassGenericPassword) continue;
      if (v == kSecMatchLimitOne || v == keychain) continue;
      cfRelease(v);
    }
  }

  String? copy(
    String service,
    String account,
    _CFRef? keychain, {
    required bool wantData,
  }) {
    final entries = address(service, account, keychain, forAdd: false)
      ..[kSecMatchLimit] = kSecMatchLimitOne
      ..[wantData ? kSecReturnData : kSecReturnAttributes] = kCFBooleanTrue;
    final query = dictionary(entries);
    final out = calloc<_CFRef>();
    try {
      final status = secItemCopyMatching(query, out);
      if (status == _errSecItemNotFound) return null;
      _check(status);
      final result = out.value;
      try {
        if (!wantData) return '';
        if (cfGetTypeID(result) != cfDataGetTypeID()) {
          throw const SecretStoreException('the keychain item is not data');
        }
        final length = cfDataGetLength(result);
        // Copied out of native memory before the release below; decoded
        // with a fixed message so a non-UTF-8 item cannot leak its bytes.
        final bytes = Uint8List.fromList(
          cfDataGetBytePtr(result).asTypedList(length),
        );
        try {
          return utf8.decode(bytes);
        } on FormatException {
          throw const SecretStoreException('the keychain item is not UTF-8');
        }
      } finally {
        cfRelease(result);
      }
    } finally {
      calloc.free(out);
      releaseValues(entries, keychain);
      cfRelease(query);
    }
  }

  void write(String service, String account, String value, _CFRef? keychain) {
    final bytes = utf8.encode(value);
    // Update in place first; only an absent item is added.
    final where = address(service, account, keychain, forAdd: false);
    final query = dictionary(where);
    final change = {kSecValueData: data(bytes)};
    final attrs = dictionary(change);
    int status;
    try {
      status = secItemUpdate(query, attrs);
    } finally {
      releaseValues(change, keychain);
      cfRelease(attrs);
      releaseValues(where, keychain);
      cfRelease(query);
    }
    if (status != _errSecItemNotFound) {
      _check(status);
      return;
    }
    final entries = address(service, account, keychain, forAdd: true)
      ..[kSecValueData] = data(bytes);
    final item = dictionary(entries);
    try {
      _check(secItemAdd(item, nullptr));
    } finally {
      releaseValues(entries, keychain);
      cfRelease(item);
    }
  }

  bool delete(String service, String account, _CFRef? keychain) {
    final entries = address(service, account, keychain, forAdd: false);
    final query = dictionary(entries);
    try {
      final status = secItemDelete(query);
      if (status == _errSecItemNotFound) return false;
      _check(status);
      return true;
    } finally {
      releaseValues(entries, keychain);
      cfRelease(query);
    }
  }

  _CFRef openOrCreate(String path, String password) {
    final cPath = path.toNativeUtf8();
    final cPass = password.toNativeUtf8();
    final out = calloc<_CFRef>();
    try {
      final passLen = utf8.encode(password).length;
      int status;
      if (File(path).existsSync()) {
        status = secKeychainOpen(cPath, out);
        _check(status);
        status = secKeychainUnlock(out.value, passLen, cPass, 1);
        if (status != _errSecSuccess) cfRelease(out.value);
      } else {
        status = secKeychainCreate(cPath, passLen, cPass, 0, nullptr, out);
      }
      _check(status);
      return out.value;
    } finally {
      calloc.free(cPath);
      calloc.free(cPass);
      calloc.free(out);
    }
  }

  void destroyKeychain(_CFRef keychain) {
    try {
      _check(secKeychainDelete(keychain));
    } finally {
      cfRelease(keychain);
    }
  }

  void _check(int status) {
    if (status == _errSecSuccess) return;
    throw SecretStoreException(_describe(status), status: status);
  }
}
