# iOS IPA Resign Scripts

These scripts are related to Mobile Publisher's Binary Handoff distribution scope.

They are used for resigning iOS IPA files with new signing identities, bundle identifiers, and provisioning profiles. These tools support the main app and multiple extensions based on the app type.

## Prerequisites

- macOS with Xcode command line tools
- Valid iOS Developer signing identity in keychain
- Provisioning profiles for your bundle identifiers

## Scripts

- [Salesforce App Resign Script](SalesforceApp/README.md) - For Salesforce based Publisher Apps 
- [Experience Cloud Resign Script](ExperienceCloud/README.md) - For Experience Cloud based Publisher Apps

## Usage

Each script creates a timestamped output directory with the resigned IPA. Run with `-h` flag for detailed usage information. 