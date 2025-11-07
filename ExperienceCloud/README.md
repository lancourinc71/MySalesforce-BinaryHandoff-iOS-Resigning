# Experience Cloud IPA Resign Script

A shell script for resigning iOS IPA files with new signing identities, bundle identifiers, and provisioning profiles. This tool supports the main app and a Notification Service Extension.

## Features

This script automates the process of resigning iOS applications, allowing you to:

- Change the bundle identifier
- Resign with a different signing identity
- Update provisioning profiles for the main app and notification extension
- Automatically configure App Groups
- Handle notification service extensions seamlessly

## Prerequisites

- macOS with Xcode command line tools
- Valid iOS signing identity in keychain
- Provisioning profiles for main app and notification extension with matching App Groups

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--input-ipa-paths` | Path to input IPA file | `/Users/you/app.ipa` |
| `--output-dir` | Output directory | `/Users/you/output/` |
| `--signing-identity` | Signing identity from keychain | `iPhone Developer: John Doe (ABC123)` |
| `--team-id` | Apple team ID | `ABC123DEF4` |
| `--bundle-identifier` | Your bundle identifier | `com.example.myapp` |
| `--mobileprovision` | Main app provisioning profile | `/Users/you/app.mobileprovision` |
| `--extension-mobileprovision` | Extension provisioning profile | `/Users/you/extension.mobileprovision` |
| `--bundle-version` | Bundle version (optional) | `1.2.3` |

**Note**: Extension bundle ID (`{BUNDLE_IDENTIFIER}.NotificationServiceExtension`) and app group (`group.{BUNDLE_IDENTIFIER}`) are auto-generated.

## Example

```bash
./resign_experiencecloud.sh \
  --input-ipa-paths "/Users/you/app.ipa" \
  --output-dir "/Users/you/output/" \
  --signing-identity "iPhone Developer: John Doe (ABC123)" \
  --team-id "ABC123DEF4" \
  --bundle-identifier "com.example.myapp" \
  --mobileprovision "/Users/you/app.mobileprovision" \
  --extension-mobileprovision "/Users/you/extension.mobileprovision"
```

Run `./resign_experiencecloud.sh -h` for help.