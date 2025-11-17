#!/bin/bash
# Global verbose flag
VERBOSE=false

#######################################
# Log function with verbose support
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR, DEBUG)
#   $2 - Message

#######################################
log() {
    local level="$1"
    shift
    local message="$*"
    case "$level" in
        "ERROR")
            echo "ERROR: $message" >&2
            ;;
        "WARN")
            echo "WARN: $message" >&2
            ;;
        "INFO")
            echo "INFO: $message"
            ;;
        "DEBUG")
            if [[ "$VERBOSE" == true ]]; then
                echo "DEBUG: $message" >&2
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
}

#######################################
# Check if SIGNING_IDENTITY exists in keychain
# Globals:
#   SIGNING_IDENTITY
# Arguments:
#   None
# Returns:
#   0 if identity exists, 1 if not found

#######################################
check_keychain() {
    log "DEBUG" "Starting check_keychain function"
    # Validate required variables
    if [[ -z "${SIGNING_IDENTITY}" ]]; then
        log "ERROR" "SIGNING_IDENTITY variable is not set"
        return 1
    fi
    log "INFO" "Checking if signing identity exists in keychain: ${SIGNING_IDENTITY}"
    # Use security find-identity to list all identities and check if our identity exists
    local found_identity=false
    # Get all identities and check if our identity is in the list
    while IFS= read -r line; do
        if [[ "$line" == *"$SIGNING_IDENTITY"* ]]; then
            found_identity=true
            break
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null)
    if [[ "$found_identity" == true ]]; then
        log "INFO" "Signing identity found in keychain: ${SIGNING_IDENTITY}"
        return 0
    else
        log "ERROR" "Signing identity not found in keychain: ${SIGNING_IDENTITY}"
        log "ERROR" "Available identities:"
        security find-identity -v -p codesigning 2>/dev/null | while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+\"(.+)\" ]]; then
                log "ERROR" "  ${BASH_REMATCH[1]}"
            fi
        done
        return 1
    fi
}

#######################################
# Validate all required dependencies and tools
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 if all dependencies are available, 1 if any are missing
#######################################
validate_dependencies() {
    log "INFO" "*** Validating Dependencies ***"
    
    local missing_deps=()
    local missing_install_commands=()
    
    # Check for required command line tools
    local required_tools=(
        "unzip:unzip"
        "zip:zip"
        "codesign:codesign"
        "security:security"
        "grep:grep"
        "sed:sed"
        "mktemp:mktemp"
        "basename:basename"
        "dirname:dirname"
        "find:find"
        "cp:cp"
        "rm:rm"
        "mkdir:mkdir"
        "chmod:chmod"
    )
    
    # Check for PlistBuddy specifically
    if ! command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        missing_deps+=("PlistBuddy")
        missing_install_commands+=("Install Xcode Command Line Tools: xcode-select --install")
    fi
    
    # Check other required tools
    for tool_info in "${required_tools[@]}"; do
        local tool_name="${tool_info%%:*}"
        local tool_command="${tool_info##*:}"
        
        if ! command -v "${tool_command}" >/dev/null 2>&1; then
            missing_deps+=("${tool_name}")
            if [[ "${tool_name}" == "codesign" || "${tool_name}" == "security" ]]; then
                missing_install_commands+=("Install Xcode Command Line Tools: xcode-select --install")
            fi
        fi
    done
    
    # Check for Xcode Command Line Tools
    if ! xcode-select --print-path >/dev/null 2>&1; then
        missing_deps+=("Xcode Command Line Tools")
        missing_install_commands+=("Install Xcode Command Line Tools: xcode-select --install")
    fi
    
    # Check for signing identities in keychain
    if ! security find-identity -v -p codesigning >/dev/null 2>&1; then
        log "WARN" "No code signing identities found in keychain"
        log "INFO" "You may need to:"
        log "INFO" "  1. Enroll in Apple Developer Program (\$99/year)"
        log "INFO" "  2. Download certificates from Apple Developer Portal"
        log "INFO" "  3. Import certificates into macOS Keychain"
        log "INFO" "  4. Run: security find-identity -v -p codesigning"
    fi
    
    # Report results
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies:"
        for dep in "${missing_deps[@]}"; do
            log "ERROR" "  - ${dep}"
        done
        
        log "ERROR" ""
        log "ERROR" "Installation commands:"
        for cmd in "${missing_install_commands[@]}"; do
            log "ERROR" "  ${cmd}"
        done
        
        log "ERROR" ""
        log "ERROR" "After installation, verify with:"
        log "ERROR" "  xcode-select --print-path"
        log "ERROR" "  /usr/libexec/PlistBuddy -h"
        log "ERROR" "  security find-identity -v -p codesigning"
        
        return 1
    fi
    
    log "SUCCESS" "All required dependencies are available"
    log "INFO" "Xcode Command Line Tools: $(xcode-select --print-path)"
    log "INFO" "PlistBuddy: $(/usr/libexec/PlistBuddy -h 2>&1 | head -1)"
    
    return 0
}

#######################################
# Unzip ipa file to location
# Globals:
#   DESTINATION_FOLDER_PATH FILE, PAYLOAD_PATH, FILE
# Arguments:
#   None

#######################################
function unzip_ipa() {
    log "DEBUG" "Starting unzip_ipa function"
    # Validate required variables
    if [[ -z "${FILE}" ]]; then
        log "ERROR" "FILE variable is not set"
        return 1
    fi
    if [[ -z "${DESTINATION_FOLDER_PATH}" ]]; then
        log "ERROR" "DESTINATION_FOLDER_PATH variable is not set"
        return 1
    fi
    if [[ ! -f "${FILE}" ]]; then
        log "ERROR" "File ${FILE} does not exist"
        return 1
    fi
    log "INFO" "*** Start Unzip IPA ***"
    log "DEBUG" "Source file: ${FILE}"
    log "DEBUG" "Destination: ${DESTINATION_FOLDER_PATH}"
    # Create destination directory
    log "DEBUG" "Creating destination directory: ${DESTINATION_FOLDER_PATH}"
    if ! mkdir -p "${DESTINATION_FOLDER_PATH}"; then
        log "ERROR" "Failed to create directory ${DESTINATION_FOLDER_PATH}"
        return 1
    fi
    log "INFO" "Unzip $(basename "${FILE}") under ${DESTINATION_FOLDER_PATH}"
    # Unzip the file silently
    log "DEBUG" "Running unzip command: unzip -q ${FILE} -d ${DESTINATION_FOLDER_PATH}"
    if ! unzip -q "${FILE}" -d "${DESTINATION_FOLDER_PATH}"; then
        log "ERROR" "Unable to unzip ${FILE} to ${DESTINATION_FOLDER_PATH}"
        return 1
    fi
    # Set APP_NAME as global variable
    APP_NAME=$(basename "${PAYLOAD_PATH}"/*.app)
    log "DEBUG" "Extracted APP_NAME: ${APP_NAME}"
    log "INFO" "*** Unzip IPA Completed ***"
}

#######################################
# Delete app signature from app and app frameworks
# Globals:
#   PAYLOAD_PATH, APP_NAME
# Arguments:
#   None

#######################################
function delete_signature() {
    log "DEBUG" "Starting delete_signature function"
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]]; then
        log "ERROR" "PAYLOAD_PATH or APP_NAME variables are not set"
        return 1
    fi
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    log "DEBUG" "App directory: ${app_dir}"
    if [[ ! -d "${app_dir}" ]]; then
        log "ERROR" "App directory ${app_dir} does not exist"
        return 1
    fi
    log "INFO" "*** Delete App Signature ***"
    # Remove main app signature
    log "DEBUG" "Removing signature from ${app_dir}"
    if [[ -d "${app_dir}/_CodeSignature" ]]; then
        log "DEBUG" "Removing _CodeSignature from main app"
        if ! rm -rf "${app_dir}/_CodeSignature"; then
            log "ERROR" "Unable to remove CodeSignature under ${app_dir}"
            return 1
        fi
        log "DEBUG" "Successfully removed main app signature"
    else
        log "DEBUG" "No _CodeSignature found in main app"
    fi
    # Remove app extension signatures
    local found_appex=false
    shopt -s nullglob
    for dir in "${app_dir}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        found_appex=true
        log "DEBUG" "Removing signature from ${dir}"
        if [[ -d "${dir}/_CodeSignature" ]]; then
            log "DEBUG" "Removing _CodeSignature from app extension: ${dir}"
            if ! rm -rf "${dir}/_CodeSignature"; then
                log "ERROR" "Unable to remove CodeSignature under ${dir}"
                return 1
            fi
            log "DEBUG" "Successfully removed signature from app extension"
        else
            log "DEBUG" "No _CodeSignature found in app extension: ${dir}"
        fi
    done
    shopt -u nullglob
    if [[ "$found_appex" == false ]]; then
        log "WARN" "No app extensions found"
    fi
    # Remove framework signatures
    local found_framework=false
    shopt -s nullglob
    for dir in "${app_dir}/Frameworks"/*.framework ; do
        [[ -e "$dir" ]] || continue
        found_framework=true
        log "DEBUG" "Removing signature from ${dir}"
        if [[ -d "${dir}/_CodeSignature" ]]; then
            log "DEBUG" "Removing _CodeSignature from framework: ${dir}"
            if ! rm -rf "${dir}/_CodeSignature"; then
                log "ERROR" "Unable to remove CodeSignature under ${dir}"
                return 1
            fi
            log "DEBUG" "Successfully removed signature from framework"
        else
            log "DEBUG" "No _CodeSignature found in framework: ${dir}"
        fi
    done
    shopt -u nullglob
    if [[ "$found_framework" == false ]]; then
        log "WARN" "No frameworks found"
    fi
    log "INFO" "*** Delete App Signature Completed ***"
}

#######################################
# Delete existing entitlement file
# Globals:
#   APP_NAME, PAYLOAD_PATH, DESTINATION_FOLDER_PATH, TEAM_ID, BUNDLE_IDENTIFIER,
#   NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER, WIDGET_EXTENSION_BUNDLE_IDENTIFIER,
#   CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER
# Arguments:
#   None
# Outputs:
#   Writes location to stdout

#######################################
function delete_app_entitlements() {
    log "DEBUG" "Starting delete_app_entitlements function"
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${DESTINATION_FOLDER_PATH}" ]] || [[ -z "${TEAM_ID}" ]] || [[ -z "${BUNDLE_IDENTIFIER}" ]]; then
        log "ERROR" "Required variables are not set"
        return 1
    fi
    log "INFO" "*** Delete App Entitlement ***"
    log "INFO" "Removing entitlements ${PAYLOAD_PATH}/${APP_NAME}/"
    local entitlements="${DESTINATION_FOLDER_PATH}/${APP_NAME%.*}_entitlement.plist"
    log "DEBUG" "Main app entitlements file: ${entitlements}"
    log "DEBUG" "Extracting entitlements from main app"
    if ! codesign -d --entitlements :- "${PAYLOAD_PATH}/${APP_NAME}" > "${entitlements}"; then
        log "ERROR" "Failed to extract entitlements from main app"
        return 1
    fi
    log "DEBUG" "Deleting beta-reports-active from main app entitlements"
    if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${entitlements}"; then
        log "ERROR" "Failed to delete beta-reports-active from entitlements"
        return 1
    fi
    log "DEBUG" "Setting application-identifier: ${TEAM_ID}.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        log "ERROR" "Failed to set application-identifier"
        return 1
    fi
    log "DEBUG" "Setting team-identifier: ${TEAM_ID}"
    if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${entitlements}"; then
        log "ERROR" "Failed to set team-identifier"
        return 1
    fi
    log "DEBUG" "Setting keychain-access-groups: ${TEAM_ID}.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        log "ERROR" "Failed to set keychain-access-groups"
        return 1
    fi
    log "DEBUG" "Setting application-groups: group.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        log "ERROR" "Failed to set application-groups"
        return 1
    fi
    # Process NotificationServiceExtension
    log "INFO" "Removing entitlements from ${PAYLOAD_PATH}/${APP_NAME}/PlugIns/NotificationServiceExtension.appex"
    local extension_entitlements="${DESTINATION_FOLDER_PATH}/NotificationServiceExtension_entitlement.plist"
    log "DEBUG" "NotificationServiceExtension entitlements file: ${extension_entitlements}"
    log "DEBUG" "Extracting entitlements from NotificationServiceExtension"
    if ! codesign -d --entitlements :- "${PAYLOAD_PATH}/${APP_NAME}/PlugIns/NotificationServiceExtension.appex" > "${extension_entitlements}"; then
        log "ERROR" "Failed to extract entitlements from NotificationServiceExtension"
        return 1
    fi
    log "DEBUG" "Deleting beta-reports-active from NotificationServiceExtension entitlements"
    if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${extension_entitlements}"; then
        log "ERROR" "Failed to delete beta-reports-active from NotificationServiceExtension entitlements"
        return 1
    fi
    log "DEBUG" "Setting team-identifier for NotificationServiceExtension: ${TEAM_ID}"
    if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set team-identifier for NotificationServiceExtension"
        return 1
    fi
    log "DEBUG" "Setting application-identifier for NotificationServiceExtension: ${TEAM_ID}.${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-identifier for NotificationServiceExtension"
        return 1
    fi
    log "DEBUG" "Setting keychain-access-groups for NotificationServiceExtension: ${TEAM_ID}.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set keychain-access-groups for NotificationServiceExtension"
        return 1
    fi
    log "DEBUG" "Setting application-groups for NotificationServiceExtension: group.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-groups for NotificationServiceExtension"
        return 1
    fi
    # Process SAppWidgetsExtension
    log "INFO" "Removing entitlements from ${PAYLOAD_PATH}/${APP_NAME}/PlugIns/SAppWidgetsExtension.appex"
    extension_entitlements="${DESTINATION_FOLDER_PATH}/SAppWidgetsExtension_entitlement.plist"
    log "DEBUG" "SAppWidgetsExtension entitlements file: ${extension_entitlements}"
    log "DEBUG" "Extracting entitlements from SAppWidgetsExtension"
    if ! codesign -d --entitlements :- "${PAYLOAD_PATH}/${APP_NAME}/PlugIns/SAppWidgetsExtension.appex" > "${extension_entitlements}"; then
        log "ERROR" "Failed to extract entitlements from SAppWidgetsExtension"
        return 1
    fi
    log "DEBUG" "Deleting beta-reports-active from SAppWidgetsExtension entitlements"
    if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${extension_entitlements}"; then
        log "ERROR" "Failed to delete beta-reports-active from SAppWidgetsExtension entitlements"
        return 1
    fi
    log "DEBUG" "Setting team-identifier for SAppWidgetsExtension: ${TEAM_ID}"
    if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set team-identifier for SAppWidgetsExtension"
        return 1
    fi
    log "DEBUG" "Setting application-identifier for SAppWidgetsExtension: ${TEAM_ID}.${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-identifier for SAppWidgetsExtension"
        return 1
    fi
    log "DEBUG" "Setting keychain-access-groups for SAppWidgetsExtension: ${TEAM_ID}.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set keychain-access-groups for SAppWidgetsExtension"
        return 1
    fi
    log "DEBUG" "Setting application-groups for SAppWidgetsExtension: group.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-groups for SAppWidgetsExtension"
        return 1
    fi
    # Process SAppCallDirectoryExtension
    log "INFO" "Removing entitlements from ${PAYLOAD_PATH}/${APP_NAME}/PlugIns/SAppCallDirectoryExtension.appex"
    extension_entitlements="${DESTINATION_FOLDER_PATH}/SAppCallDirectoryExtension_entitlement.plist"
    log "DEBUG" "SAppCallDirectoryExtension entitlements file: ${extension_entitlements}"
    log "DEBUG" "Extracting entitlements from SAppCallDirectoryExtension"
    if ! codesign -d --entitlements :- "${PAYLOAD_PATH}/${APP_NAME}/PlugIns/SAppCallDirectoryExtension.appex" > "${extension_entitlements}"; then
        log "ERROR" "Failed to extract entitlements from SAppCallDirectoryExtension"
        return 1
    fi
    log "DEBUG" "Deleting beta-reports-active from SAppCallDirectoryExtension entitlements"
    if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${extension_entitlements}"; then
        log "ERROR" "Failed to delete beta-reports-active from SAppCallDirectoryExtension entitlements"
        return 1
    fi
    log "DEBUG" "Setting team-identifier for SAppCallDirectoryExtension: ${TEAM_ID}"
    if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set team-identifier for SAppCallDirectoryExtension"
        return 1
    fi
    log "DEBUG" "Setting application-identifier for SAppCallDirectoryExtension: ${TEAM_ID}.${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-identifier for SAppCallDirectoryExtension"
        return 1
    fi
    log "DEBUG" "Setting keychain-access-groups for SAppCallDirectoryExtension: ${TEAM_ID}.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set keychain-access-groups for SAppCallDirectoryExtension"
        return 1
    fi
    log "DEBUG" "Setting application-groups for SAppCallDirectoryExtension: group.${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
        log "ERROR" "Failed to set application-groups for SAppCallDirectoryExtension"
        return 1
    fi
    log "INFO" "*** Delete App Entitlement Completed ***"
}

#######################################
# Replace existing provisioning profile to app and app extension
# Globals:
#   APP_NAME, PAYLOAD_PATH, MOBILEPROVISION, NOTIFICATION_EXTENSION_MOBILEPROVISION,
#   WIDGET_EXTENSION_MOBILEPROVISION, CALL_DIRECTORY_EXTENSION_MOBILEPROVISION
# Arguments:
#   None

#######################################
function replace_provisioning_profiles() {
    log "DEBUG" "Starting replace_provisioning_profiles function"
    # Validate required variables
    if [[ -z "${APP_NAME}" ]] || [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${MOBILEPROVISION}" ]] || [[ -z "${NOTIFICATION_EXTENSION_MOBILEPROVISION}" ]] || [[ -z "${WIDGET_EXTENSION_MOBILEPROVISION}" ]] || [[ -z "${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}" ]]; then
        log "ERROR" "Required variables are not set"
        return 1
    fi
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    log "DEBUG" "App directory: ${app_dir}"
    if [[ ! -d "${app_dir}" ]]; then
        log "ERROR" "App directory ${app_dir} does not exist"
        return 1
    fi
    log "INFO" "*** Replace Provisioning Profile ***"
    log "INFO" "Replacing provisioning profile in ${APP_NAME}"
    log "DEBUG" "Copying main app mobileprovision: ${MOBILEPROVISION}"
    if ! cp "${MOBILEPROVISION}" "${app_dir}/embedded.mobileprovision"; then
        log "ERROR" "Unable to copy ${MOBILEPROVISION} to ${app_dir}/embedded.mobileprovision"
        return 1
    fi
    log "DEBUG" "Successfully copied main app mobileprovision"
    log "DEBUG" "Copying NotificationServiceExtension mobileprovision: ${NOTIFICATION_EXTENSION_MOBILEPROVISION}"
    if ! cp "${NOTIFICATION_EXTENSION_MOBILEPROVISION}" "${app_dir}/PlugIns/NotificationServiceExtension.appex/embedded.mobileprovision"; then
        log "ERROR" "Unable to copy ${NOTIFICATION_EXTENSION_MOBILEPROVISION} to ${app_dir}/PlugIns/NotificationServiceExtension.appex/embedded.mobileprovision"
        return 1
    fi
    log "DEBUG" "Successfully copied NotificationServiceExtension mobileprovision"
    log "DEBUG" "Copying SAppWidgetsExtension mobileprovision: ${WIDGET_EXTENSION_MOBILEPROVISION}"
    if ! cp "${WIDGET_EXTENSION_MOBILEPROVISION}" "${app_dir}/PlugIns/SAppWidgetsExtension.appex/embedded.mobileprovision"; then
        log "ERROR" "Unable to copy ${WIDGET_EXTENSION_MOBILEPROVISION} to ${app_dir}/PlugIns/SAppWidgetsExtension.appex/embedded.mobileprovision"
        return 1
    fi
    log "DEBUG" "Successfully copied SAppWidgetsExtension mobileprovision"
    log "DEBUG" "Copying SAppCallDirectoryExtension mobileprovision: ${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}"
    if ! cp "${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}" "${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/embedded.mobileprovision"; then
        log "ERROR" "Unable to copy ${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION} to ${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/embedded.mobileprovision"
        return 1
    fi
    log "DEBUG" "Successfully copied SAppCallDirectoryExtension mobileprovision"
    log "INFO" "*** Replace Provisioning Profile Completed ***"
}

#######################################
# Update plist value with new bundle identifier
# Globals:
#   APP_NAME, PAYLOAD_PATH, BUNDLE_IDENTIFIER, NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER,
#   WIDGET_EXTENSION_BUNDLE_IDENTIFIER, CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER
# Arguments:
#   None

#######################################
function update_plist() {
    log "DEBUG" "Starting update_plist function"
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${BUNDLE_IDENTIFIER}" ]]; then
        log "ERROR" "Required variables are not set"
        return 1
    fi
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    log "DEBUG" "App directory: ${app_dir}"
    if [[ ! -d "${app_dir}" ]]; then
        log "ERROR" "App directory ${app_dir} does not exist"
        return 1
    fi
    log "INFO" "*** Updating Bundle ID in Plist ***"
    log "INFO" "Updating bundle identifier in ${app_dir}/Info.plist with value ${BUNDLE_IDENTIFIER}"
    log "DEBUG" "Setting CFBundleIdentifier for main app: ${BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${BUNDLE_IDENTIFIER}" "${app_dir}/Info.plist"; then
        log "ERROR" "Unable to update bundle identifier in plist"
        return 1
    fi
    if ! update_group_identifier "${app_dir}/Info.plist"; then
        log "ERROR" "Failed to update group identifier for main app"
        return 1
    fi
    #
    # Update the extension bundle ID's
    #
    # NotificationServiceExtension
    log "INFO" "Updating bundle identifier in ${app_dir}/PlugIns/NotificationServiceExtension.appex/Info.plist with value ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}.NotificationServiceExtension"
    log "DEBUG" "Setting CFBundleIdentifier for NotificationServiceExtension: ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}" "${app_dir}/PlugIns/NotificationServiceExtension.appex/Info.plist"; then
        log "ERROR" "Unable to update bundle identifier in ${app_dir}/PlugIns/NotificationServiceExtension.appex/Info.plist "
        return 1
    fi
    if ! update_group_identifier "${app_dir}/PlugIns/NotificationServiceExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update group identifier for NotificationServiceExtension"
        return 1
    fi
    # SAppWidgetsExtension
    log "INFO" "Updating bundle identifier in ${app_dir}/PlugIns/SAppWidgetsExtension.appex/Info.plist with value ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}.WidgetExtension"
    log "DEBUG" "Setting CFBundleIdentifier for SAppWidgetsExtension: ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}" "${app_dir}/PlugIns/SAppWidgetsExtension.appex/Info.plist"; then
        log "ERROR" "Unable to update bundle identifier in ${app_dir}/PlugIns/SAppWidgetsExtension.appex/Info.plist "
        return 1
    fi
    if ! update_group_identifier "${app_dir}/PlugIns/SAppWidgetsExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update group identifier for SAppWidgetsExtension"
        return 1
    fi
    # Call Directory extension
    log "INFO" "Updating bundle identifier in ${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/Info.plist with value ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}.CallDirectoryExtension"
    log "DEBUG" "Setting CFBundleIdentifier for SAppCallDirectoryExtension: ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}" "${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/Info.plist"; then
        log "ERROR" "Unable to update bundle identifier in ${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/Info.plist "
        return 1
    fi
    if ! update_group_identifier "${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update group identifier for SAppCallDirectoryExtension"
        return 1
    fi
    log "INFO" "*** Update Bundle ID in Plist Completed ***"
    # Update CFBundleVersion if supplied
    log "DEBUG" "Updating bundle versions for all components"
    if ! update_bundle_version "${app_dir}/Info.plist"; then
        log "ERROR" "Failed to update bundle version for main app"
        return 1
    fi
    if ! update_bundle_version "${app_dir}/PlugIns/NotificationServiceExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update bundle version for NotificationServiceExtension"
        return 1
    fi
    if ! update_bundle_version "${app_dir}/PlugIns/SAppWidgetsExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update bundle version for SAppWidgetsExtension"
        return 1
    fi
    if ! update_bundle_version "${app_dir}/PlugIns/SAppCallDirectoryExtension.appex/Info.plist"; then
        log "ERROR" "Failed to update bundle version for SAppCallDirectoryExtension"
        return 1
    fi
}

#######################################
# Update plist value with new group identifier
# Globals:
#   APP_GROUP_IDENTIFIER
# Arguments:
#   None

#######################################
function update_group_identifier() {
    log "DEBUG" "Starting update_group_identifier function"
    # Validate input parameter
    if [[ $# -eq 0 ]]; then
        log "ERROR" "No plist file path provided"
        return 1
    fi
    local plist_file="$1"
    log "DEBUG" "Processing plist file: ${plist_file}"
    # Check if plist file exists
    if [[ ! -f "${plist_file}" ]]; then
        log "ERROR" "Plist file ${plist_file} does not exist"
        return 1
    fi
    log "INFO" "*** Updating Group ID in Plist ***"
    log "INFO" "Updating Group identifier in ${plist_file} with value ${APP_GROUP_IDENTIFIER}"
    # Update the group identifier
    log "DEBUG" "Running PlistBuddy command: Set AppGroupIdentifier ${APP_GROUP_IDENTIFIER}"
    if ! /usr/libexec/PlistBuddy -c "Set AppGroupIdentifier ${APP_GROUP_IDENTIFIER}" "${plist_file}"; then
        log "ERROR" "Unable to update group identifier in ${plist_file}"
        return 1
    fi
    log "INFO" "Successfully updated group identifier to ${APP_GROUP_IDENTIFIER} for ${plist_file}"
    log "INFO" "*** Update Group identifier in Plist Completed ***"
}

#######################################
# Update plist with bundle version arg
# Globals:
#   BUNDLE_VERSION
# Arguments:
#   None

#######################################
function update_bundle_version() {
    log "DEBUG" "Starting update_bundle_version function"
    # Validate input parameter
    if [[ $# -eq 0 ]]; then
        log "ERROR" "No plist file path provided"
        return 1
    fi
    local plist_file="$1"
    log "DEBUG" "Processing plist file: ${plist_file}"
    # Check if plist file exists
    if [[ ! -f "${plist_file}" ]]; then
        log "ERROR" "Plist file ${plist_file} does not exist"
        return 1
    fi
    # Check if BUNDLE_VERSION is set and not empty
    if [[ -z "${BUNDLE_VERSION:-}" ]]; then
        log "WARN" "BUNDLE_VERSION is not set, skipping bundle version update"
        return 0
    fi
    log "INFO" "*** Updating CFBundleVersion to ${BUNDLE_VERSION} for ${plist_file}"
    # Update the bundle version
    log "DEBUG" "Running PlistBuddy command: Set CFBundleVersion ${BUNDLE_VERSION}"
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleVersion ${BUNDLE_VERSION}" "${plist_file}"; then
        log "ERROR" "Unable to update CFBundleVersion for ${plist_file}"
        return 1
    fi
    log "INFO" "Successfully updated CFBundleVersion to ${BUNDLE_VERSION} for ${plist_file}"
}

#######################################
# Resign app frameworks with cert.
# Globals:
#   PAYLOAD_PATH, APP_NAME, SIGNING_IDENTITY
# Arguments:
#   None

#######################################
function codesign_frameworks() {
    log "DEBUG" "Starting codesign_frameworks function"
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${SIGNING_IDENTITY}" ]]; then
        log "ERROR" "PAYLOAD_PATH, APP_NAME, or SIGNING_IDENTITY variables are not set"
        return 1
    fi
    local frameworks_dir="${PAYLOAD_PATH}/${APP_NAME}/Frameworks"
    log "DEBUG" "Frameworks directory: ${frameworks_dir}"
    # Check if frameworks directory exists
    if [[ ! -d "${frameworks_dir}" ]]; then
        log "WARN" "Frameworks directory ${frameworks_dir} does not exist"
        return 0
    fi
    log "INFO" "*** Codesign Frameworks ***"
    local found_framework=false
    local failed_codesign=false
    # Enable nullglob to handle cases where no frameworks exist
    shopt -s nullglob
    for dir in "${frameworks_dir}"/*.framework ; do
        [[ -e "$dir" ]] || continue
        found_framework=true
        log "DEBUG" "Codesign ${dir} with ${SIGNING_IDENTITY}"
        # Codesign the framework
        local codesign_flags="-fs"
        if [[ "$VERBOSE" == true ]]; then
            codesign_flags="--verbose -fs"
        fi
        log "DEBUG" "Running codesign command: codesign ${codesign_flags} ${SIGNING_IDENTITY} ${dir}"
        if ! codesign ${codesign_flags} "${SIGNING_IDENTITY}" "${dir}"; then
            log "ERROR" "Failed to codesign ${dir}"
            failed_codesign=true
            continue
        fi
        # Verify the codesign
        log "DEBUG" "Verifying codesign for ${dir}"
        if ! codesign -vv "${dir}" >/dev/null 2>&1; then
            log "ERROR" "Failed to verify codesign for ${dir}"
            failed_codesign=true
            continue
        fi
        log "DEBUG" "Successfully codesigned ${dir}"
    done
    # Disable nullglob
    shopt -u nullglob
    if [[ "$found_framework" == false ]]; then
        log "WARN" "No frameworks found in ${frameworks_dir}"
    fi
    if [[ "$failed_codesign" == true ]]; then
        log "ERROR" "Some frameworks failed to codesign"
        return 1
    fi
    log "INFO" "*** Codesign Frameworks Completed ***"
}

#######################################
# Resign app and app extension with cert.
# Globals:
#   PAYLOAD_PATH, APP_NAME, SIGNING_IDENTITY
# Arguments:
#   None

#######################################
function codesign_ipa() {
    log "DEBUG" "Starting codesign_ipa function"
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${SIGNING_IDENTITY}" ]] || [[ -z "${DESTINATION_FOLDER_PATH}" ]]; then
        log "ERROR" "PAYLOAD_PATH, APP_NAME, SIGNING_IDENTITY, or DESTINATION_FOLDER_PATH variables are not set"
        return 1
    fi
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    log "DEBUG" "App directory: ${app_dir}"
    # Check if app directory exists
    if [[ ! -d "${app_dir}" ]]; then
        log "ERROR" "App directory ${app_dir} does not exist"
        return 1
    fi
    log "INFO" "*** Codesign App ***"
    local failed_codesign=false
    # Codesign app extensions
    local found_appex=false
    shopt -s nullglob
    for dir in "${app_dir}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        found_appex=true
        local app_name_extension
        app_name_extension=$(basename "${dir}")
        local entitlements_file="${DESTINATION_FOLDER_PATH}/${app_name_extension%.*}_ENTITLEMENT.plist"
        log "INFO" "Codesigning app extension: ${app_name_extension}"
        log "DEBUG" "Entitlements file: ${entitlements_file}"
        # Check if entitlements file exists
        if [[ ! -f "${entitlements_file}" ]]; then
            log "ERROR" "Entitlements file ${entitlements_file} does not exist"
            failed_codesign=true
            continue
        fi
        # Codesign the app extension
        local codesign_flags="-f -s"
        if [[ "$VERBOSE" == true ]]; then
            codesign_flags="--verbose -f -s"
        fi
        log "DEBUG" "Running codesign command for app extension: codesign ${codesign_flags} ${SIGNING_IDENTITY} --entitlements ${entitlements_file} ${dir}"
        if ! codesign ${codesign_flags} "${SIGNING_IDENTITY}" --entitlements "${entitlements_file}" "${dir}"; then
            log "ERROR" "Failed to codesign ${dir}"
            failed_codesign=true
            continue
        fi
        # Verify the codesign
        log "DEBUG" "Verifying codesign for app extension: ${dir}"
        if ! codesign -vv "${dir}" >/dev/null 2>&1; then
            log "ERROR" "Failed to verify codesign for ${dir}"
            failed_codesign=true
            continue
        fi
        # Clean up entitlements file
        log "DEBUG" "Cleaning up entitlements file: ${entitlements_file}"
        if ! rm -f "${entitlements_file}"; then
            log "WARN" "Failed to remove ${entitlements_file}"
        fi
        log "INFO" "Successfully codesigned ${app_name_extension}"
    done
    shopt -u nullglob
    if [[ "$found_appex" == false ]]; then
        log "WARN" "No app extensions found"
    fi
    # Codesign main app
    local main_entitlements_file="${DESTINATION_FOLDER_PATH}/${APP_NAME%.*}_entitlement.plist"
    log "INFO" "Codesigning main app: ${APP_NAME}"
    log "DEBUG" "Main app entitlements file: ${main_entitlements_file}"
    # Check if main entitlements file exists
    if [[ ! -f "${main_entitlements_file}" ]]; then
        log "ERROR" "Main entitlements file ${main_entitlements_file} does not exist"
        return 1
    fi
    # Codesign the main app
    local codesign_flags="-f -s"
    if [[ "$VERBOSE" == true ]]; then
        codesign_flags="--verbose -f -s"
    fi
    log "DEBUG" "Running codesign command for main app: codesign ${codesign_flags} ${SIGNING_IDENTITY} --entitlements ${main_entitlements_file} ${app_dir}"
    if ! codesign ${codesign_flags} "${SIGNING_IDENTITY}" --entitlements "${main_entitlements_file}" "${app_dir}"; then
        log "ERROR" "Failed to codesign main app ${app_dir}"
        return 1
    fi
    # Verify the main app codesign
    log "DEBUG" "Verifying codesign for main app: ${app_dir}"
    if ! codesign -vv "${app_dir}" >/dev/null 2>&1; then
        log "ERROR" "Failed to verify codesign for main app ${app_dir}"
        return 1
    fi
    # Clean up main entitlements file
    log "DEBUG" "Cleaning up main entitlements file: ${main_entitlements_file}"
    if ! rm -f "${main_entitlements_file}"; then
        log "WARN" "Failed to remove ${main_entitlements_file}"
    fi
    if [[ "$failed_codesign" == true ]]; then
        log "ERROR" "Some app extensions failed to codesign"
        return 1
    fi
    log "INFO" "Successfully codesigned main app: ${APP_NAME}"
    log "INFO" "*** Codesign App Completed ***"
}

#######################################
# Zip to ipa file
# Globals:
#   DESTINATION_FOLDER_PATH, PAYLOAD_PATH, SYMBOLS_PATH, SWIFT_PATH
# Arguments:
#   None

#######################################
function zip_ipa() {
    log "DEBUG" "Starting zip_ipa function"
    # Validate required variables
    if [[ -z "${DESTINATION_FOLDER_PATH}" ]]; then
        log "ERROR" "DESTINATION_FOLDER_PATH variable is not set"
        return 1
    fi
    if [[ ! -d "${DESTINATION_FOLDER_PATH}" ]]; then
        log "ERROR" "Destination directory ${DESTINATION_FOLDER_PATH} does not exist"
        return 1
    fi
    # Check if required directories exist
    if [[ ! -d "${DESTINATION_FOLDER_PATH}/Payload" ]]; then
        log "ERROR" "Payload directory does not exist in ${DESTINATION_FOLDER_PATH}"
        return 1
    fi
    log "INFO" "*** Zip IPA File ***"
    # Store current directory to restore later
    local current_dir
    current_dir=$(pwd)
    log "DEBUG" "Current directory: ${current_dir}"
    # Change to destination directory
    log "DEBUG" "Changing to destination directory: ${DESTINATION_FOLDER_PATH}"
    if ! cd "${DESTINATION_FOLDER_PATH}"; then
        log "ERROR" "Failed to change to directory ${DESTINATION_FOLDER_PATH}"
        return 1
    fi
    local output_file="resigned.ipa"
    log "DEBUG" "Output file: ${output_file}"
    # Create the zip file
    log "INFO" "Creating ${output_file}..."
    log "DEBUG" "Running zip command: zip -qr ${output_file} Payload/* SwiftSupport/*"
    if ! zip -qr "${output_file}" Payload/* SwiftSupport/* 2>/dev/null; then
        log "ERROR" "Failed to create zip file ${output_file}"
        cd "${current_dir}" || true
        return 1
    fi
    # Verify the zip file was created
    if [[ ! -f "${output_file}" ]]; then
        log "ERROR" "Zip file ${output_file} was not created"
        cd "${current_dir}" || true
        return 1
    fi
    # Clean up temporary files
    log "INFO" "Cleaning up temporary files..."
    if [[ -d "${PAYLOAD_PATH}" ]]; then
        log "DEBUG" "Removing PAYLOAD_PATH: ${PAYLOAD_PATH}"
        if ! rm -rf "${PAYLOAD_PATH}"; then
            log "WARN" "Failed to remove ${PAYLOAD_PATH}"
        fi
    fi
    if [[ -d "${SYMBOLS_PATH}" ]]; then
        log "DEBUG" "Removing SYMBOLS_PATH: ${SYMBOLS_PATH}"
        if ! rm -rf "${SYMBOLS_PATH}"; then
            log "WARN" "Failed to remove ${SYMBOLS_PATH}"
        fi
    fi
    if [[ -d "${SWIFT_PATH}" ]]; then
        log "DEBUG" "Removing SWIFT_PATH: ${SWIFT_PATH}"
        if ! rm -rf "${SWIFT_PATH}"; then
            log "WARN" "Failed to remove ${SWIFT_PATH}"
        fi
    fi
    # Restore original directory
    log "DEBUG" "Restoring original directory: ${current_dir}"
    cd "${current_dir}" || true
    log "INFO" "Your resigned app is located in: ${DESTINATION_FOLDER_PATH}/${output_file}"
    log "INFO" "*** Zip IPA File Completed ***"
}

#######################################
# Validate provisioning profiles match bundle identifiers
# Globals:
#   MOBILEPROVISION, NOTIFICATION_EXTENSION_MOBILEPROVISION, WIDGET_EXTENSION_MOBILEPROVISION,
#   CALL_DIRECTORY_EXTENSION_MOBILEPROVISION, BUNDLE_IDENTIFIER, TEAM_ID
# Arguments:
#   None

#######################################
function validate_provisioning_profiles() {
    log "DEBUG" "Starting validate_provisioning_profiles function"
    log "INFO" "*** Validating Provisioning Profiles ***"
    # Validate main app provisioning profile
    if [[ -n "${MOBILEPROVISION}" ]] && [[ -f "${MOBILEPROVISION}" ]]; then
        log "INFO" "Validating main app provisioning profile: ${MOBILEPROVISION}"
        local temp_file=$(mktemp)
        if ! security cms -D -i "${MOBILEPROVISION}" > "${temp_file}" 2>/dev/null; then
            log "ERROR" "Failed to decode main provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # Extract bundle identifier from provisioning profile using enhanced methods
        local profile_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${temp_file}" 2>/dev/null | sed 's/^[^.]*\.//')
        # Alternative - look for any application-identifier pattern
        if [[ -z "${profile_bundle_id}" ]]; then
            profile_bundle_id=$(grep -o '"application-identifier"[[:space:]]*:[[:space:]]*"[^"]*"' "${temp_file}" | cut -d'"' -f4 | sed 's/^[^.]*\.//')
        fi
        local profile_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${temp_file}" 2>/dev/null)
        # Extract app group identifier from provisioning profile
        local profile_app_group=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "${temp_file}" 2>/dev/null)
        # Alternative - look for any app group pattern
        if [[ -z "${profile_app_group}" ]]; then
            profile_app_group=$(grep -o '"com.apple.security.application-groups"[[:space:]]*:[[:space:]]*\[[^]]*\]' "${temp_file}" | grep -o '"[^"]*"' | head -1 | tr -d '"')
        fi
        if [[ -z "${profile_bundle_id}" ]]; then
            log "ERROR" "No bundle identifier found in main provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_team_id}" ]]; then
            log "ERROR" "No team identifier found in main provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_app_group}" ]]; then
            log "ERROR" "No app group identifier found in main provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate bundle identifier
        if [[ "${profile_bundle_id}" != "${BUNDLE_IDENTIFIER}" ]]; then
            log "ERROR" "Bundle identifier mismatch in main provisioning profile"
            log "ERROR" "Expected: ${BUNDLE_IDENTIFIER}"
            log "ERROR" "Found: ${profile_bundle_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate team identifier
        if [[ "${profile_team_id}" != "${TEAM_ID}" ]]; then
            log "ERROR" "Team identifier mismatch in main provisioning profile"
            log "ERROR" "Expected: ${TEAM_ID}"
            log "ERROR" "Found: ${profile_team_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate app group identifier
        if [[ "${profile_app_group}" != "${APP_GROUP_IDENTIFIER}" ]]; then
            log "ERROR" "App group identifier mismatch in main provisioning profile"
            log "ERROR" "Expected: ${APP_GROUP_IDENTIFIER}"
            log "ERROR" "Found: ${profile_app_group}"
            rm -f "${temp_file}"
            return 1
        fi
        log "SUCCESS" "Main app provisioning profile validation passed"
        log "INFO" "Bundle ID: ${profile_bundle_id}, Team ID: ${profile_team_id}, App Group: ${profile_app_group}"
        rm -f "${temp_file}"
    else
        log "ERROR" "Main provisioning profile not found: ${MOBILEPROVISION}"
        return 1
    fi
    # Validate notification extension provisioning profile
    if [[ -n "${NOTIFICATION_EXTENSION_MOBILEPROVISION}" ]] && [[ -f "${NOTIFICATION_EXTENSION_MOBILEPROVISION}" ]]; then
        log "INFO" "Validating notification extension provisioning profile: ${NOTIFICATION_EXTENSION_MOBILEPROVISION}"
        local temp_file=$(mktemp)
        if ! security cms -D -i "${NOTIFICATION_EXTENSION_MOBILEPROVISION}" > "${temp_file}" 2>/dev/null; then
            log "ERROR" "Failed to decode notification extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # Extract bundle identifier from provisioning profile using enhanced methods
        local profile_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${temp_file}" 2>/dev/null | sed 's/^[^.]*\.//')
        # Alternative - look for any application-identifier pattern
        if [[ -z "${profile_bundle_id}" ]]; then
            profile_bundle_id=$(grep -o '"application-identifier"[[:space:]]*:[[:space:]]*"[^"]*"' "${temp_file}" | cut -d'"' -f4 | sed 's/^[^.]*\.//')
        fi
        local profile_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${temp_file}" 2>/dev/null)
        # Extract app group identifier from provisioning profile
        local profile_app_group=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "${temp_file}" 2>/dev/null)
        # Alternative - look for any app group pattern
        if [[ -z "${profile_app_group}" ]]; then
            profile_app_group=$(grep -o '"com.apple.security.application-groups"[[:space:]]*:[[:space:]]*\[[^]]*\]' "${temp_file}" | grep -o '"[^"]*"' | head -1 | tr -d '"')
        fi
        if [[ -z "${profile_bundle_id}" ]]; then
            log "ERROR" "No bundle identifier found in notification extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_team_id}" ]]; then
            log "ERROR" "No team identifier found in notification extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_app_group}" ]]; then
            log "ERROR" "No app group identifier found in notification extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # For extension profile, we expect it to match the extension bundle ID
        if [[ "${profile_bundle_id}" != "${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}" ]]; then
            log "ERROR" "Bundle identifier mismatch in notification extension provisioning profile"
            log "ERROR" "Expected: ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}"
            log "ERROR" "Found: ${profile_bundle_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate team identifier
        if [[ "${profile_team_id}" != "${TEAM_ID}" ]]; then
            log "ERROR" "Team identifier mismatch in notification extension provisioning profile"
            log "ERROR" "Expected: ${TEAM_ID}"
            log "ERROR" "Found: ${profile_team_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate app group identifier
        if [[ "${profile_app_group}" != "${APP_GROUP_IDENTIFIER}" ]]; then
            log "ERROR" "App group identifier mismatch in notification extension provisioning profile"
            log "ERROR" "Expected: ${APP_GROUP_IDENTIFIER}"
            log "ERROR" "Found: ${profile_app_group}"
            rm -f "${temp_file}"
            return 1
        fi
        log "SUCCESS" "Notification extension provisioning profile validation passed"
        log "INFO" "Bundle ID: ${profile_bundle_id}, Team ID: ${profile_team_id}, App Group: ${profile_app_group}"
        rm -f "${temp_file}"
    else
        log "ERROR" "Notification extension provisioning profile not found: ${NOTIFICATION_EXTENSION_MOBILEPROVISION}"
        return 1
    fi
    # Validate widget extension provisioning profile
    if [[ -n "${WIDGET_EXTENSION_MOBILEPROVISION}" ]] && [[ -f "${WIDGET_EXTENSION_MOBILEPROVISION}" ]]; then
        log "INFO" "Validating widget extension provisioning profile: ${WIDGET_EXTENSION_MOBILEPROVISION}"
        local temp_file=$(mktemp)
        if ! security cms -D -i "${WIDGET_EXTENSION_MOBILEPROVISION}" > "${temp_file}" 2>/dev/null; then
            log "ERROR" "Failed to decode widget extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # Extract bundle identifier from provisioning profile using enhanced methods
        local profile_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${temp_file}" 2>/dev/null | sed 's/^[^.]*\.//')
        # Alternative - look for any application-identifier pattern
        if [[ -z "${profile_bundle_id}" ]]; then
            profile_bundle_id=$(grep -o '"application-identifier"[[:space:]]*:[[:space:]]*"[^"]*"' "${temp_file}" | cut -d'"' -f4 | sed 's/^[^.]*\.//')
        fi
        local profile_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${temp_file}" 2>/dev/null)
        # Extract app group identifier from provisioning profile
        local profile_app_group=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "${temp_file}" 2>/dev/null)
        # Alternative - look for any app group pattern
        if [[ -z "${profile_app_group}" ]]; then
            profile_app_group=$(grep -o '"com.apple.security.application-groups"[[:space:]]*:[[:space:]]*\[[^]]*\]' "${temp_file}" | grep -o '"[^"]*"' | head -1 | tr -d '"')
        fi
        if [[ -z "${profile_bundle_id}" ]]; then
            log "ERROR" "No bundle identifier found in widget extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_team_id}" ]]; then
            log "ERROR" "No team identifier found in widget extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_app_group}" ]]; then
            log "ERROR" "No app group identifier found in widget extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # For extension profile, we expect it to match the extension bundle ID
        if [[ "${profile_bundle_id}" != "${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}" ]]; then
            log "ERROR" "Bundle identifier mismatch in widget extension provisioning profile"
            log "ERROR" "Expected: ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}"
            log "ERROR" "Found: ${profile_bundle_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate team identifier
        if [[ "${profile_team_id}" != "${TEAM_ID}" ]]; then
            log "ERROR" "Team identifier mismatch in widget extension provisioning profile"
            log "ERROR" "Expected: ${TEAM_ID}"
            log "ERROR" "Found: ${profile_team_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate app group identifier
        if [[ "${profile_app_group}" != "${APP_GROUP_IDENTIFIER}" ]]; then
            log "ERROR" "App group identifier mismatch in widget extension provisioning profile"
            log "ERROR" "Expected: ${APP_GROUP_IDENTIFIER}"
            log "ERROR" "Found: ${profile_app_group}"
            rm -f "${temp_file}"
            return 1
        fi
        log "SUCCESS" "Widget extension provisioning profile validation passed"
        log "INFO" "Bundle ID: ${profile_bundle_id}, Team ID: ${profile_team_id}, App Group: ${profile_app_group}"
        rm -f "${temp_file}"
    else
        log "ERROR" "Widget extension provisioning profile not found: ${WIDGET_EXTENSION_MOBILEPROVISION}"
        return 1
    fi
    # Validate call directory extension provisioning profile
    if [[ -n "${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}" ]] && [[ -f "${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}" ]]; then
        log "INFO" "Validating call directory extension provisioning profile: ${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}"
        local temp_file=$(mktemp)
        if ! security cms -D -i "${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}" > "${temp_file}" 2>/dev/null; then
            log "ERROR" "Failed to decode call directory extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # Extract bundle identifier from provisioning profile using enhanced methods
        local profile_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${temp_file}" 2>/dev/null | sed 's/^[^.]*\.//')
        # Alternative - look for any application-identifier pattern
        if [[ -z "${profile_bundle_id}" ]]; then
            profile_bundle_id=$(grep -o '"application-identifier"[[:space:]]*:[[:space:]]*"[^"]*"' "${temp_file}" | cut -d'"' -f4 | sed 's/^[^.]*\.//')
        fi
        local profile_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${temp_file}" 2>/dev/null)
        # Extract app group identifier from provisioning profile
        local profile_app_group=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "${temp_file}" 2>/dev/null)
        # Alternative - look for any app group pattern
        if [[ -z "${profile_app_group}" ]]; then
            profile_app_group=$(grep -o '"com.apple.security.application-groups"[[:space:]]*:[[:space:]]*\[[^]]*\]' "${temp_file}" | grep -o '"[^"]*"' | head -1 | tr -d '"')
        fi
        if [[ -z "${profile_bundle_id}" ]]; then
            log "ERROR" "No bundle identifier found in call directory extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_team_id}" ]]; then
            log "ERROR" "No team identifier found in call directory extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_app_group}" ]]; then
            log "ERROR" "No app group identifier found in call directory extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # For extension profile, we expect it to match the extension bundle ID
        if [[ "${profile_bundle_id}" != "${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}" ]]; then
            log "ERROR" "Bundle identifier mismatch in call directory extension provisioning profile"
            log "ERROR" "Expected: ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}"
            log "ERROR" "Found: ${profile_bundle_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate team identifier
        if [[ "${profile_team_id}" != "${TEAM_ID}" ]]; then
            log "ERROR" "Team identifier mismatch in call directory extension provisioning profile"
            log "ERROR" "Expected: ${TEAM_ID}"
            log "ERROR" "Found: ${profile_team_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate app group identifier
        if [[ "${profile_app_group}" != "${APP_GROUP_IDENTIFIER}" ]]; then
            log "ERROR" "App group identifier mismatch in call directory extension provisioning profile"
            log "ERROR" "Expected: ${APP_GROUP_IDENTIFIER}"
            log "ERROR" "Found: ${profile_app_group}"
            rm -f "${temp_file}"
            return 1
        fi
        log "SUCCESS" "Call directory extension provisioning profile validation passed"
        log "INFO" "Bundle ID: ${profile_bundle_id}, Team ID: ${profile_team_id}, App Group: ${profile_app_group}"
        rm -f "${temp_file}"
    else
        log "ERROR" "Call directory extension provisioning profile not found: ${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}"
        return 1
    fi
    log "INFO" "*** Provisioning Profile Validation Completed ***"
}
main()
{
    if [ "$1" == "-h" ]; then
        echo "Usage: `basename $0`"
        echo "\t--input-ipa-path [your ipa file absolute path. eg: /Users/example/app.ipa]"
        echo "\t--output-dir [resigned ipa absolute folder path. eg: /Users/example/output/]"
        echo "\t--signing-identity [list current identities using command: 'security find-identity' example: 'iPhone Developer: John Doe (ABC123)']"
        echo "\t--team-id [signing identity's apple team id]"
        echo "\t--bundle-identifier [bundle id for your new ipa. eg: com.example.myapp]"
        echo "\t--mobileprovision [absolute path of mobileprovision. eg: /Users/example/app.mobileprovision]"
        echo "\t--notification-extension-mobileprovision [absolute path of notification extension mobileprovision. eg: /Users/example/notification.mobileprovision]"
        echo "\t--widget-extension-mobileprovision [absolute path of widget extension mobileprovision. eg: /Users/example/widget.mobileprovision]"
        echo "\t--call-directory-extension-mobileprovision [absolute path of call directory extension mobileprovision. eg: /Users/example/calldirectory.mobileprovision]"
        echo "\t--verbose [enable verbose logging]"
        exit 0
    fi
    if [ $# -lt 7 ]; then
        echo "Invalid Input Arguments." >&2
        echo "run ./resign_salesforceapp.sh -h for more info"
        exit 1
    fi
    while test $# -gt 0; do
        case "$1" in
            --input-ipa-path)
            shift
            readonly FILE=$1
            shift
            ;;
            --output-dir)
            shift
             DESTINATION_FOLDER_PATH="$1/$(date +%F-%H-%M-%S)"
            shift
            ;;
            --signing-identity)
            shift
            readonly SIGNING_IDENTITY=$1
            shift
            ;;
            --team-id)
            shift
            readonly TEAM_ID=$1
            shift
            ;;
            --bundle-identifier)
            shift
            readonly BUNDLE_IDENTIFIER=$1
            shift
            ;;
            --bundle-version)
            shift
            readonly BUNDLE_VERSION=$1
            shift
            ;;
            --mobileprovision)
            shift
            readonly MOBILEPROVISION=$1
            shift
            ;;
            --notification-extension-mobileprovision)
            shift
            readonly NOTIFICATION_EXTENSION_MOBILEPROVISION=$1
            shift
            ;;
            --widget-extension-mobileprovision)
            shift
            readonly WIDGET_EXTENSION_MOBILEPROVISION=$1
            shift
            ;;
            --call-directory-extension-mobileprovision)
            shift
            readonly CALL_DIRECTORY_EXTENSION_MOBILEPROVISION=$1
            shift
            ;;
            --verbose)
            VERBOSE=true
            shift
            ;;
            *)
            echo "Error: Unknown argument '$1'" >&2
            echo "Run ./resign_salesforceapp.sh -h for usage information" >&2
            exit 1
            ;;
        esac
    done
    readonly PAYLOAD_PATH="${DESTINATION_FOLDER_PATH}/Payload"
    readonly SYMBOLS_PATH="${DESTINATION_FOLDER_PATH}/Symbols"
    readonly SWIFT_PATH="${DESTINATION_FOLDER_PATH}/SwiftSupport"
    
    # Always create APP_GROUP_IDENTIFIER from BUNDLE_IDENTIFIER
    APP_GROUP_IDENTIFIER="group.${BUNDLE_IDENTIFIER}"
    log "DEBUG" "Auto-generated APP_GROUP_IDENTIFIER: ${APP_GROUP_IDENTIFIER}"
    
    # Always create NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER from BUNDLE_IDENTIFIER
    NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER}.NotificationServiceExtension"
    log "DEBUG" "Auto-generated NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER: ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}"
    
    # Always create WIDGET_EXTENSION_BUNDLE_IDENTIFIER from BUNDLE_IDENTIFIER
    WIDGET_EXTENSION_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER}.WidgetExtension"
    log "DEBUG" "Auto-generated WIDGET_EXTENSION_BUNDLE_IDENTIFIER: ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}"
    
    # Always create CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER from BUNDLE_IDENTIFIER
    CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER}.SAppCallDirectoryExtension"
    log "DEBUG" "Auto-generated CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER: ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}"
    
    log "DEBUG" "Script started with verbose mode: ${VERBOSE}"
    log "DEBUG" "FILE: ${FILE}"
    log "DEBUG" "DESTINATION_FOLDER_PATH: ${DESTINATION_FOLDER_PATH}"
    log "DEBUG" "SIGNING_IDENTITY: ${SIGNING_IDENTITY}"
    log "DEBUG" "TEAM_ID: ${TEAM_ID}"
    log "DEBUG" "BUNDLE_IDENTIFIER: ${BUNDLE_IDENTIFIER}"
    log "DEBUG" "BUNDLE_VERSION: ${BUNDLE_VERSION}"
    log "DEBUG" "APP_GROUP_IDENTIFIER: ${APP_GROUP_IDENTIFIER}"
    log "DEBUG" "MOBILEPROVISION: ${MOBILEPROVISION}"
    log "DEBUG" "NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER: ${NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER}"
    log "DEBUG" "NOTIFICATION_EXTENSION_MOBILEPROVISION: ${NOTIFICATION_EXTENSION_MOBILEPROVISION}"
    log "DEBUG" "WIDGET_EXTENSION_BUNDLE_IDENTIFIER: ${WIDGET_EXTENSION_BUNDLE_IDENTIFIER}"
    log "DEBUG" "WIDGET_EXTENSION_MOBILEPROVISION: ${WIDGET_EXTENSION_MOBILEPROVISION}"
    log "DEBUG" "CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER: ${CALL_DIRECTORY_EXTENSION_BUNDLE_IDENTIFIER}"
    log "DEBUG" "CALL_DIRECTORY_EXTENSION_MOBILEPROVISION: ${CALL_DIRECTORY_EXTENSION_MOBILEPROVISION}"
    log "DEBUG" "PAYLOAD_PATH: ${PAYLOAD_PATH}"
    log "DEBUG" "SYMBOLS_PATH: ${SYMBOLS_PATH}"
    log "DEBUG" "SWIFT_PATH: ${SWIFT_PATH}"
    log "INFO" "*** Start Resign ***"
    
    # Validate all required dependencies and tools
    if ! validate_dependencies; then
        log "ERROR" "Failed to validate dependencies"
        exit 1
    fi
    
    # Check if signing identity exists in keychain
    if ! check_keychain; then
        log "ERROR" "Failed to validate signing identity in keychain"
        exit 1
    fi
    # Validate provisioning profiles match bundle identifiers
    if ! validate_provisioning_profiles; then
        log "ERROR" "Failed to validate provisioning profiles"
        exit 1
    fi
    # Unzip the IPA file
    if ! unzip_ipa; then
        log "ERROR" "Failed to unzip IPA file"
        exit 1
    fi
    # Delete existing signatures
    if ! delete_signature; then
        log "ERROR" "Failed to delete signatures"
        exit 1
    fi
    # Delete and update entitlements
    if ! delete_app_entitlements; then
        log "ERROR" "Failed to delete/update entitlements"
        exit 1
    fi
    # Update plist files
    if ! update_plist; then
        log "ERROR" "Failed to update plist files"
        exit 1
    fi
    # Replace provisioning profiles
    if ! replace_provisioning_profiles; then
        log "ERROR" "Failed to replace provisioning profiles"
        exit 1
    fi
    # Codesign frameworks
    if ! codesign_frameworks; then
        log "ERROR" "Failed to codesign frameworks"
        exit 1
    fi
    # Codesign app and extensions
    if ! codesign_ipa; then
        log "ERROR" "Failed to codesign app"
        exit 1
    fi
    # Create final IPA file
    if ! zip_ipa; then
        log "ERROR" "Failed to create IPA file"
        exit 1
    fi
    log "INFO" "*** Resign Completed Successfully ***"
}
main "$@"
