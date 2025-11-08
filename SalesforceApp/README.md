# Salesforce App IPA Resign Script

A shell script for resigning iOS IPA files with new signing identities, bundle identifiers, and provisioning profiles. This tool supports the main app and multiple extensions including Notification Service Extension, Widget Extension, and Call Directory Extension.

## Features

This script automates the process of resigning iOS applications, allowing you to:

- Change the bundle identifier
- Resign with a different signing identity
- Update provisioning profiles for the main app and all extensions
- Automatically configure App Groups
- Handle multiple app extensions seamlessly

## Prerequisites

- macOS with Xcode command line tools
- Valid iOS signing identity in keychain
- Provisioning profiles for main app and all extensions with matching App Groups

## Script Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--input-ipa-full-path` | Path to input IPA file | `/Users/you/app.ipa` |
| `--output-dir` | Output directory | `/Users/you/output/` |
| `--signing-identity` | Signing identity from keychain | `iPhone Developer: John Doe (ABC123)` |
| `--team-id` | Apple team ID | `ABC123DEF4` |
| `--bundle-identifier` | Your bundle identifier | `com.example.myapp` |
| `--mobileprovision` | Main app provisioning profile | `/Users/you/app.mobileprovision` |
| `--notification-extension-mobileprovision` | Notification extension profile | `/Users/you/notification.mobileprovision` |
| `--widget-extension-mobileprovision` | Widget extension profile | `/Users/you/widget.mobileprovision` |
| `--call-directory-extension-mobileprovision` | Call directory extension profile | `/Users/you/calldirectory.mobileprovision` |
| `--bundle-version` | Bundle version (optional) | `1.2.3` |

**Note**: Extension bundle IDs and app group (`group.{BUNDLE_IDENTIFIER}`) are auto-generated:
- Notification: `{BUNDLE_IDENTIFIER}.NotificationServiceExtension`
- Widget: `{BUNDLE_IDENTIFIER}.WidgetExtension`
- Call Directory: `{BUNDLE_IDENTIFIER}.SAppCallDirectoryExtension`

## Example

```bash
./resign_salesforceapp.sh \
  --input-ipa-full-path "/Users/you/app.ipa" \
  --output-dir "/Users/you/output/" \
  --signing-identity "iPhone Developer: John Doe (ABC123)" \
  --team-id "ABC123DEF4" \
  --bundle-identifier "com.example.myapp" \
  --mobileprovision "/Users/you/app.mobileprovision" \
  --notification-extension-mobileprovision "/Users/you/notification.mobileprovision" \
  --widget-extension-mobileprovision "/Users/you/widget.mobileprovision" \
  --call-directory-extension-mobileprovision "/Users/you/calldirectory.mobileprovision"
```

Run `./resign_salesforceapp.sh -h` for help.