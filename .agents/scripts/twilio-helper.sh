#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153
set -euo pipefail

# Twilio Helper Script
# Comprehensive Twilio management for AI assistants
# Supports SMS, Voice, WhatsApp, Verify, Lookup, Recordings, Transcriptions

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 <command> [account] [options]"

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Config can be in repo configs/ or ~/.aidevops/configs/
if [[ -f "${SCRIPT_DIR}/../../configs/twilio-config.json" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/../../configs/twilio-config.json"
elif [[ -f "${HOME}/.aidevops/configs/twilio-config.json" ]]; then
    CONFIG_FILE="${HOME}/.aidevops/configs/twilio-config.json"
else
    CONFIG_FILE="${SCRIPT_DIR}/../../configs/twilio-config.json"
fi

# Check if Twilio CLI or curl is available
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed"
        print_info "Install on macOS: brew install jq"
        print_info "Install on Ubuntu: sudo apt-get install jq"
        exit 1
    fi
    
    # Twilio CLI is optional but recommended
    if command -v twilio &> /dev/null; then
        TWILIO_CLI_AVAILABLE=true
    else
        TWILIO_CLI_AVAILABLE=false
    fi
    
    return 0
}

# Load Twilio configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp configs/twilio-config.json.txt configs/twilio-config.json"
        exit 1
    fi
    return 0
}

# Get account configuration
get_account_config() {
    local account_name="$1"
    
    if [[ -z "$account_name" ]]; then
        print_error "Account name is required"
        list_accounts
        exit 1
    fi
    
    local account_config
    account_config=$(jq -r ".accounts.\"$account_name\"" "$CONFIG_FILE")
    if [[ "$account_config" == "null" ]]; then
        print_error "Account '$account_name' not found in configuration"
        list_accounts
        exit 1
    fi
    
    echo "$account_config"
    return 0
}

# Set Twilio credentials for account
set_twilio_credentials() {
    local account_name="$1"
    local config
    config=$(get_account_config "$account_name")
    
    TWILIO_ACCOUNT_SID=$(echo "$config" | jq -r '.account_sid')
    TWILIO_AUTH_TOKEN=$(echo "$config" | jq -r '.auth_token')
    TWILIO_DEFAULT_FROM=$(echo "$config" | jq -r '.default_from // empty')
    
    if [[ "$TWILIO_ACCOUNT_SID" == "null" || "$TWILIO_AUTH_TOKEN" == "null" ]]; then
        print_error "Invalid Twilio credentials for account '$account_name'"
        exit 1
    fi
    
    export TWILIO_ACCOUNT_SID
    export TWILIO_AUTH_TOKEN
    return 0
}

# Make Twilio API request
twilio_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    local data="$*"
    
    local url="https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}${endpoint}"
    
    if [[ "$method" == "GET" ]]; then
        curl -s -X GET "$url" \
            -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}"
    else
        curl -s -X "$method" "$url" \
            -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
            $data
    fi
    return 0
}

# List all configured accounts
list_accounts() {
    load_config
    print_info "Available Twilio accounts:"
    jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read -r account; do
        local description
        description=$(jq -r ".accounts.\"$account\".description" "$CONFIG_FILE")
        local default_from
        default_from=$(jq -r ".accounts.\"$account\".default_from // \"not set\"" "$CONFIG_FILE")
        echo "  - $account (from: $default_from) - $description"
    done
    return 0
}

# Get account balance
get_balance() {
    local account_name="$1"
    set_twilio_credentials "$account_name"
    
    print_info "Getting balance for account: $account_name"
    local response
    response=$(twilio_api GET "/Balance.json")
    
    local balance currency
    balance=$(echo "$response" | jq -r '.balance')
    currency=$(echo "$response" | jq -r '.currency')
    
    echo "Balance: $currency $balance"
    return 0
}

# List phone numbers
list_numbers() {
    local account_name="$1"
    set_twilio_credentials "$account_name"
    
    print_info "Phone numbers for account: $account_name"
    local response
    response=$(twilio_api GET "/IncomingPhoneNumbers.json")
    
    echo "$response" | jq -r '.incoming_phone_numbers[] | "\(.phone_number) - \(.friendly_name) [\(.capabilities | to_entries | map(select(.value == true) | .key) | join(", "))]"'
    return 0
}

# Search available numbers
search_numbers() {
    local account_name="$1"
    local country="$2"
    shift 2
    
    set_twilio_credentials "$account_name"
    
    local params=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --area-code)
                params="${params}&AreaCode=$2"
                shift 2
                ;;
            --contains)
                params="${params}&Contains=$2"
                shift 2
                ;;
            --sms)
                params="${params}&SmsEnabled=true"
                shift
                ;;
            --voice)
                params="${params}&VoiceEnabled=true"
                shift
                ;;
            --mms)
                params="${params}&MmsEnabled=true"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    print_info "Searching for available numbers in $country..."
    local url="https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/AvailablePhoneNumbers/${country}/Local.json?${params}"
    
    local response
    response=$(curl -s -X GET "$url" -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}")
    
    local count
    count=$(echo "$response" | jq -r '.available_phone_numbers | length')
    
    if [[ "$count" == "0" ]]; then
        print_warning "No numbers available with those criteria"
        print_info "Try different search parameters or contact Twilio support for special numbers"
        return 1
    fi
    
    echo "$response" | jq -r '.available_phone_numbers[] | "\(.phone_number) - \(.locality // "N/A"), \(.region // "N/A") [\(.capabilities | to_entries | map(select(.value == true) | .key) | join(", "))]"'
    return 0
}

# Buy a phone number
buy_number() {
    local account_name="$1"
    local phone_number="$2"
    
    set_twilio_credentials "$account_name"
    
    print_warning "About to purchase number: $phone_number"
    read -p "Confirm purchase? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        print_info "Purchase cancelled"
        return 1
    fi
    
    local response
    response=$(twilio_api POST "/IncomingPhoneNumbers.json" -d "PhoneNumber=$phone_number")
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "Number purchased successfully!"
        echo "$response" | jq -r '"SID: \(.sid)\nNumber: \(.phone_number)\nFriendly Name: \(.friendly_name)"'
    else
        print_error "Failed to purchase number"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# Send SMS
send_sms() {
    local account_name="$1"
    local to="$2"
    local body="$3"
    local from="${4:-$TWILIO_DEFAULT_FROM}"
    
    set_twilio_credentials "$account_name"
    
    if [[ -z "$from" ]]; then
        from="$TWILIO_DEFAULT_FROM"
    fi
    
    if [[ -z "$from" ]]; then
        print_error "No 'from' number specified and no default configured"
        return 1
    fi
    
    # AUP compliance check
    print_info "Sending SMS from $from to $to"
    
    local response
    response=$(twilio_api POST "/Messages.json" \
        -d "To=$to" \
        -d "From=$from" \
        -d "Body=$body")
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "SMS sent successfully!"
        echo "$response" | jq -r '"SID: \(.sid)\nStatus: \(.status)\nTo: \(.to)\nFrom: \(.from)"'
    else
        print_error "Failed to send SMS"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# List messages
list_messages() {
    local account_name="$1"
    local limit="${2:-20}"
    
    set_twilio_credentials "$account_name"
    
    print_info "Recent messages for account: $account_name"
    local response
    response=$(twilio_api GET "/Messages.json?PageSize=$limit")
    
    echo "$response" | jq -r '.messages[] | "\(.date_sent) | \(.direction) | \(.from) -> \(.to) | \(.status) | \(.body[0:50])..."'
    return 0
}

# Get message status
get_message_status() {
    local account_name="$1"
    local message_sid="$2"
    
    set_twilio_credentials "$account_name"
    
    print_info "Getting status for message: $message_sid"
    local response
    response=$(twilio_api GET "/Messages/${message_sid}.json")
    
    echo "$response" | jq -r '"SID: \(.sid)\nStatus: \(.status)\nDirection: \(.direction)\nFrom: \(.from)\nTo: \(.to)\nBody: \(.body)\nDate Sent: \(.date_sent)\nError Code: \(.error_code // "none")\nError Message: \(.error_message // "none")"'
    return 0
}

# Make a call
make_call() {
    local account_name="$1"
    local to="$2"
    shift 2
    
    set_twilio_credentials "$account_name"
    
    local from="$TWILIO_DEFAULT_FROM"
    local twiml=""
    local url=""
    local record="false"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                from="$2"
                shift 2
                ;;
            --twiml)
                twiml="$2"
                shift 2
                ;;
            --url)
                url="$2"
                shift 2
                ;;
            --record)
                record="true"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [[ -z "$from" ]]; then
        print_error "No 'from' number specified and no default configured"
        return 1
    fi
    
    print_info "Initiating call from $from to $to"
    
    local data="-d To=$to -d From=$from"
    
    if [[ -n "$twiml" ]]; then
        data="$data -d Twiml=$twiml"
    elif [[ -n "$url" ]]; then
        data="$data -d Url=$url"
    else
        # Default TwiML
        data="$data -d Twiml=<Response><Say>Hello from AI DevOps!</Say></Response>"
    fi
    
    if [[ "$record" == "true" ]]; then
        data="$data -d Record=true"
    fi
    
    local response
    response=$(twilio_api POST "/Calls.json" $data)
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "Call initiated successfully!"
        echo "$response" | jq -r '"SID: \(.sid)\nStatus: \(.status)\nTo: \(.to)\nFrom: \(.from)"'
    else
        print_error "Failed to initiate call"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# List calls
list_calls() {
    local account_name="$1"
    local limit="${2:-20}"
    
    set_twilio_credentials "$account_name"
    
    print_info "Recent calls for account: $account_name"
    local response
    response=$(twilio_api GET "/Calls.json?PageSize=$limit")
    
    echo "$response" | jq -r '.calls[] | "\(.start_time) | \(.direction) | \(.from) -> \(.to) | \(.status) | \(.duration)s"'
    return 0
}

# List recordings
list_recordings() {
    local account_name="$1"
    local limit="${2:-20}"
    
    set_twilio_credentials "$account_name"
    
    print_info "Recordings for account: $account_name"
    local response
    response=$(twilio_api GET "/Recordings.json?PageSize=$limit")
    
    echo "$response" | jq -r '.recordings[] | "\(.date_created) | \(.sid) | \(.duration)s | \(.call_sid)"'
    return 0
}

# Get recording details
get_recording() {
    local account_name="$1"
    local recording_sid="$2"
    
    set_twilio_credentials "$account_name"
    
    print_info "Getting recording: $recording_sid"
    local response
    response=$(twilio_api GET "/Recordings/${recording_sid}.json")
    
    echo "$response" | jq -r '"SID: \(.sid)\nCall SID: \(.call_sid)\nDuration: \(.duration)s\nDate: \(.date_created)\nStatus: \(.status)"'
    
    echo ""
    echo "Download URL: https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Recordings/${recording_sid}.mp3"
    return 0
}

# Download recording
download_recording() {
    local account_name="$1"
    local recording_sid="$2"
    local output_dir="${3:-.}"
    
    set_twilio_credentials "$account_name"
    
    local url="https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Recordings/${recording_sid}.mp3"
    local output_file="${output_dir}/${recording_sid}.mp3"
    
    print_info "Downloading recording to: $output_file"
    curl -s -o "$output_file" -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" "$url"
    
    if [[ -f "$output_file" ]]; then
        print_success "Recording downloaded: $output_file"
    else
        print_error "Failed to download recording"
    fi
    return 0
}

# List transcriptions
list_transcriptions() {
    local account_name="$1"
    local limit="${2:-20}"
    
    set_twilio_credentials "$account_name"
    
    print_info "Transcriptions for account: $account_name"
    local response
    response=$(twilio_api GET "/Transcriptions.json?PageSize=$limit")
    
    echo "$response" | jq -r '.transcriptions[] | "\(.date_created) | \(.sid) | \(.status) | \(.recording_sid)"'
    return 0
}

# Get transcription
get_transcription() {
    local account_name="$1"
    local transcription_sid="$2"
    
    set_twilio_credentials "$account_name"
    
    print_info "Getting transcription: $transcription_sid"
    local response
    response=$(twilio_api GET "/Transcriptions/${transcription_sid}.json")
    
    echo "$response" | jq -r '"SID: \(.sid)\nRecording SID: \(.recording_sid)\nStatus: \(.status)\nDate: \(.date_created)\n\nTranscription:\n\(.transcription_text)"'
    return 0
}

# Send WhatsApp message
send_whatsapp() {
    local account_name="$1"
    local to="$2"
    local body="$3"
    local from="${4:-}"
    
    set_twilio_credentials "$account_name"
    
    # WhatsApp numbers need whatsapp: prefix
    if [[ ! "$to" =~ ^whatsapp: ]]; then
        to="whatsapp:$to"
    fi
    
    if [[ -z "$from" ]]; then
        # Get WhatsApp sender from config
        from=$(jq -r ".accounts.\"$account_name\".whatsapp_from // empty" "$CONFIG_FILE")
    fi
    
    if [[ -z "$from" ]]; then
        print_error "No WhatsApp sender configured for account '$account_name'"
        return 1
    fi
    
    if [[ ! "$from" =~ ^whatsapp: ]]; then
        from="whatsapp:$from"
    fi
    
    print_info "Sending WhatsApp message from $from to $to"
    
    local response
    response=$(twilio_api POST "/Messages.json" \
        -d "To=$to" \
        -d "From=$from" \
        -d "Body=$body")
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "WhatsApp message sent successfully!"
        echo "$response" | jq -r '"SID: \(.sid)\nStatus: \(.status)"'
    else
        print_error "Failed to send WhatsApp message"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# Lookup phone number
lookup_number() {
    local account_name="$1"
    local phone_number="$2"
    local lookup_type="${3:-}"
    
    set_twilio_credentials "$account_name"
    
    local url="https://lookups.twilio.com/v1/PhoneNumbers/${phone_number}"
    
    if [[ -n "$lookup_type" ]]; then
        url="${url}?Type=${lookup_type}"
    fi
    
    print_info "Looking up: $phone_number"
    local response
    response=$(curl -s -X GET "$url" -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}")
    
    echo "$response" | jq '.'
    return 0
}

# Verify - Create service
verify_create_service() {
    local account_name="$1"
    local friendly_name="$2"
    
    set_twilio_credentials "$account_name"
    
    print_info "Creating Verify service: $friendly_name"
    
    local response
    response=$(curl -s -X POST "https://verify.twilio.com/v2/Services" \
        -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
        -d "FriendlyName=$friendly_name")
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "Verify service created!"
        echo "$response" | jq -r '"SID: \(.sid)\nName: \(.friendly_name)"'
        print_info "Save this SID in your config as 'verify_service_sid'"
    else
        print_error "Failed to create Verify service"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# Verify - Send code
verify_send() {
    local account_name="$1"
    local to="$2"
    local channel="${3:-sms}"
    
    set_twilio_credentials "$account_name"
    
    local service_sid
    service_sid=$(jq -r ".accounts.\"$account_name\".verify_service_sid // empty" "$CONFIG_FILE")
    
    if [[ -z "$service_sid" ]]; then
        print_error "No Verify service SID configured for account '$account_name'"
        print_info "Create one with: $0 verify-create-service $account_name \"Service Name\""
        return 1
    fi
    
    print_info "Sending verification code to $to via $channel"
    
    local response
    response=$(curl -s -X POST "https://verify.twilio.com/v2/Services/${service_sid}/Verifications" \
        -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
        -d "To=$to" \
        -d "Channel=$channel")
    
    if echo "$response" | jq -e '.sid' > /dev/null 2>&1; then
        print_success "Verification code sent!"
        echo "$response" | jq -r '"Status: \(.status)\nChannel: \(.channel)\nTo: \(.to)"'
    else
        print_error "Failed to send verification code"
        echo "$response" | jq -r '.message // .'
    fi
    return 0
}

# Verify - Check code
verify_check() {
    local account_name="$1"
    local to="$2"
    local code="$3"
    
    set_twilio_credentials "$account_name"
    
    local service_sid
    service_sid=$(jq -r ".accounts.\"$account_name\".verify_service_sid // empty" "$CONFIG_FILE")
    
    if [[ -z "$service_sid" ]]; then
        print_error "No Verify service SID configured for account '$account_name'"
        return 1
    fi
    
    print_info "Checking verification code for $to"
    
    local response
    response=$(curl -s -X POST "https://verify.twilio.com/v2/Services/${service_sid}/VerificationCheck" \
        -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
        -d "To=$to" \
        -d "Code=$code")
    
    local status
    status=$(echo "$response" | jq -r '.status')
    
    if [[ "$status" == "approved" ]]; then
        print_success "Verification successful!"
    else
        print_error "Verification failed"
    fi
    
    echo "$response" | jq -r '"Status: \(.status)\nTo: \(.to)\nValid: \(.valid)"'
    return 0
}

# Get usage summary
get_usage() {
    local account_name="$1"
    local period="${2:-today}"
    
    set_twilio_credentials "$account_name"
    
    local start_date end_date
    case "$period" in
        today)
            start_date=$(date +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)
            ;;
        week)
            start_date=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)
            ;;
        month)
            start_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d "30 days ago" +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)
            ;;
        *)
            start_date="$period"
            end_date=$(date +%Y-%m-%d)
            ;;
    esac
    
    print_info "Usage for account: $account_name ($start_date to $end_date)"
    local response
    response=$(twilio_api GET "/Usage/Records.json?StartDate=$start_date&EndDate=$end_date")
    
    echo "$response" | jq -r '.usage_records[] | select(.count != "0") | "\(.category): \(.count) (\(.price) \(.price_unit))"'
    return 0
}

# Audit account
audit_account() {
    local account_name="$1"
    set_twilio_credentials "$account_name"
    
    print_info "=== Twilio Account Audit: $account_name ==="
    echo ""
    
    print_info "Account Balance:"
    get_balance "$account_name"
    echo ""
    
    print_info "Phone Numbers:"
    list_numbers "$account_name"
    echo ""
    
    print_info "Recent Messages (last 5):"
    list_messages "$account_name" 5
    echo ""
    
    print_info "Recent Calls (last 5):"
    list_calls "$account_name" 5
    echo ""
    
    print_info "Usage Summary (this month):"
    get_usage "$account_name" month
    
    return 0
}

# Show help
show_help() {
    cat << EOF
Twilio Helper Script - Comprehensive Twilio management for AI assistants

$USAGE_COMMAND_OPTIONS

ACCOUNT COMMANDS:
  accounts                          List all configured accounts
  balance <account>                 Get account balance
  usage <account> [period]          Get usage summary (today|week|month)
  audit <account>                   Full account audit
  status <account>                  Check account status

PHONE NUMBER COMMANDS:
  numbers <account>                 List owned phone numbers
  search-numbers <account> <country> [options]
                                    Search available numbers
    --area-code <code>              Filter by area code
    --contains <digits>             Filter by containing digits
    --sms                           Must support SMS
    --voice                         Must support voice
    --mms                           Must support MMS
  buy-number <account> <number>     Purchase a phone number
  release-number <account> <number> Release a phone number

SMS COMMANDS:
  sms <account> <to> <body> [from]  Send SMS message
  messages <account> [limit]        List recent messages
  message-status <account> <sid>    Get message status

VOICE COMMANDS:
  call <account> <to> [options]     Make outbound call
    --from <number>                 From number
    --twiml <xml>                   TwiML instructions
    --url <url>                     TwiML URL
    --record                        Record the call
  calls <account> [limit]           List recent calls
  call-details <account> <sid>      Get call details

RECORDING COMMANDS:
  recordings <account> [limit]      List recordings
  recording <account> <sid>         Get recording details
  download-recording <account> <sid> [dir]
                                    Download recording MP3

TRANSCRIPTION COMMANDS:
  transcriptions <account> [limit]  List transcriptions
  transcription <account> <sid>     Get transcription text

WHATSAPP COMMANDS:
  whatsapp <account> <to> <body>    Send WhatsApp message

VERIFY (2FA) COMMANDS:
  verify-create-service <account> <name>
                                    Create Verify service
  verify-send <account> <to> [channel]
                                    Send verification code (sms|call|email)
  verify-check <account> <to> <code>
                                    Check verification code

LOOKUP COMMANDS:
  lookup <account> <number> [type]  Lookup phone number info
                                    Types: carrier, caller-name

EXAMPLES:
  $0 accounts
  $0 sms production "+1234567890" "Hello!"
  $0 search-numbers production US --area-code 415 --sms
  $0 call production "+1234567890" --record
  $0 verify-send production "+1234567890" sms
  $0 audit production

CONFIGURATION:
  Config file: configs/twilio-config.json
  Template: configs/twilio-config.json.txt

For more information, see: .agents/services/communications/twilio.md
EOF
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local account_name="${2:-}"
    shift 2 2>/dev/null || true
    
    check_dependencies
    load_config
    
    case "$command" in
        "accounts")
            list_accounts
            ;;
        "balance")
            get_balance "$account_name"
            ;;
        "numbers")
            list_numbers "$account_name"
            ;;
        "search-numbers")
            local country="$1"
            shift
            search_numbers "$account_name" "$country" "$@"
            ;;
        "buy-number")
            buy_number "$account_name" "$1"
            ;;
        "sms")
            send_sms "$account_name" "$1" "$2" "${3:-}"
            ;;
        "messages")
            list_messages "$account_name" "${1:-20}"
            ;;
        "message-status")
            get_message_status "$account_name" "$1"
            ;;
        "call")
            make_call "$account_name" "$1" "${@:2}"
            ;;
        "calls")
            list_calls "$account_name" "${1:-20}"
            ;;
        "recordings")
            list_recordings "$account_name" "${1:-20}"
            ;;
        "recording")
            get_recording "$account_name" "$1"
            ;;
        "download-recording")
            download_recording "$account_name" "$1" "${2:-.}"
            ;;
        "transcriptions")
            list_transcriptions "$account_name" "${1:-20}"
            ;;
        "transcription")
            get_transcription "$account_name" "$1"
            ;;
        "whatsapp")
            send_whatsapp "$account_name" "$1" "$2"
            ;;
        "lookup")
            lookup_number "$account_name" "$1" "${2:-}"
            ;;
        "verify-create-service")
            verify_create_service "$account_name" "$1"
            ;;
        "verify-send")
            verify_send "$account_name" "$1" "${2:-sms}"
            ;;
        "verify-check")
            verify_check "$account_name" "$1" "$2"
            ;;
        "usage")
            get_usage "$account_name" "${1:-today}"
            ;;
        "audit")
            audit_account "$account_name"
            ;;
        "status")
            get_balance "$account_name"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
