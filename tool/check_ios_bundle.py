#!/usr/bin/env python3
"""Reports what App Store Connect would refuse in a built Runner.app.

Apple only answers after a signed upload, and each try costs a full build, so the
same checks run on the unsigned build too:

  check_ios_bundle.py build/ios/iphoneos/Runner.app
  check_ios_bundle.py Payload/Runner.app --signed

Needs nm and codesign, so it only runs on macOS.
"""
import plistlib
import subprocess
import sys
from pathlib import Path

# A class the binary references, and the Info.plist key Apple then requires
PURPOSE = {
    'AVAudioRecorder': 'NSMicrophoneUsageDescription',
    'AVCaptureDevice': 'NSCameraUsageDescription',
    'ATTrackingManager': 'NSUserTrackingUsageDescription',
    'CBCentralManager': 'NSBluetoothAlwaysUsageDescription',
    'CBPeripheralManager': 'NSBluetoothAlwaysUsageDescription',
    'CLLocationManager': 'NSLocationWhenInUseUsageDescription',
    'CMMotionActivityManager': 'NSMotionUsageDescription',
    'CMPedometer': 'NSMotionUsageDescription',
    'CNContactStore': 'NSContactsUsageDescription',
    'EKEventStore': 'NSCalendarsUsageDescription',
    'HKHealthStore': 'NSHealthShareUsageDescription',
    'HMHomeManager': 'NSHomeKitUsageDescription',
    'INPreferences': 'NSSiriUsageDescription',
    'LAContext': 'NSFaceIDUsageDescription',
    'MPMediaLibrary': 'NSAppleMusicUsageDescription',
    'MPMediaPickerController': 'NSAppleMusicUsageDescription',
    'MPMediaQuery': 'NSAppleMusicUsageDescription',
    'NFCNDEFReaderSession': 'NFCReaderUsageDescription',
    'NFCTagReaderSession': 'NFCReaderUsageDescription',
    'PHAsset': 'NSPhotoLibraryUsageDescription',
    'PHPhotoLibrary': 'NSPhotoLibraryUsageDescription',
    'SFSpeechRecognizer': 'NSSpeechRecognitionUsageDescription',
}
PURPOSE_FUNCTIONS = {'_UIImageWriteToSavedPhotosAlbum': 'NSPhotoLibraryAddUsageDescription'}

# Required-reason APIs by privacy manifest category
TIMESTAMP = 'NSPrivacyAccessedAPICategoryFileTimestamp'
BOOT_TIME = 'NSPrivacyAccessedAPICategorySystemBootTime'
DISK_SPACE = 'NSPrivacyAccessedAPICategoryDiskSpace'
USER_DEFAULTS = 'NSPrivacyAccessedAPICategoryUserDefaults'
REASONS = {
    '_stat': TIMESTAMP,
    '_stat$INODE64': TIMESTAMP,
    '_lstat': TIMESTAMP,
    '_lstat$INODE64': TIMESTAMP,
    '_fstat': TIMESTAMP,
    '_fstat$INODE64': TIMESTAMP,
    '_fstatat': TIMESTAMP,
    '_fstatat$INODE64': TIMESTAMP,
    '_getattrlist': TIMESTAMP,
    '_fgetattrlist': TIMESTAMP,
    '_getattrlistat': TIMESTAMP,
    '_getattrlistbulk': TIMESTAMP,
    '_NSFileCreationDate': TIMESTAMP,
    '_NSFileModificationDate': TIMESTAMP,
    '_NSURLContentModificationDateKey': TIMESTAMP,
    '_NSURLCreationDateKey': TIMESTAMP,
    '_mach_absolute_time': BOOT_TIME,
    '_statfs': DISK_SPACE,
    '_statfs$INODE64': DISK_SPACE,
    '_fstatfs': DISK_SPACE,
    '_fstatfs$INODE64': DISK_SPACE,
    '_statvfs': DISK_SPACE,
    '_fstatvfs': DISK_SPACE,
    '_NSFileSystemFreeSize': DISK_SPACE,
    '_NSFileSystemSize': DISK_SPACE,
    '_NSURLVolumeAvailableCapacityKey': DISK_SPACE,
    '_NSURLVolumeTotalCapacityKey': DISK_SPACE,
    '_OBJC_CLASS_$_NSUserDefaults': USER_DEFAULTS,
}

TUNNEL_ENTITLEMENT = 'com.apple.developer.networking.networkextension'
GROUP_ENTITLEMENT = 'com.apple.security.application-groups'


def references(binary):
    result = subprocess.run(['nm', '-u', str(binary)], capture_output=True, text=True, check=True)
    return {line.strip() for line in result.stdout.splitlines()}


def info(bundle):
    return plistlib.loads((bundle / 'Info.plist').read_bytes())


def declared(bundle):
    """Categories the bundle's own manifests declare, including its resource bundles."""
    categories = set()
    for manifest in bundle.rglob('PrivacyInfo.xcprivacy'):
        data = plistlib.loads(manifest.read_bytes())
        for entry in data.get('NSPrivacyAccessedAPITypes', []):
            categories.add(entry['NSPrivacyAccessedAPIType'])
    return categories


def binary_of(bundle):
    return bundle / info(bundle)['CFBundleExecutable']


def check_purposes(app, binaries):
    problems = []
    keys = info(app)
    for binary in binaries:
        symbols = references(binary)
        wanted = dict(PURPOSE_FUNCTIONS)
        wanted.update({f'_OBJC_CLASS_$_{name}': key for name, key in PURPOSE.items()})
        for symbol, key in wanted.items():
            if symbol in symbols and key not in keys:
                problems.append(f'{binary.name} references {symbol} but Info.plist has no {key}')
    return problems


def check_reasons(owner, binaries):
    """The owner's manifest covers everything in it; a framework may also declare its own."""
    problems = []
    covered = declared(owner)
    for binary in binaries:
        symbols = references(binary)
        wanted = {category for symbol, category in REASONS.items() if symbol in symbols}
        own = declared(binary.parent) if binary.parent != owner else set()
        print(f'{binary.relative_to(owner.parent)}: {sorted(wanted) or "-"}; own manifest {sorted(own) or "-"}')
        for category in sorted(wanted - covered - own):
            problems.append(f'{binary.name} uses {category}, declared nowhere')
    return problems


def check_signature(app, tunnel):
    problems = []
    if info(app)['CFBundleVersion'] != info(tunnel)['CFBundleVersion']:
        problems.append('the app and the tunnel have different CFBundleVersion')
    if info(app)['CFBundleShortVersionString'] != info(tunnel)['CFBundleShortVersionString']:
        problems.append('the app and the tunnel have different CFBundleShortVersionString')
    for bundle in (app, tunnel):
        result = subprocess.run(['codesign', '-d', '--xml', '--entitlements', '-', str(bundle)],
                                capture_output=True, check=True)
        entitlements = plistlib.loads(result.stdout)
        for key in (TUNNEL_ENTITLEMENT, GROUP_ENTITLEMENT):
            if not entitlements.get(key):
                problems.append(f'{bundle.name} was signed without {key}')
    return problems


def main():
    app = Path(sys.argv[1])
    tunnel = next((app / 'PlugIns').glob('*.appex'))

    problems = []
    if (tunnel / 'Frameworks').exists():
        problems.append(f'{tunnel.name} embeds a Frameworks folder')

    frameworks = sorted((app / 'Frameworks').glob('*.framework'))
    binaries = [binary_of(app)] + [binary_of(framework) for framework in frameworks]
    problems += check_purposes(app, binaries + [binary_of(tunnel)])
    problems += check_reasons(app, binaries)
    problems += check_reasons(tunnel, [binary_of(tunnel)])
    if '--signed' in sys.argv:
        problems += check_signature(app, tunnel)

    for problem in problems:
        print(f'::error::{problem}')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
