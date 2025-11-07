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
# Validate provisioning profiles
# Globals:
#   MOBILEPROVISION, EXTENSION_MOBILEPROVISION, BUNDLE_IDENTIFIER, EXTENSION_BUNDLE_IDENTIFIER, TEAM_ID
# Arguments:
#   None
# Returns:
#   0 if validation passes, 1 if validation fails
#######################################
validate_provisioning_profiles() {
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
    
    # Validate extension provisioning profile
    if [[ -n "${EXTENSION_MOBILEPROVISION}" ]] && [[ -f "${EXTENSION_MOBILEPROVISION}" ]]; then
        log "INFO" "Validating extension provisioning profile: ${EXTENSION_MOBILEPROVISION}"
        local temp_file=$(mktemp)
        if ! security cms -D -i "${EXTENSION_MOBILEPROVISION}" > "${temp_file}" 2>/dev/null; then
            log "ERROR" "Failed to decode extension provisioning profile"
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
            log "ERROR" "No bundle identifier found in extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_team_id}" ]]; then
            log "ERROR" "No team identifier found in extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        if [[ -z "${profile_app_group}" ]]; then
            log "ERROR" "No app group identifier found in extension provisioning profile"
            rm -f "${temp_file}"
            return 1
        fi
        # For extension profile, we expect it to match the extension bundle ID
        if [[ "${profile_bundle_id}" != "${EXTENSION_BUNDLE_IDENTIFIER}" ]]; then
            log "ERROR" "Bundle identifier mismatch in extension provisioning profile"
            log "ERROR" "Expected: ${EXTENSION_BUNDLE_IDENTIFIER}"
            log "ERROR" "Found: ${profile_bundle_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate team identifier
        if [[ "${profile_team_id}" != "${TEAM_ID}" ]]; then
            log "ERROR" "Team identifier mismatch in extension provisioning profile"
            log "ERROR" "Expected: ${TEAM_ID}"
            log "ERROR" "Found: ${profile_team_id}"
            rm -f "${temp_file}"
            return 1
        fi
        # Validate app group identifier
        if [[ "${profile_app_group}" != "${APP_GROUP_IDENTIFIER}" ]]; then
            log "ERROR" "App group identifier mismatch in extension provisioning profile"
            log "ERROR" "Expected: ${APP_GROUP_IDENTIFIER}"
            log "ERROR" "Found: ${profile_app_group}"
            rm -f "${temp_file}"
            return 1
        fi
        log "SUCCESS" "Extension provisioning profile validation passed"
        log "INFO" "Bundle ID: ${profile_bundle_id}, Team ID: ${profile_team_id}, App Group: ${profile_app_group}"
        rm -f "${temp_file}"
    else
        log "ERROR" "Extension provisioning profile not found: ${EXTENSION_MOBILEPROVISION}"
        return 1
    fi
    
    log "INFO" "*** Provisioning Profile Validation Completed ***"
    return 0
}

#######################################
# Unzip ipa file to location
# Globals:
#   DESTINATION_FOLDER_PATH FILE
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
#   SOMEDIR
# Arguments:
#   None
# Outputs:
#   Writes location to stdout
#######################################
function delete_app_entitlements() {
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${DESTINATION_FOLDER_PATH}" ]] || [[ -z "${TEAM_ID}" ]] || [[ -z "${BUNDLE_IDENTIFIER}" ]]; then
        echo "Error: Required variables are not set" >&2
        return 1
    fi
    
    echo "*** Delete App Entitlement ***" 
    echo "Removing entitlements ${PAYLOAD_PATH}/${APP_NAME}/"
    local entitlements="${DESTINATION_FOLDER_PATH}/${APP_NAME%.*}_entitlement.plist"
    
    if ! codesign -d --entitlements :- "${PAYLOAD_PATH}/${APP_NAME}" > "${entitlements}"; then
        echo "Error: Failed to extract entitlements from main app" >&2
        return 1
    fi
    
    if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${entitlements}"; then
        echo "Error: Failed to delete beta-reports-active from entitlements" >&2
        return 1
    fi
    
    if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        echo "Error: Failed to set application-identifier" >&2
        return 1
    fi
    
    if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${entitlements}"; then
        echo "Error: Failed to set team-identifier" >&2
        return 1
    fi
    
    if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        echo "Error: Failed to set keychain-access-groups" >&2
        return 1
    fi
    
    if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${entitlements}"; then
        echo "Error: Failed to set application-groups" >&2
        return 1
    fi

    # Process app extensions
    local found_appex=false
    shopt -s nullglob
    for dir in "${PAYLOAD_PATH}/${APP_NAME}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        found_appex=true
        
        echo "Removing entitlements from ${dir}"
        local app_name_extension
        app_name_extension=$(basename "${dir}")
        local extension_entitlements="${DESTINATION_FOLDER_PATH}/${app_name_extension%.*}_entitlement.plist"

        if ! codesign -d --entitlements :- "${dir}" > "${extension_entitlements}"; then
            echo "Error: Failed to extract entitlements from ${dir}" >&2
            return 1
        fi
        
        if ! /usr/libexec/PlistBuddy -c 'Delete beta-reports-active' "${extension_entitlements}"; then
            echo "Error: Failed to delete beta-reports-active from extension entitlements" >&2
            return 1
        fi
        
        if ! /usr/libexec/PlistBuddy -c "Set com.apple.developer.team-identifier ${TEAM_ID}" "${extension_entitlements}"; then
            echo "Error: Failed to set team-identifier for extension" >&2
            return 1
        fi
        
        if ! /usr/libexec/PlistBuddy -c "Set application-identifier ${TEAM_ID}.${EXTENSION_BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
            echo "Error: Failed to set application-identifier for extension" >&2
            return 1
        fi
        
        if ! /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${TEAM_ID}.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
            echo "Error: Failed to set keychain-access-groups for extension" >&2
            return 1
        fi
        
        if ! /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 group.${BUNDLE_IDENTIFIER}" "${extension_entitlements}"; then
            echo "Error: Failed to set application-groups for extension" >&2
            return 1
        fi
    done
    shopt -u nullglob
    
    if [[ "$found_appex" == false ]]; then
        echo "Warning: No app extensions found"
    fi

    echo "*** Delete App Entitlement Completed ***"
}

#######################################
# Replace existing provisioning profile to app and app extension
# Globals:
#   APP_NAME, PAYLOAD_PATH, MOBILEPROVISION, EXTENSION_MOBILEPROVISION
# Arguments:
#   None
#######################################
function replace_provising_profile() {
    # Validate required variables
    if [[ -z "${APP_NAME}" ]] || [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${MOBILEPROVISION}" ]] || [[ -z "${EXTENSION_MOBILEPROVISION}" ]]; then
        echo "Error: Required variables are not set" >&2
        return 1
    fi
    
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    
    if [[ ! -d "${app_dir}" ]]; then
        echo "Error: App directory ${app_dir} does not exist" >&2
        return 1
    fi
    
    echo "*** Replace Provising Profile ***"
    echo "Replacing provising profile in ${APP_NAME}"
    
    if ! cp "${MOBILEPROVISION}" "${app_dir}/embedded.mobileprovision"; then
        echo "Error: Unable to copy ${MOBILEPROVISION} to ${app_dir}/embedded.mobileprovision" >&2
        return 1
    fi
    
    # Process app extensions
    local found_appex=false
    shopt -s nullglob
    for dir in "${app_dir}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        found_appex=true
        
        echo "Replacing provising profile in ${dir}"
        if ! cp "${EXTENSION_MOBILEPROVISION}" "${dir}/embedded.mobileprovision"; then
            echo "Error: Unable to copy ${EXTENSION_MOBILEPROVISION} to ${dir}/embedded.mobileprovision" >&2
            return 1
        fi
    done
    shopt -u nullglob
    
    if [[ "$found_appex" == false ]]; then
        echo "Warning: No app extensions found"
    fi
    
    echo "*** Replace Provising Profile Completed ***"
}

#######################################
# Update plist value with new bundle identifier
# Globals:
#   APP_NAME, PAYLOAD_PATH, BUNDLE_IDENTIFIER
# Arguments:
#   None
#######################################
function update_plist() {
    # Validate required variables
    if [[ -z "${PAYLOAD_PATH}" ]] || [[ -z "${APP_NAME}" ]] || [[ -z "${BUNDLE_IDENTIFIER}" ]]; then
        echo "Error: Required variables are not set" >&2
        return 1
    fi
    
    local app_dir="${PAYLOAD_PATH}/${APP_NAME}"
    
    if [[ ! -d "${app_dir}" ]]; then
        echo "Error: App directory ${app_dir} does not exist" >&2
        return 1
    fi
    
    echo "*** Updating Bundle ID in Plist ***"
    echo "Updating bundle identifier in ${app_dir}/Info.plist with value ${BUNDLE_IDENTIFIER}"
    
    if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${BUNDLE_IDENTIFIER}" "${app_dir}/Info.plist"; then
        echo "Error: Unable to update bundle identifier in plist" >&2
        return 1
    fi

    # Process app extensions
    local found_appex=false
    shopt -s nullglob
    for dir in "${app_dir}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        found_appex=true
        
        local app_name_extension
        app_name_extension=$(basename "${dir}")
        echo "Updating bundle identifier in ${dir}/Info.plist with value ${BUNDLE_IDENTIFIER}.${app_name_extension%.*}"
        
        if ! /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier ${EXTENSION_BUNDLE_IDENTIFIER}" "${dir}/Info.plist"; then
            echo "Error: Unable to update bundle identifier in ${dir}/Info.plist " >&2
            return 1
        fi
        
    done
    shopt -u nullglob
    
    if [[ "$found_appex" == false ]]; then
        echo "Warning: No app extensions found"
    fi
    
    echo "*** Update Bundle ID in Plist Completed ***"
    
    # Update CFBundleVersion if supplied
    log "DEBUG" "Updating bundle versions for all components"
    if ! update_bundle_version "${app_dir}/Info.plist"; then
        log "ERROR" "Failed to update bundle version for main app"
        return 1
    fi
    
    # Update bundle version for app extensions
    shopt -s nullglob
    for dir in "${app_dir}"/*/*.appex ; do
        [[ -e "$dir" ]] || continue
        if ! update_bundle_version "${dir}/Info.plist"; then
            log "ERROR" "Failed to update bundle version for ${dir}"
            return 1
        fi
    done
    shopt -u nullglob
}

#######################################
# Update plist with bundle version arg
# Globals:
#   BUNDLE_VERSION
# Arguments:
#   Plist file path
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
        codesign_flags=" --verbose -f -s"
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
#   DESTINATION_FOLDER_PATH, PAYLOAD_PATH, SYMBOLS_PATH, SWIFTSUPPORT_PATH, FILE
# Arguments:
#   None
#######################################
function zip_ipa() {
    # Validate required variables
    if [[ -z "${DESTINATION_FOLDER_PATH}" ]]; then
        echo "Error: DESTINATION_FOLDER_PATH variable is not set" >&2
        return 1
    fi
    
    if [[ ! -d "${DESTINATION_FOLDER_PATH}" ]]; then
        echo "Error: Destination directory ${DESTINATION_FOLDER_PATH} does not exist" >&2
        return 1
    fi
    
    # Check if required directories exist
    if [[ ! -d "${DESTINATION_FOLDER_PATH}/Payload" ]]; then
        echo "Error: Payload directory does not exist in ${DESTINATION_FOLDER_PATH}" >&2
        return 1
    fi
    
    echo "*** Zip IPA File ***"
    
    # Store current directory to restore later
    local current_dir
    current_dir=$(pwd)
    
    # Change to destination directory
    if ! cd "${DESTINATION_FOLDER_PATH}"; then
        echo "Error: Failed to change to directory ${DESTINATION_FOLDER_PATH}" >&2
        return 1
    fi
    
    local output_file="resigned.ipa"
    
    # Create the zip file
    echo "Creating ${output_file}..."
    if ! zip -qr "${output_file}" Payload/* 2>/dev/null; then
        echo "Error: Failed to create zip file ${output_file}" >&2
        cd "${current_dir}" || true
        return 1
    fi
    
    # Verify the zip file was created
    if [[ ! -f "${output_file}" ]]; then
        echo "Error: Zip file ${output_file} was not created" >&2
        cd "${current_dir}" || true
        return 1
    fi
    
    # Clean up temporary files
    echo "Cleaning up temporary files..."
    if [[ -d "${PAYLOAD_PATH}" ]]; then
        if ! rm -rf "${PAYLOAD_PATH}"; then
            echo "Warning: Failed to remove ${PAYLOAD_PATH}" >&2
        fi
    fi
    
    if [[ -d "${SYMBOLS_PATH}" ]]; then
        if ! rm -rf "${SYMBOLS_PATH}"; then
            echo "Warning: Failed to remove ${SYMBOLS_PATH}" >&2
        fi
    fi
    
    # Restore original directory
    cd "${current_dir}" || true
    
    echo "Your resigned app is located in: ${DESTINATION_FOLDER_PATH}/${output_file}"
    echo "*** Zip IPA File Completed ***"
}

main() 
{
    if [ "$1" == "-h" ]; then
        echo "Usage: `basename $0`"
        echo "\t--input-ipa-paths [your ipa file absolute path. eg: /Users/example/app.ipa]"
        echo "\t--output-dir [resigned ipa absolute folder path. eg: /Users/example/output/]"
        echo "\t--signing-identity [to list current identities list using: security find-identity. eg: iPhone Developer: John Doe (ABC123).]"
        echo "\t--mobileprovision [absolute path of mobileprovision. eg: /Users/example/app.mobileprovision]"
        echo "\t--extension-mobileprovision [absolute path of extension mobileprovision. eg: /Users/example/extension.mobileprovision]"
        echo "\t--team-id [signing identity's apple team id.]"
        echo "\t--bundle-identifier [bundle id for your new ipa. eg: com.example.myapp]"
        echo "\t--bundle-version [new bundle version. eg: 1.2.3]"
        echo "\t--verbose [enable verbose logging]"
        exit 0
    fi

    if [ $# -lt 14 ]; then
        echo "Invalid Input Arguments." >&2
        echo "run ./resign_experiencecloud.sh -h for more info"
        exit 1
    fi

    while test $# -gt 0; do
        case "$1" in
            --input-ipa-paths)
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
            --mobileprovision)
            shift
            readonly MOBILEPROVISION=$1
            shift
            ;;
            --extension-mobileprovision)
            shift
            readonly EXTENSION_MOBILEPROVISION=$1
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
            --verbose)
            VERBOSE=true
            shift
            ;;
            *)
            echo "Error: Unknown argument '$1'" >&2
            echo "Run ./resign_experiencecloud.sh -h for usage information" >&2
            exit 1
            ;;
        esac
    done

    readonly PAYLOAD_PATH="${DESTINATION_FOLDER_PATH}/Payload"
    readonly SYMBOLS_PATH="${DESTINATION_FOLDER_PATH}/Symbols"
    
    # Always create EXTENSION_BUNDLE_IDENTIFIER from BUNDLE_IDENTIFIER
    EXTENSION_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER}.NotificationServiceExtension"
    log "DEBUG" "Auto-generated EXTENSION_BUNDLE_IDENTIFIER: ${EXTENSION_BUNDLE_IDENTIFIER}"
    
    # Always create APP_GROUP_IDENTIFIER from BUNDLE_IDENTIFIER
    APP_GROUP_IDENTIFIER="group.${BUNDLE_IDENTIFIER}"
    log "DEBUG" "Auto-generated APP_GROUP_IDENTIFIER: ${APP_GROUP_IDENTIFIER}"

    log "DEBUG" "Script started with verbose mode: ${VERBOSE}"
    log "DEBUG" "FILE: ${FILE}"
    log "DEBUG" "DESTINATION_FOLDER_PATH: ${DESTINATION_FOLDER_PATH}"
    log "DEBUG" "SIGNING_IDENTITY: ${SIGNING_IDENTITY}"
    log "DEBUG" "TEAM_ID: ${TEAM_ID}"
    log "DEBUG" "BUNDLE_IDENTIFIER: ${BUNDLE_IDENTIFIER}"
    log "DEBUG" "EXTENSION_BUNDLE_IDENTIFIER: ${EXTENSION_BUNDLE_IDENTIFIER}"
    log "DEBUG" "APP_GROUP_IDENTIFIER: ${APP_GROUP_IDENTIFIER}"
    log "DEBUG" "BUNDLE_VERSION: ${BUNDLE_VERSION}"

    log "DEBUG" "MOBILEPROVISION: ${MOBILEPROVISION}"
    log "DEBUG" "EXTENSION_MOBILEPROVISION: ${EXTENSION_MOBILEPROVISION}"
    log "DEBUG" "PAYLOAD_PATH: ${PAYLOAD_PATH}"
    log "DEBUG" "SYMBOLS_PATH: ${SYMBOLS_PATH}"

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
    
    # Validate provisioning profiles
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
    if ! replace_provising_profile; then
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
