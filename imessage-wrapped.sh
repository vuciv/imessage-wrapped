#!/bin/bash

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║            iMessage Wrapped - Universal Generator                          ║
# ║            Generate a Spotify Wrapped-style HTML for:                      ║
# ║            - Individual contacts                                           ║
# ║            - Group chats                                                   ║
# ║            - ALL your messages combined                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Database paths
IMESSAGE_DB="$HOME/Library/Messages/chat.db"
ADDRESSBOOK_DB=$(find "$HOME/Library/Application Support/AddressBook" -name "AddressBook-v22.abcddb" 2>/dev/null | head -1)

# Default year (can be overridden with --year)
YEAR=2025

# Function to calculate Apple timestamps for a given year
# Apple's epoch is 2001-01-01 00:00:00 UTC
calculate_timestamps() {
    local year=$1
    # Calculate seconds from Unix epoch (1970) to Apple epoch (2001)
    local apple_epoch_offset=978307200
    # Calculate start of year in Unix time, then convert to Apple time
    START_TIMESTAMP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$year-01-01 00:00:00" "+%s" 2>/dev/null)
    END_TIMESTAMP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$((year + 1))-01-01 00:00:00" "+%s" 2>/dev/null)
    # Convert to Apple timestamps
    START_YEAR=$((START_TIMESTAMP - apple_epoch_offset))
    END_YEAR=$((END_TIMESTAMP - apple_epoch_offset))
}

usage() {
    echo ""
    echo -e "${CYAN}${BOLD}iMessage Wrapped Generator${NC}"
    echo ""
    echo "Usage: $0 [OPTIONS] <target>"
    echo ""
    echo "Target types:"
    echo "  <phone/email>     Phone number or email for individual contact"
    echo "  <contact name>    Contact name to search (fuzzy match)"
    echo "  --group <name>    Group chat name (fuzzy match)"
    echo "  --all             Generate wrapped for ALL your messages"
    echo ""
    echo "Options:"
    echo "  -o, --output FILE    Output HTML file"
    echo "  -n, --name NAME      Display name for the contact/group"
    echo "  -y, --your-name NAME Your name to display (default: 'You')"
    echo "  --year YEAR          Year to generate wrapped for (default: 2025)"
    echo "  --privacy            Hide phone numbers/emails (use first names only)"
    echo "  --list-groups        List all group chats"
    echo "  --list-contacts      List top contacts by message count"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 '+15551234567'                    # Individual by phone"
    echo "  $0 -n 'Helen' '+15551234567'         # Individual with display name"
    echo "  $0 --group 'movie club'              # Group chat (fuzzy match)"
    echo "  $0 --group 'rowers' -n 'Austin Rowers'"
    echo "  $0 --all                             # All messages wrapped"
    echo "  $0 --year 2024 --all                 # All messages from 2024"
    echo "  $0 --list-groups                     # See all group chats"
    echo ""
    exit 1
}

# Parse arguments
OUTPUT_FILE=""
CONTACT_NAME=""
YOUR_NAME="You"
TARGET=""
MODE="individual"  # individual, group, all
LIST_GROUPS=false
LIST_CONTACTS=false
PRIVACY_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -n|--name)
            CONTACT_NAME="$2"
            shift 2
            ;;
        -y|--your-name)
            YOUR_NAME="$2"
            shift 2
            ;;
        --group)
            MODE="group"
            TARGET="$2"
            shift 2
            ;;
        --all)
            MODE="all"
            shift
            ;;
        --list-groups)
            LIST_GROUPS=true
            shift
            ;;
        --list-contacts)
            LIST_CONTACTS=true
            shift
            ;;
        --year)
            YEAR="$2"
            shift 2
            ;;
        --privacy)
            PRIVACY_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

# Calculate timestamps for the selected year
calculate_timestamps $YEAR

# Check if database exists
if [ ! -f "$IMESSAGE_DB" ]; then
    echo -e "${RED}Error: iMessage database not found at $IMESSAGE_DB${NC}"
    echo "Make sure you're running this on macOS with iMessage set up."
    exit 1
fi

# Check for Full Disk Access
if ! sqlite3 "$IMESSAGE_DB" "SELECT 1 LIMIT 1" 2>/dev/null; then
    echo -e "${RED}Error: Cannot access iMessage database.${NC}"
    echo ""
    echo "Please grant Full Disk Access to your terminal app:"
    echo "1. Open System Settings > Privacy & Security > Full Disk Access"
    echo "2. Click the + button and add your terminal app"
    echo "3. Restart your terminal and run this script again"
    exit 1
fi

# Create temp files
CONTACT_CACHE=$(mktemp)

# Build contact lookup
echo -e "${DIM}Building contact lookup...${NC}"
if [ -n "$ADDRESSBOOK_DB" ]; then
    sqlite3 "$ADDRESSBOOK_DB" "
        SELECT
            COALESCE(ZFIRSTNAME, '') || ' ' || COALESCE(ZLASTNAME, ''),
            REPLACE(REPLACE(REPLACE(REPLACE(ZFULLNUMBER, ' ', ''), '-', ''), '(', ''), ')', '')
        FROM ZABCDRECORD
        LEFT JOIN ZABCDPHONENUMBER ON ZABCDRECORD.Z_PK = ZABCDPHONENUMBER.ZOWNER
        WHERE ZFULLNUMBER IS NOT NULL
        UNION
        SELECT
            COALESCE(ZFIRSTNAME, '') || ' ' || COALESCE(ZLASTNAME, ''),
            LOWER(ZADDRESS)
        FROM ZABCDRECORD
        LEFT JOIN ZABCDEMAILADDRESS ON ZABCDRECORD.Z_PK = ZABCDEMAILADDRESS.ZOWNER
        WHERE ZADDRESS IS NOT NULL;
    " 2>/dev/null | while IFS='|' read -r name identifier; do
        echo "$name|$identifier"
    done > "$CONTACT_CACHE"
fi

# Temp file for anonymous user mapping in privacy mode
ANON_MAP_FILE=$(mktemp)
ANON_COUNTER_FILE=$(mktemp)
echo "0" > "$ANON_COUNTER_FILE"
trap "rm -f $CONTACT_CACHE $ANON_MAP_FILE $ANON_COUNTER_FILE" EXIT

# Function to get contact name from handle
get_contact_name() {
    local handle="$1"
    local normalized=$(echo "$handle" | tr -cd '0-9' | sed 's/^1//')
    local match=""

    if [ ${#normalized} -ge 10 ]; then
        local last10="${normalized: -10}"
        match=$(grep "$last10" "$CONTACT_CACHE" 2>/dev/null | head -1 | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    if [ -z "$match" ] || [ "$match" = " " ]; then
        match=$(grep -i "$handle" "$CONTACT_CACHE" 2>/dev/null | head -1 | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    if [ -n "$match" ] && [ "$match" != " " ]; then
        if [ "$PRIVACY_MODE" = true ]; then
            # Return only first name in privacy mode
            echo "$match" | awk '{print $1}'
        else
            echo "$match"
        fi
    else
        if [ "$PRIVACY_MODE" = true ]; then
            # Return consistent anonymous name for each handle using temp file
            local existing=$(grep "^${handle}|" "$ANON_MAP_FILE" 2>/dev/null | cut -d'|' -f2)
            if [ -n "$existing" ]; then
                echo "$existing"
            else
                local counter=$(cat "$ANON_COUNTER_FILE")
                counter=$((counter + 1))
                echo "$counter" > "$ANON_COUNTER_FILE"
                echo "${handle}|Friend ${counter}" >> "$ANON_MAP_FILE"
                echo "Friend ${counter}"
            fi
        else
            # Return truncated handle
            if [ ${#handle} -gt 15 ]; then
                echo "...${handle: -10}"
            else
                echo "$handle"
            fi
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# LIST MODE: Show groups or contacts
# ═══════════════════════════════════════════════════════════════════════════

if [ "$LIST_GROUPS" = true ]; then
    echo ""
    echo -e "${CYAN}${BOLD}Group Chats in $YEAR:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    sqlite3 "$IMESSAGE_DB" "
        SELECT
            c.chat_identifier,
            c.display_name,
            COUNT(m.ROWID) as cnt
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        WHERE c.chat_identifier LIKE 'chat%'
          AND m.date/1000000000 >= $START_YEAR
          AND m.date/1000000000 < $END_YEAR
        GROUP BY c.chat_identifier
        HAVING cnt > 10
        ORDER BY cnt DESC
        LIMIT 30;
    " | while IFS='|' read -r chat_id display_name count; do
        if [ -n "$display_name" ]; then
            printf "  ${GREEN}%-40s${NC} %6s messages\n" "$display_name" "$count"
        else
            printf "  ${DIM}%-40s${NC} %6s messages\n" "${chat_id:0:40}" "$count"
        fi
    done

    echo ""
    echo -e "${DIM}Use: $0 --group '<name>' to generate wrapped${NC}"
    exit 0
fi

if [ "$LIST_CONTACTS" = true ]; then
    echo ""
    echo -e "${CYAN}${BOLD}Top Contacts in $YEAR:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    sqlite3 "$IMESSAGE_DB" "
        SELECT
            h.id,
            COUNT(m.ROWID) as cnt
        FROM handle h
        JOIN message m ON m.handle_id = h.ROWID
        WHERE m.date/1000000000 >= $START_YEAR
          AND m.date/1000000000 < $END_YEAR
        GROUP BY h.id
        HAVING cnt > 50
        ORDER BY cnt DESC
        LIMIT 30;
    " | while IFS='|' read -r handle count; do
        name=$(get_contact_name "$handle")
        printf "  ${GREEN}%-30s${NC} ${DIM}%-25s${NC} %6s\n" "$name" "$handle" "$count"
    done

    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# DETERMINE TARGET AND BUILD SQL
# ═══════════════════════════════════════════════════════════════════════════

WHERE_CLAUSE=""
TITLE=""

if [ "$MODE" = "all" ]; then
    echo -e "${CYAN}${BOLD}Generating wrapped for ALL your messages!${NC}"
    WHERE_CLAUSE="m.date/1000000000 >= $START_YEAR AND m.date/1000000000 < $END_YEAR"
    TITLE="Your iMessage"
    CONTACT_NAME="${CONTACT_NAME:-Everyone}"
    OUTPUT_FILE="${OUTPUT_FILE:-imessage-wrapped-${YEAR}.html}"

elif [ "$MODE" = "group" ]; then
    if [ -z "$TARGET" ]; then
        echo -e "${RED}Error: Group name required with --group${NC}"
        usage
    fi

    echo -e "${CYAN}Searching for group chat matching: ${BOLD}$TARGET${NC}"

    # Fuzzy match on display_name or chat_identifier
    CHAT_MATCHES=$(sqlite3 "$IMESSAGE_DB" "
        SELECT
            c.chat_identifier,
            c.display_name,
            COUNT(m.ROWID) as cnt
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        WHERE c.chat_identifier LIKE 'chat%'
          AND m.date/1000000000 >= $START_YEAR
          AND m.date/1000000000 < $END_YEAR
          AND (LOWER(c.display_name) LIKE '%$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')%'
               OR LOWER(c.chat_identifier) LIKE '%$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')%')
        GROUP BY c.chat_identifier
        ORDER BY cnt DESC;
    ")

    if [ -z "$CHAT_MATCHES" ]; then
        echo -e "${RED}No group chats found matching '$TARGET'${NC}"
        echo ""
        echo "Try --list-groups to see available group chats"
        exit 1
    fi

    # If multiple matches, show them
    MATCH_COUNT=$(echo "$CHAT_MATCHES" | wc -l | tr -d ' ')
    if [ "$MATCH_COUNT" -gt 1 ]; then
        echo -e "${YELLOW}Found multiple matches:${NC}"
        echo "$CHAT_MATCHES" | head -5 | while IFS='|' read -r cid dname cnt; do
            echo "  - ${dname:-$cid} ($cnt messages)"
        done
        echo ""
        echo -e "${DIM}Using the first match with most messages${NC}"
    fi

    CHAT_ID=$(echo "$CHAT_MATCHES" | head -1 | cut -d'|' -f1)
    DISPLAY_NAME=$(echo "$CHAT_MATCHES" | head -1 | cut -d'|' -f2)

    echo -e "${GREEN}Found: ${DISPLAY_NAME:-$CHAT_ID}${NC}"

    WHERE_CLAUSE="c.chat_identifier = '$CHAT_ID' AND m.date/1000000000 >= $START_YEAR AND m.date/1000000000 < $END_YEAR"
    TITLE="${CONTACT_NAME:-${DISPLAY_NAME:-Group Chat}}"
    CONTACT_NAME="${CONTACT_NAME:-${DISPLAY_NAME:-Group Chat}}"

    SAFE_NAME=$(echo "$CONTACT_NAME" | tr ' ' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
    OUTPUT_FILE="${OUTPUT_FILE:-${SAFE_NAME}-wrapped-${YEAR}.html}"

else
    # Individual mode
    if [ -z "$TARGET" ]; then
        echo -e "${RED}Error: Contact identifier required${NC}"
        usage
    fi

    echo -e "${CYAN}Looking up contact: ${BOLD}$TARGET${NC}"

    # Check if it's a phone number or email
    if [[ "$TARGET" =~ ^[+0-9] ]] || [[ "$TARGET" =~ @ ]]; then
        # Direct identifier
        HANDLE_IDS=$(sqlite3 "$IMESSAGE_DB" "
            SELECT id FROM handle WHERE id LIKE '%$(echo "$TARGET" | sed "s/+/%/g")%';
        " 2>/dev/null)
    else
        # It's a name - search the contact cache (fuzzy)
        CONTACT_IDENTIFIER=$(grep -i "$TARGET" "$CONTACT_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
        if [ -n "$CONTACT_IDENTIFIER" ]; then
            HANDLE_IDS=$(sqlite3 "$IMESSAGE_DB" "
                SELECT id FROM handle WHERE id LIKE '%$CONTACT_IDENTIFIER%';
            " 2>/dev/null)
        fi
    fi

    if [ -z "$HANDLE_IDS" ]; then
        echo -e "${RED}Error: Could not find messages with '$TARGET'${NC}"
        echo ""
        echo "Try:"
        echo "  - Using a phone number format: +15551234567"
        echo "  - $0 --list-contacts to see top contacts"
        exit 1
    fi

    HANDLE_SQL=$(echo "$HANDLE_IDS" | while read -r hid; do echo "'$hid'"; done | tr '\n' ',' | sed 's/,$//')

    echo -e "${GREEN}Found handle(s): $(echo "$HANDLE_IDS" | head -1)${NC}"

    # Get contact name if not provided
    if [ -z "$CONTACT_NAME" ]; then
        FIRST_HANDLE=$(echo "$HANDLE_IDS" | head -1)
        CONTACT_NAME=$(get_contact_name "$FIRST_HANDLE")
    fi

    WHERE_CLAUSE="h.id IN ($HANDLE_SQL) AND m.date/1000000000 >= $START_YEAR AND m.date/1000000000 < $END_YEAR"
    TITLE="$YOUR_NAME & $CONTACT_NAME"

    SAFE_NAME=$(echo "$CONTACT_NAME" | tr ' ' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
    YOUR_NAME_LOWER=$(echo "$YOUR_NAME" | tr '[:upper:]' '[:lower:]')
    OUTPUT_FILE="${OUTPUT_FILE:-${YOUR_NAME_LOWER}-${SAFE_NAME}-wrapped-${YEAR}.html}"
fi

echo -e "${CYAN}${BOLD}Generating wrapped for: $TITLE${NC}"
if [ "$PRIVACY_MODE" = true ]; then
    echo -e "${YELLOW}Privacy mode enabled - phone numbers and last names will be hidden${NC}"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# GATHER ALL STATISTICS
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${DIM}Gathering statistics...${NC}"

# Build the base query depending on mode
if [ "$MODE" = "group" ]; then
    BASE_FROM="FROM message m JOIN chat_message_join cmj ON m.ROWID = cmj.message_id JOIN chat c ON cmj.chat_id = c.ROWID"
elif [ "$MODE" = "all" ]; then
    BASE_FROM="FROM message m"
else
    BASE_FROM="FROM message m JOIN handle h ON m.handle_id = h.ROWID"
fi

# Total messages
TOTAL_MESSAGES=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE;")

if [ "$TOTAL_MESSAGES" -eq 0 ]; then
    echo -e "${RED}No messages found for this target in $YEAR!${NC}"
    exit 1
fi

# Messages sent by you
YOUR_MESSAGES=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.is_from_me = 1;")

# Messages received
THEIR_MESSAGES=$((TOTAL_MESSAGES - YOUR_MESSAGES))

# Calculate percentages and averages
YOUR_PERCENT=$(echo "scale=1; $YOUR_MESSAGES * 100 / $TOTAL_MESSAGES" | bc)
THEIR_PERCENT=$(echo "scale=1; $THEIR_MESSAGES * 100 / $TOTAL_MESSAGES" | bc)
DAILY_AVG=$(echo "scale=1; $TOTAL_MESSAGES / 365" | bc)

# Peak hour
PEAK_HOUR_DATA=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        CAST(strftime('%H', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) AS INTEGER) as hour,
        COUNT(*) as cnt
    $BASE_FROM
    WHERE $WHERE_CLAUSE
    GROUP BY hour
    ORDER BY cnt DESC
    LIMIT 1;
")
PEAK_HOUR=$(echo "$PEAK_HOUR_DATA" | cut -d'|' -f1)
PEAK_HOUR_COUNT=$(echo "$PEAK_HOUR_DATA" | cut -d'|' -f2)

# Format peak hour
if [ "$PEAK_HOUR" -eq 0 ]; then
    PEAK_HOUR_FMT="12 AM"
elif [ "$PEAK_HOUR" -lt 12 ]; then
    PEAK_HOUR_FMT="${PEAK_HOUR} AM"
elif [ "$PEAK_HOUR" -eq 12 ]; then
    PEAK_HOUR_FMT="12 PM"
else
    PEAK_HOUR_FMT="$((PEAK_HOUR - 12)) PM"
fi

# Reactions
LOVED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2000;")
LIKED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2001;")
DISLIKED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2002;")
LAUGHED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2003;")
EMPHASIZED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2004;")
QUESTIONED=$(sqlite3 "$IMESSAGE_DB" "SELECT COUNT(*) $BASE_FROM WHERE $WHERE_CLAUSE AND m.associated_message_type = 2005;")
TOTAL_REACTIONS=$((LOVED + LIKED + DISLIKED + LAUGHED + EMPHASIZED + QUESTIONED))

# Late night messages (1-5 AM)
YOUR_LATE=$(sqlite3 "$IMESSAGE_DB" "
    SELECT COUNT(*) $BASE_FROM
    WHERE $WHERE_CLAUSE AND m.is_from_me = 1
    AND CAST(strftime('%H', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) AS INTEGER) BETWEEN 1 AND 5;
")
THEIR_LATE=$(sqlite3 "$IMESSAGE_DB" "
    SELECT COUNT(*) $BASE_FROM
    WHERE $WHERE_CLAUSE AND m.is_from_me = 0
    AND CAST(strftime('%H', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) AS INTEGER) BETWEEN 1 AND 5;
")
TOTAL_LATE=$((YOUR_LATE + THEIR_LATE))

# Busiest day
BUSIEST_DAY_DATA=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        date(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') as day,
        COUNT(*) as cnt
    $BASE_FROM
    WHERE $WHERE_CLAUSE
    GROUP BY day
    ORDER BY cnt DESC
    LIMIT 1;
")
BUSIEST_DATE=$(echo "$BUSIEST_DAY_DATA" | cut -d'|' -f1)
BUSIEST_COUNT=$(echo "$BUSIEST_DAY_DATA" | cut -d'|' -f2)
BUSIEST_DATE_FMT=$(date -j -f "%Y-%m-%d" "$BUSIEST_DATE" "+%B %d" 2>/dev/null || echo "$BUSIEST_DATE")

# Monthly breakdown
MONTHLY_DATA=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        CAST(strftime('%m', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) AS INTEGER) as month,
        COUNT(*) as cnt
    $BASE_FROM
    WHERE $WHERE_CLAUSE
    GROUP BY month
    ORDER BY month;
")
MAX_MONTH_COUNT=$(echo "$MONTHLY_DATA" | cut -d'|' -f2 | sort -nr | head -1)
MAX_MONTH=$(echo "$MONTHLY_DATA" | sort -t'|' -k2 -nr | head -1 | cut -d'|' -f1)
MONTH_NAMES_FULL=("" "January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")
PEAK_MONTH_NAME="${MONTH_NAMES_FULL[$MAX_MONTH]}"

# Day of week
DOW_DATA=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        CAST(strftime('%w', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) AS INTEGER) as dow,
        COUNT(*) as cnt
    $BASE_FROM
    WHERE $WHERE_CLAUSE
    GROUP BY dow
    ORDER BY cnt DESC
    LIMIT 1;
")
BUSIEST_DOW=$(echo "$DOW_DATA" | cut -d'|' -f1)
BUSIEST_DOW_COUNT=$(echo "$DOW_DATA" | cut -d'|' -f2)
DAYS=("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")
BUSIEST_DAY_NAME="${DAYS[$BUSIEST_DOW]}"

# Top talkers (for group/all mode)
if [ "$MODE" = "group" ] || [ "$MODE" = "all" ]; then
    TOP_TALKERS=$(sqlite3 "$IMESSAGE_DB" "
        SELECT
            CASE WHEN m.is_from_me = 1 THEN 'YOU' ELSE h.id END as person,
            COUNT(*) as cnt
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        $([ "$MODE" = "group" ] && echo "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id JOIN chat c ON cmj.chat_id = c.ROWID")
        WHERE $WHERE_CLAUSE
        GROUP BY person
        ORDER BY cnt DESC
        LIMIT 10;
    ")
fi

# Top laugh react receivers (for group mode)
if [ "$MODE" = "group" ]; then
    # Find who received the most laugh reacts
    # Laugh reacts have associated_message_type = 2003
    # The associated_message_guid has prefixes like "p:0/" or "bp:" that need to be stripped
    TOP_LAUGH_RECEIVERS=$(sqlite3 "$IMESSAGE_DB" "
        SELECT
            CASE WHEN orig.is_from_me = 1 THEN 'YOU' ELSE h.id END as person,
            COUNT(*) as cnt
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN chat c ON cmj.chat_id = c.ROWID
        JOIN message orig ON orig.guid = SUBSTR(m.associated_message_guid, INSTR(m.associated_message_guid, ':') + 3)
                          OR orig.guid = SUBSTR(m.associated_message_guid, INSTR(m.associated_message_guid, ':') + 1)
                          OR orig.guid = m.associated_message_guid
        LEFT JOIN handle h ON orig.handle_id = h.ROWID
        WHERE c.chat_identifier = '$CHAT_ID'
          AND m.date/1000000000 >= $START_YEAR
          AND m.date/1000000000 < $END_YEAR
          AND m.associated_message_type = 2003
        GROUP BY person
        ORDER BY cnt DESC
        LIMIT 5;
    ")

fi

# Sample messages
SWEET_MESSAGES=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        m.is_from_me,
        REPLACE(REPLACE(m.text, '\"', ''), \"'\", '')
    $BASE_FROM
    WHERE $WHERE_CLAUSE
      AND m.text IS NOT NULL
      AND (LOWER(m.text) LIKE '%love you%' OR LOWER(m.text) LIKE '%miss you%' OR LOWER(m.text) LIKE '%thank you%')
      AND LENGTH(m.text) < 100
    ORDER BY RANDOM()
    LIMIT 3;
" 2>/dev/null)

RANDOM_MESSAGES=$(sqlite3 "$IMESSAGE_DB" "
    SELECT
        m.is_from_me,
        REPLACE(REPLACE(m.text, '\"', ''), \"'\", '')
    $BASE_FROM
    WHERE $WHERE_CLAUSE
      AND m.text IS NOT NULL
      AND LENGTH(m.text) BETWEEN 15 AND 100
      AND m.text NOT LIKE '%http%'
      AND m.text NOT LIKE '%Loved%'
      AND m.text NOT LIKE '%Liked%'
      AND m.text NOT LIKE '%Laughed%'
    ORDER BY RANDOM()
    LIMIT 3;
" 2>/dev/null)

# Word counts
TOTAL_WORDS=$(sqlite3 "$IMESSAGE_DB" "
    SELECT COALESCE(SUM(LENGTH(m.text) - LENGTH(REPLACE(m.text, ' ', '')) + 1), 0)
    $BASE_FROM
    WHERE $WHERE_CLAUSE AND m.text IS NOT NULL AND LENGTH(m.text) > 0;
")
TOTAL_WORDS=${TOTAL_WORDS:-0}
# Handle empty result
[ -z "$TOTAL_WORDS" ] && TOTAL_WORDS=0

# Photo count (attachments)
PHOTO_COUNT=$(sqlite3 "$IMESSAGE_DB" "
    SELECT COUNT(DISTINCT a.ROWID)
    FROM message m
    JOIN message_attachment_join maj ON m.ROWID = maj.message_id
    JOIN attachment a ON maj.attachment_id = a.ROWID
    $([ "$MODE" = "group" ] && echo "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id JOIN chat c ON cmj.chat_id = c.ROWID")
    $([ "$MODE" = "individual" ] && echo "JOIN handle h ON m.handle_id = h.ROWID")
    WHERE $WHERE_CLAUSE
      AND (a.mime_type LIKE 'image/%' OR a.mime_type LIKE 'video/%');
")
PHOTO_COUNT=${PHOTO_COUNT:-0}

echo -e "${GREEN}Statistics gathered!${NC}"

# ═══════════════════════════════════════════════════════════════════════════
# FUN CONDITIONAL COPY
# ═══════════════════════════════════════════════════════════════════════════

# Total messages commentary
if [ "$TOTAL_MESSAGES" -gt 50000 ]; then
    TOTAL_COMMENT="You two basically share a brain at this point. This is WILD."
elif [ "$TOTAL_MESSAGES" -gt 20000 ]; then
    TOTAL_COMMENT="Okay, you're basically attached at the hip. In the best way."
elif [ "$TOTAL_MESSAGES" -gt 10000 ]; then
    TOTAL_COMMENT="That's a LOT of words. You really can't stop talking."
elif [ "$TOTAL_MESSAGES" -gt 5000 ]; then
    TOTAL_COMMENT="Solid communication game. Keep it up!"
elif [ "$TOTAL_MESSAGES" -gt 1000 ]; then
    TOTAL_COMMENT="A healthy amount of texting. Quality over quantity, right?"
else
    TOTAL_COMMENT="Quality over quantity! Every message counts."
fi

# Balance commentary
BALANCE_DIFF=$(echo "$YOUR_PERCENT - $THEIR_PERCENT" | bc | tr -d '-')
if [ "$(echo "$BALANCE_DIFF < 5" | bc)" -eq 1 ]; then
    BALANCE_COMMENT="Almost perfectly balanced. This is what healthy communication looks like."
elif [ "$(echo "$YOUR_PERCENT > $THEIR_PERCENT" | bc)" -eq 1 ]; then
    if [ "$(echo "$YOUR_PERCENT > 60" | bc)" -eq 1 ]; then
        BALANCE_COMMENT="You're carrying this conversation! Maybe give them a chance to respond? 😂"
    else
        BALANCE_COMMENT="You're slightly more chatty, but who's counting?"
    fi
else
    if [ "$(echo "$THEIR_PERCENT > 60" | bc)" -eq 1 ]; then
        BALANCE_COMMENT="They're really putting in the work! Time to step up your game."
    else
        BALANCE_COMMENT="They're slightly more talkative. Probably has more to say!"
    fi
fi

# Daily average commentary
DAILY_INT=$(echo "$DAILY_AVG" | cut -d'.' -f1)
if [ "$DAILY_INT" -gt 100 ]; then
    DAILY_COMMENT="That's a message every few MINUTES you're awake. Absolutely unhinged. We love it."
elif [ "$DAILY_INT" -gt 50 ]; then
    DAILY_COMMENT="A message every 30 minutes. The conversation never really ends."
elif [ "$DAILY_INT" -gt 20 ]; then
    DAILY_COMMENT="Keeping the connection strong, one text at a time."
elif [ "$DAILY_INT" -gt 10 ]; then
    DAILY_COMMENT="Consistent communication without overwhelming. Nice balance!"
else
    DAILY_COMMENT="Quality check-ins. Sometimes less is more."
fi

# Peak hour commentary
if [ "$PEAK_HOUR" -ge 0 ] && [ "$PEAK_HOUR" -le 5 ]; then
    PEAK_COMMENT="NIGHT OWLS! Go to bed, you two!"
elif [ "$PEAK_HOUR" -ge 6 ] && [ "$PEAK_HOUR" -le 9 ]; then
    PEAK_COMMENT="Morning people! Starting the day with texts."
elif [ "$PEAK_HOUR" -ge 10 ] && [ "$PEAK_HOUR" -le 12 ]; then
    PEAK_COMMENT="Late morning vibes. Coffee and conversation."
elif [ "$PEAK_HOUR" -ge 13 ] && [ "$PEAK_HOUR" -le 16 ]; then
    PEAK_COMMENT="Afternoon texters. Taking breaks from work, huh?"
elif [ "$PEAK_HOUR" -ge 17 ] && [ "$PEAK_HOUR" -le 19 ]; then
    PEAK_COMMENT="End of work day = time to catch up. Priorities: correct."
elif [ "$PEAK_HOUR" -ge 20 ] && [ "$PEAK_HOUR" -le 23 ]; then
    PEAK_COMMENT="Evening conversationalists. Winding down with texts."
fi

# Late night commentary
if [ "$TOTAL_LATE" -gt 500 ]; then
    LATE_COMMENT="PLEASE GO TO SLEEP. This is concerning levels of late-night texting. (But also kind of sweet.)"
elif [ "$TOTAL_LATE" -gt 100 ]; then
    LATE_COMMENT="Definitely some late night heart-to-hearts happening. Sleep is for the weak!"
elif [ "$TOTAL_LATE" -gt 50 ]; then
    LATE_COMMENT="A few late night conversations. Those are usually the best ones."
elif [ "$TOTAL_LATE" -gt 10 ]; then
    LATE_COMMENT="Mostly responsible texters. Only occasional late-night vibes."
else
    LATE_COMMENT="You actually sleep! How responsible."
fi

# Reactions commentary
if [ "$LOVED" -gt 500 ]; then
    REACTIONS_COMMENT="$LOVED hearts?! You're DISGUSTINGLY cute. Don't ever change."
elif [ "$LOVED" -gt 100 ]; then
    REACTIONS_COMMENT="$LOVED hearts. The love is real."
elif [ "$LAUGHED" -gt "$LOVED" ]; then
    REACTIONS_COMMENT="More laughs than hearts. This must be a fun conversation!"
else
    REACTIONS_COMMENT="Every reaction is a little burst of feeling. Keep 'em coming!"
fi

# Busiest day commentary
if [ "$BUSIEST_COUNT" -gt 500 ]; then
    BUSIEST_COMMENT="FIVE HUNDRED messages in one day?! What happened?? We need details."
elif [ "$BUSIEST_COUNT" -gt 300 ]; then
    BUSIEST_COMMENT="Over 300 messages! That's a message every 3 minutes. Wild day."
elif [ "$BUSIEST_COUNT" -gt 150 ]; then
    BUSIEST_COMMENT="Something big must have happened. Or you just really missed each other."
else
    BUSIEST_COMMENT="A solid day of conversation!"
fi

# Day of week commentary
case "$BUSIEST_DAY_NAME" in
    "Monday")
        DOW_COMMENT="Mondays are better when you have someone to complain to."
        ;;
    "Tuesday")
        DOW_COMMENT="Tuesday just hits different when you have good company."
        ;;
    "Wednesday")
        DOW_COMMENT="Hump day is for texting, apparently!"
        ;;
    "Thursday")
        DOW_COMMENT="Almost Friday energy = lots of texts."
        ;;
    "Friday")
        DOW_COMMENT="TGIF! Time to text about weekend plans."
        ;;
    "Saturday")
        DOW_COMMENT="Weekend vibes = max texting mode."
        ;;
    "Sunday")
        DOW_COMMENT="Sunday Funday? More like Sunday Text-day."
        ;;
esac

echo ""
echo "  Total messages: $(printf "%'d" $TOTAL_MESSAGES)"
echo "  Your messages: $(printf "%'d" $YOUR_MESSAGES) ($YOUR_PERCENT%)"
echo "  Their messages: $(printf "%'d" $THEIR_MESSAGES) ($THEIR_PERCENT%)"
echo "  Daily average: $DAILY_AVG"
echo "  Peak hour: $PEAK_HOUR_FMT ($PEAK_HOUR_COUNT messages)"
echo "  Total reactions: $(printf "%'d" $TOTAL_REACTIONS)"
echo "  Late night texts: $TOTAL_LATE"
echo "  Busiest day: $BUSIEST_DATE_FMT ($BUSIEST_COUNT messages)"
echo "  Photos/videos shared: $(printf "%'d" $PHOTO_COUNT)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# GENERATE HTML
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}Generating HTML...${NC}"

# Build month chart bars
MONTH_NAMES=("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
MONTH_BARS=""
for i in {1..12}; do
    COUNT=$(echo "$MONTHLY_DATA" | grep "^$i|" | cut -d'|' -f2)
    COUNT=${COUNT:-0}
    if [ "$MAX_MONTH_COUNT" -gt 0 ]; then
        HEIGHT=$(echo "scale=0; $COUNT * 100 / $MAX_MONTH_COUNT" | bc)
    else
        HEIGHT=0
    fi
    [ "$HEIGHT" -lt 3 ] && [ "$COUNT" -gt 0 ] && HEIGHT=3
    MONTH_BARS="$MONTH_BARS<div class=\"chart-bar\" style=\"height: ${HEIGHT}%\"><span class=\"chart-value\">$COUNT</span><span class=\"chart-label\">${MONTH_NAMES[$i]}</span></div>"
done

# Build leaderboard for group/all mode
LEADERBOARD_HTML=""
if [ "$MODE" = "group" ] || [ "$MODE" = "all" ]; then
    RANK=1
    LEADERBOARD_HTML="<div class=\"leaderboard\">"
    echo "$TOP_TALKERS" | head -8 | while IFS='|' read -r person count; do
        if [ "$person" = "YOU" ]; then
            NAME="${BOLD}YOU${NC}"
            NAME_HTML="<strong>YOU</strong>"
        else
            NAME=$(get_contact_name "$person")
            NAME_HTML="$NAME"
        fi

        case $RANK in
            1) MEDAL="🥇" ;;
            2) MEDAL="🥈" ;;
            3) MEDAL="🥉" ;;
            *) MEDAL="&nbsp;&nbsp;" ;;
        esac

        echo "<div class=\"leaderboard-item\"><span class=\"rank\">$MEDAL</span><span class=\"rank-name\">$NAME_HTML</span><span class=\"rank-count\">$count</span></div>"
        ((RANK++))
    done
    LEADERBOARD_HTML="$LEADERBOARD_HTML</div>"
fi

# Build sweet messages HTML
SWEET_HTML=""
while IFS='|' read -r is_from_me text; do
    if [ -n "$text" ]; then
        if [ "$is_from_me" = "1" ]; then
            SENDER="$YOUR_NAME"
            CLASS="you"
        else
            SENDER="${CONTACT_NAME}"
            CLASS="them"
        fi
        SWEET_HTML="$SWEET_HTML<div class=\"message-card\"><div class=\"message-sender $CLASS\">$SENDER</div><div class=\"message-text\">\"$text\"</div></div>"
    fi
done <<< "$SWEET_MESSAGES"

# Build random messages HTML
RANDOM_HTML=""
while IFS='|' read -r is_from_me text; do
    if [ -n "$text" ]; then
        if [ "$is_from_me" = "1" ]; then
            SENDER="$YOUR_NAME"
            CLASS="you"
        else
            SENDER="${CONTACT_NAME}"
            CLASS="them"
        fi
        RANDOM_HTML="$RANDOM_HTML<div class=\"message-card\"><div class=\"message-sender $CLASS\">$SENDER</div><div class=\"message-text\">\"$text\"</div></div>"
    fi
done <<< "$RANDOM_MESSAGES"

# Generate the actual leaderboard HTML if in group/all mode
if [ "$MODE" = "group" ] || [ "$MODE" = "all" ]; then
    LEADERBOARD_HTML="<div class=\"leaderboard\">"
    RANK=1
    while IFS='|' read -r person count; do
        if [ -n "$person" ]; then
            if [ "$person" = "YOU" ]; then
                NAME_HTML="<strong style=\"color: var(--apple-blue);\">You</strong>"
            else
                NAME=$(get_contact_name "$person")
                NAME_HTML="$NAME"
            fi

            case $RANK in
                1) MEDAL="🥇" ;;
                2) MEDAL="🥈" ;;
                3) MEDAL="🥉" ;;
                *) MEDAL="&nbsp;&nbsp;" ;;
            esac

            LEADERBOARD_HTML="$LEADERBOARD_HTML<div class=\"leaderboard-item\"><span class=\"rank\">$MEDAL</span><span class=\"rank-name\">$NAME_HTML</span><span class=\"rank-count\">$count</span></div>"
            ((RANK++))
        fi
    done <<< "$(echo "$TOP_TALKERS" | head -8)"
    LEADERBOARD_HTML="$LEADERBOARD_HTML</div>"
fi

# Start building HTML
cat > "$OUTPUT_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>💬 Wrapped</title>
    <style>
        :root {
            --apple-black: #1d1d1f;
            --apple-gray: #86868b;
            --apple-light: #f5f5f7;
            --apple-blue: #0071e3;
            --apple-green: #34c759;
            --apple-pink: #ff2d55;
            --apple-purple: #af52de;
            --apple-orange: #ff9500;
            --apple-teal: #5ac8fa;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Helvetica Neue', sans-serif;
            background: #000;
            color: white;
            overflow: hidden;
            height: 100vh;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }

        .wrapped-container { height: 100vh; width: 100vw; position: relative; }

        .slide {
            position: absolute;
            top: 0; left: 0;
            width: 100%; height: 100%;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            padding: 60px 40px;
            opacity: 0;
            transform: translateY(20px);
            transition: opacity 0.8s cubic-bezier(0.25, 0.46, 0.45, 0.94), transform 0.8s cubic-bezier(0.25, 0.46, 0.45, 0.94);
            pointer-events: none;
            background: #000;
        }

        .slide.active {
            opacity: 1;
            transform: translateY(0);
            pointer-events: all;
        }

        /* Apple-style gradient backgrounds */
        .slide-intro {
            background: radial-gradient(ellipse at top, #1a1a2e 0%, #000 70%);
        }
        .slide-total {
            background: linear-gradient(180deg, #000 0%, #1a0a0a 100%);
        }
        .slide-balance {
            background: linear-gradient(180deg, #000 0%, #0a0a1a 100%);
            color: white;
        }
        .slide-daily {
            background: linear-gradient(180deg, #000 0%, #0a0a15 100%);
        }
        .slide-peak {
            background: linear-gradient(180deg, #000 0%, #150a15 100%);
        }
        .slide-reactions {
            background: linear-gradient(180deg, #000 0%, #151005 100%);
        }
        .slide-late-night {
            background: radial-gradient(ellipse at bottom, #0a0a20 0%, #000 70%);
        }
        .slide-sweet {
            background: linear-gradient(180deg, #000 0%, #150a0a 100%);
            color: white;
        }
        .slide-random {
            background: linear-gradient(180deg, #000 0%, #0a150a 100%);
            color: white;
        }
        .slide-busiest {
            background: linear-gradient(180deg, #000 0%, #151008 100%);
        }
        .slide-months {
            background: linear-gradient(180deg, #000 0%, #051015 100%);
        }
        .slide-day {
            background: linear-gradient(180deg, #000 0%, #100515 100%);
        }
        .slide-leaderboard {
            background: linear-gradient(180deg, #000 0%, #150510 100%);
        }
        .slide-stats {
            background: linear-gradient(180deg, #000 0%, #051010 100%);
        }
        .slide-finale {
            background: radial-gradient(ellipse at center, #1a1020 0%, #000 70%);
        }

        /* Typography */
        .pre-title {
            font-size: 0.875rem;
            font-weight: 500;
            color: var(--apple-gray);
            text-transform: uppercase;
            letter-spacing: 0.1em;
            margin-bottom: 12px;
        }

        .big-number {
            font-size: clamp(5rem, 20vw, 12rem);
            font-weight: 700;
            line-height: 1;
            letter-spacing: -0.03em;
            background: linear-gradient(180deg, #fff 0%, rgba(255,255,255,0.8) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .stat-label {
            font-size: 1.5rem;
            font-weight: 600;
            color: var(--apple-gray);
            margin-top: 8px;
            letter-spacing: -0.01em;
        }

        .subtitle {
            font-size: 1.125rem;
            font-weight: 400;
            color: var(--apple-gray);
            margin-top: 40px;
            max-width: 500px;
            text-align: center;
            line-height: 1.5;
        }

        .title {
            font-size: clamp(2.5rem, 8vw, 4.5rem);
            font-weight: 700;
            text-align: center;
            margin-bottom: 8px;
            letter-spacing: -0.03em;
            background: linear-gradient(180deg, #fff 0%, rgba(255,255,255,0.85) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        /* Message Cards - Frosted Glass */
        .message-card {
            background: rgba(255,255,255,0.08);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid rgba(255,255,255,0.1);
            border-radius: 18px;
            padding: 20px 24px;
            margin: 10px 0;
            max-width: 440px;
            width: 100%;
            animation: fadeUp 0.6s cubic-bezier(0.25, 0.46, 0.45, 0.94) forwards;
            opacity: 0;
        }
        .message-card:nth-child(1) { animation-delay: 0.1s; }
        .message-card:nth-child(2) { animation-delay: 0.2s; }
        .message-card:nth-child(3) { animation-delay: 0.3s; }

        @keyframes fadeUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .message-sender {
            font-weight: 600;
            font-size: 0.8125rem;
            margin-bottom: 6px;
            letter-spacing: -0.01em;
        }
        .message-sender.you { color: var(--apple-blue); }
        .message-sender.them { color: var(--apple-pink); }

        .message-text {
            font-size: 1rem;
            color: rgba(255,255,255,0.9);
            line-height: 1.5;
            font-weight: 400;
        }

        /* Reactions Grid */
        .reactions-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 24px;
            margin-top: 40px;
            max-width: 360px;
        }

        .reaction-item {
            text-align: center;
            animation: scaleIn 0.5s cubic-bezier(0.34, 1.56, 0.64, 1) forwards;
            opacity: 0;
        }
        .reaction-item:nth-child(1) { animation-delay: 0.05s; }
        .reaction-item:nth-child(2) { animation-delay: 0.1s; }
        .reaction-item:nth-child(3) { animation-delay: 0.15s; }
        .reaction-item:nth-child(4) { animation-delay: 0.2s; }
        .reaction-item:nth-child(5) { animation-delay: 0.25s; }
        .reaction-item:nth-child(6) { animation-delay: 0.3s; }

        @keyframes scaleIn {
            from { opacity: 0; transform: scale(0.5); }
            to { opacity: 1; transform: scale(1); }
        }

        .reaction-emoji {
            font-size: 2.5rem;
            display: block;
            margin-bottom: 8px;
        }

        .reaction-count {
            font-size: 1.125rem;
            font-weight: 600;
            color: rgba(255,255,255,0.9);
        }

        /* Navigation */
        .nav-dots {
            position: fixed;
            bottom: 40px;
            left: 50%;
            transform: translateX(-50%);
            display: flex;
            gap: 8px;
            z-index: 100;
            padding: 10px 16px;
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border-radius: 20px;
        }

        .nav-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: rgba(255,255,255,0.3);
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94);
        }

        .nav-dot.active {
            background: white;
            transform: scale(1.2);
        }

        .nav-dot:hover {
            background: rgba(255,255,255,0.6);
        }

        .nav-arrows {
            position: fixed;
            bottom: 40px;
            right: 40px;
            display: flex;
            gap: 12px;
            z-index: 100;
        }

        .nav-arrow {
            width: 44px;
            height: 44px;
            border-radius: 50%;
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid rgba(255,255,255,0.1);
            color: white;
            font-size: 1.25rem;
            cursor: pointer;
            transition: all 0.25s cubic-bezier(0.25, 0.46, 0.45, 0.94);
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .nav-arrow:hover {
            background: rgba(255,255,255,0.2);
            transform: scale(1.05);
        }

        /* Intro */
        .intro-logo {
            font-size: 4rem;
            margin-bottom: 24px;
        }

        .click-hint {
            position: fixed;
            bottom: 100px;
            left: 50%;
            transform: translateX(-50%);
            font-size: 0.8125rem;
            font-weight: 500;
            color: var(--apple-gray);
            animation: fadeInOut 3s ease-in-out infinite;
        }

        @keyframes fadeInOut {
            0%, 100% { opacity: 0.4; }
            50% { opacity: 0.8; }
        }

        /* Balance Bar */
        .balance-bar {
            display: flex;
            width: 100%;
            max-width: 400px;
            height: 56px;
            border-radius: 28px;
            overflow: hidden;
            margin: 32px 0;
            background: rgba(255,255,255,0.05);
        }

        .balance-you {
            background: var(--apple-blue);
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 600;
            font-size: 0.875rem;
            color: white;
            padding: 0 16px;
            transition: width 0.8s cubic-bezier(0.25, 0.46, 0.45, 0.94);
        }

        .balance-them {
            background: var(--apple-pink);
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 600;
            font-size: 0.875rem;
            color: white;
            padding: 0 16px;
        }

        /* Chart */
        .chart-container {
            display: flex;
            align-items: flex-end;
            gap: 8px;
            height: 200px;
            margin-top: 40px;
            padding: 0 20px;
        }

        .chart-bar {
            flex: 1;
            background: linear-gradient(180deg, var(--apple-blue) 0%, rgba(0,113,227,0.6) 100%);
            border-radius: 6px 6px 0 0;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: flex-start;
            padding-top: 8px;
            min-width: 24px;
            max-width: 40px;
            animation: growUp 0.8s cubic-bezier(0.25, 0.46, 0.45, 0.94) forwards;
            transform-origin: bottom;
            transform: scaleY(0);
        }

        .chart-bar:nth-child(1) { animation-delay: 0.05s; }
        .chart-bar:nth-child(2) { animation-delay: 0.1s; }
        .chart-bar:nth-child(3) { animation-delay: 0.15s; }
        .chart-bar:nth-child(4) { animation-delay: 0.2s; }
        .chart-bar:nth-child(5) { animation-delay: 0.25s; }
        .chart-bar:nth-child(6) { animation-delay: 0.3s; }
        .chart-bar:nth-child(7) { animation-delay: 0.35s; }
        .chart-bar:nth-child(8) { animation-delay: 0.4s; }
        .chart-bar:nth-child(9) { animation-delay: 0.45s; }
        .chart-bar:nth-child(10) { animation-delay: 0.5s; }
        .chart-bar:nth-child(11) { animation-delay: 0.55s; }
        .chart-bar:nth-child(12) { animation-delay: 0.6s; }

        @keyframes growUp {
            from { transform: scaleY(0); }
            to { transform: scaleY(1); }
        }

        .chart-label {
            font-size: 0.6875rem;
            font-weight: 500;
            color: var(--apple-gray);
            margin-top: 12px;
            position: absolute;
            bottom: -24px;
        }

        .chart-value {
            font-size: 0.625rem;
            font-weight: 600;
            color: white;
            opacity: 0.9;
        }

        .chart-bar-wrapper {
            position: relative;
            display: flex;
            flex-direction: column;
            align-items: center;
            flex: 1;
        }

        /* Stats Row */
        .stat-row {
            display: flex;
            justify-content: center;
            gap: 48px;
            width: 100%;
            max-width: 600px;
            margin-top: 48px;
        }

        .mini-stat {
            text-align: center;
        }

        .mini-stat-value {
            font-size: 2.5rem;
            font-weight: 700;
            letter-spacing: -0.02em;
            background: linear-gradient(180deg, #fff 0%, rgba(255,255,255,0.8) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .mini-stat-label {
            font-size: 0.8125rem;
            font-weight: 500;
            color: var(--apple-gray);
            margin-top: 4px;
        }

        /* VS Container */
        .vs-container {
            display: flex;
            align-items: center;
            gap: 48px;
            margin: 40px 0;
        }

        .vs-person { text-align: center; }

        .vs-name {
            font-size: 1rem;
            font-weight: 500;
            color: var(--apple-gray);
            margin-bottom: 8px;
        }

        .vs-count {
            font-size: 3.5rem;
            font-weight: 700;
            letter-spacing: -0.02em;
            background: linear-gradient(180deg, #fff 0%, rgba(255,255,255,0.8) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .vs-divider {
            font-size: 1.25rem;
            font-weight: 500;
            color: var(--apple-gray);
        }

        /* Leaderboard */
        .leaderboard {
            width: 100%;
            max-width: 400px;
            margin-top: 32px;
        }

        .leaderboard-item {
            display: flex;
            align-items: center;
            padding: 14px 0;
            border-bottom: 1px solid rgba(255,255,255,0.06);
            animation: fadeUp 0.5s cubic-bezier(0.25, 0.46, 0.45, 0.94) forwards;
            opacity: 0;
        }

        .leaderboard-item:nth-child(1) { animation-delay: 0.05s; }
        .leaderboard-item:nth-child(2) { animation-delay: 0.1s; }
        .leaderboard-item:nth-child(3) { animation-delay: 0.15s; }
        .leaderboard-item:nth-child(4) { animation-delay: 0.2s; }
        .leaderboard-item:nth-child(5) { animation-delay: 0.25s; }
        .leaderboard-item:nth-child(6) { animation-delay: 0.3s; }
        .leaderboard-item:nth-child(7) { animation-delay: 0.35s; }
        .leaderboard-item:nth-child(8) { animation-delay: 0.4s; }

        .leaderboard-item:last-child { border-bottom: none; }

        .rank {
            font-size: 1.25rem;
            width: 40px;
            text-align: center;
        }

        .rank-name {
            flex: 1;
            font-size: 1rem;
            font-weight: 500;
            color: rgba(255,255,255,0.9);
        }

        .rank-count {
            font-size: 0.9375rem;
            font-weight: 600;
            color: var(--apple-gray);
            font-variant-numeric: tabular-nums;
        }

        /* Fun Stats */
        .fun-stat {
            background: rgba(255,255,255,0.06);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 16px;
            padding: 24px 32px;
            text-align: center;
            min-width: 140px;
        }

        .fun-stat-value {
            font-size: 2rem;
            font-weight: 700;
            letter-spacing: -0.02em;
            background: linear-gradient(180deg, #fff 0%, rgba(255,255,255,0.8) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .fun-stat-label {
            font-size: 0.8125rem;
            font-weight: 500;
            color: var(--apple-gray);
            margin-top: 6px;
        }

        /* Accent colors for variety */
        .slide-total .big-number {
            background: linear-gradient(180deg, #ff375f 0%, #ff6482 100%);
            -webkit-background-clip: text;
            background-clip: text;
        }

        .slide-daily .big-number {
            background: linear-gradient(180deg, var(--apple-blue) 0%, #40a9ff 100%);
            -webkit-background-clip: text;
            background-clip: text;
        }

        .slide-peak .big-number {
            background: linear-gradient(180deg, var(--apple-purple) 0%, #c77dff 100%);
            -webkit-background-clip: text;
            background-clip: text;
        }

        .slide-busiest .big-number {
            background: linear-gradient(180deg, var(--apple-orange) 0%, #ffb340 100%);
            -webkit-background-clip: text;
            background-clip: text;
        }

        .slide-day .big-number {
            background: linear-gradient(180deg, var(--apple-teal) 0%, #7dd3fc 100%);
            -webkit-background-clip: text;
            background-clip: text;
        }

        /* Remove emoji from titles for cleaner look */
        .slide-leaderboard .title,
        .slide-reactions .title,
        .slide-late-night .title,
        .slide-sweet .title,
        .slide-random .title,
        .slide-months .title,
        .slide-stats .title {
            -webkit-text-fill-color: white;
        }
    </style>
</head>
<body>
    <div class="wrapped-container" onclick="nextSlide()">
HTMLEOF

# Determine intro subtitle based on mode
if [ "$MODE" = "all" ]; then
    INTRO_SUBTITLE="Your entire year of messages, beautifully summarized."
elif [ "$MODE" = "group" ]; then
    INTRO_SUBTITLE="A year of conversations, captured in numbers."
else
    INTRO_SUBTITLE="A year of connection, one message at a time."
fi

# Add slides
cat >> "$OUTPUT_FILE" << EOF
        <!-- Slide 0: Intro -->
        <div class="slide slide-intro active" data-slide="0">
            <div class="pre-title">YEAR IN REVIEW</div>
            <div class="title">$TITLE</div>
            <div class="stat-label">$YEAR</div>
            <div class="subtitle">$INTRO_SUBTITLE</div>
        </div>

        <!-- Slide 1: Total Messages -->
        <div class="slide slide-total" data-slide="1">
            <div class="pre-title">THIS YEAR YOU EXCHANGED</div>
            <div class="big-number">$(printf "%'d" $TOTAL_MESSAGES)</div>
            <div class="stat-label">messages</div>
            <div class="subtitle">$TOTAL_COMMENT</div>
        </div>
EOF

# Add leaderboard for group/all mode
SLIDE_NUM=2
if [ "$MODE" = "group" ] || [ "$MODE" = "all" ]; then
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Leaderboard -->
        <div class="slide slide-leaderboard" data-slide="$SLIDE_NUM">
            <div class="pre-title">WHO TALKED THE MOST</div>
            <div class="title">Top Messagers</div>
            $LEADERBOARD_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

# Add laugh react leaderboard for group mode
if [ "$MODE" = "group" ] && [ "$LAUGHED" -gt 0 ] && [ -n "$TOP_LAUGH_RECEIVERS" ]; then
    # Build laugh leaderboard HTML
    LAUGH_LEADERBOARD_HTML="<div class=\"leaderboard\">"
    RANK=1
    while IFS='|' read -r person count; do
        if [ -n "$person" ]; then
            if [ "$person" = "YOU" ]; then
                NAME_HTML="<strong style=\"color: var(--apple-blue);\">You</strong>"
            else
                NAME=$(get_contact_name "$person")
                NAME_HTML="$NAME"
            fi

            case $RANK in
                1) MEDAL="🥇" ;;
                2) MEDAL="🥈" ;;
                3) MEDAL="🥉" ;;
                *) MEDAL="&nbsp;&nbsp;" ;;
            esac

            LAUGH_LEADERBOARD_HTML="$LAUGH_LEADERBOARD_HTML<div class=\"leaderboard-item\"><span class=\"rank\">$MEDAL</span><span class=\"rank-name\">$NAME_HTML</span><span class=\"rank-count\">$count</span></div>"
            ((RANK++))
        fi
    done <<< "$TOP_LAUGH_RECEIVERS"
    LAUGH_LEADERBOARD_HTML="$LAUGH_LEADERBOARD_HTML</div>"

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Laugh React Leaderboard -->
        <div class="slide slide-leaderboard" data-slide="$SLIDE_NUM">
            <div class="pre-title">MOST LAUGH REACTS RECEIVED</div>
            <div class="title">The Comedians</div>
            $LAUGH_LEADERBOARD_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

# Balance slide (skip for all mode - doesn't make sense)
if [ "$MODE" != "all" ]; then
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Balance -->
        <div class="slide slide-balance" data-slide="$SLIDE_NUM">
            <div class="pre-title">MESSAGE BALANCE</div>
            <div class="title">Who Texted More</div>
            <div class="balance-bar">
                <div class="balance-you" style="width: ${YOUR_PERCENT}%">$YOUR_NAME: $(printf "%'d" $YOUR_MESSAGES)</div>
                <div class="balance-them" style="width: ${THEIR_PERCENT}%">$CONTACT_NAME: $(printf "%'d" $THEIR_MESSAGES)</div>
            </div>
            <div class="subtitle">$BALANCE_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Daily Average -->
        <div class="slide slide-daily" data-slide="$SLIDE_NUM">
            <div class="pre-title">DAILY AVERAGE</div>
            <div class="big-number">$DAILY_AVG</div>
            <div class="stat-label">messages per day</div>
            <div class="subtitle">$DAILY_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Peak Hour -->
        <div class="slide slide-peak" data-slide="$SLIDE_NUM">
            <div class="pre-title">PEAK MESSAGING HOUR</div>
            <div class="big-number">$PEAK_HOUR_FMT</div>
            <div class="stat-label">$(printf "%'d" $PEAK_HOUR_COUNT) messages</div>
            <div class="subtitle">$PEAK_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Reactions -->
        <div class="slide slide-reactions" data-slide="$SLIDE_NUM">
            <div class="pre-title">$(printf "%'d" $TOTAL_REACTIONS) TOTAL REACTIONS</div>
            <div class="title">Reactions</div>
            <div class="reactions-grid">
                <div class="reaction-item"><span class="reaction-emoji">❤️</span><span class="reaction-count">$LOVED</span></div>
                <div class="reaction-item"><span class="reaction-emoji">‼️</span><span class="reaction-count">$EMPHASIZED</span></div>
                <div class="reaction-item"><span class="reaction-emoji">👍</span><span class="reaction-count">$LIKED</span></div>
                <div class="reaction-item"><span class="reaction-emoji">😂</span><span class="reaction-count">$LAUGHED</span></div>
                <div class="reaction-item"><span class="reaction-emoji">👎</span><span class="reaction-count">$DISLIKED</span></div>
                <div class="reaction-item"><span class="reaction-emoji">❓</span><span class="reaction-count">$QUESTIONED</span></div>
            </div>
            <div class="subtitle">$REACTIONS_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Late Night -->
        <div class="slide slide-late-night" data-slide="$SLIDE_NUM">
            <div class="pre-title">MESSAGES SENT 1–5 AM</div>
            <div class="title">Night Owls</div>
            <div class="vs-container">
                <div class="vs-person">
                    <div class="vs-name">$CONTACT_NAME</div>
                    <div class="vs-count">$THEIR_LATE</div>
                </div>
                <div class="vs-divider">vs</div>
                <div class="vs-person">
                    <div class="vs-name">$YOUR_NAME</div>
                    <div class="vs-count">$YOUR_LATE</div>
                </div>
            </div>
            <div class="subtitle">$LATE_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

# Sweet messages slide
if [ -n "$SWEET_HTML" ]; then
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Sweet Messages -->
        <div class="slide slide-sweet" data-slide="$SLIDE_NUM">
            <div class="pre-title">HEARTFELT MOMENTS</div>
            <div class="title">The Sweet Stuff</div>
            $SWEET_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

# Random messages slide
if [ -n "$RANDOM_HTML" ]; then
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Random Moments -->
        <div class="slide slide-random" data-slide="$SLIDE_NUM">
            <div class="pre-title">MEMORABLE MESSAGES</div>
            <div class="title">Random Moments</div>
            $RANDOM_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Busiest Day -->
        <div class="slide slide-busiest" data-slide="$SLIDE_NUM">
            <div class="pre-title">BUSIEST DAY</div>
            <div class="big-number" style="font-size: clamp(2rem, 8vw, 5rem);">$BUSIEST_DATE_FMT</div>
            <div class="stat-label">$BUSIEST_COUNT messages</div>
            <div class="subtitle">$BUSIEST_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Monthly -->
        <div class="slide slide-months" data-slide="$SLIDE_NUM">
            <div class="pre-title">MESSAGES BY MONTH</div>
            <div class="title">Your Year</div>
            <div class="chart-container">
                $MONTH_BARS
            </div>
            <div class="subtitle">$PEAK_MONTH_NAME was your peak month.</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Day of Week -->
        <div class="slide slide-day" data-slide="$SLIDE_NUM">
            <div class="pre-title">FAVORITE DAY TO TEXT</div>
            <div class="big-number" style="font-size: clamp(2.5rem, 10vw, 5rem);">$BUSIEST_DAY_NAME</div>
            <div class="stat-label">$(printf "%'d" $BUSIEST_DOW_COUNT) messages</div>
            <div class="subtitle">$DOW_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

# Fun stats slide
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Fun Stats -->
        <div class="slide slide-stats" data-slide="$SLIDE_NUM">
            <div class="pre-title">MORE STATS</div>
            <div class="title">By the Numbers</div>
            <div class="stat-row">
                <div class="fun-stat">
                    <div class="fun-stat-value">$(printf "%'d" $TOTAL_WORDS)</div>
                    <div class="fun-stat-label">words typed</div>
                </div>
                <div class="fun-stat">
                    <div class="fun-stat-value">$(printf "%'d" $PHOTO_COUNT)</div>
                    <div class="fun-stat-label">photos & videos</div>
                </div>
                <div class="fun-stat">
                    <div class="fun-stat-value">$TOTAL_LATE</div>
                    <div class="fun-stat-label">late night texts</div>
                </div>
            </div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

# Finale
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Finale -->
        <div class="slide slide-finale" data-slide="$SLIDE_NUM">
            <div class="pre-title">$TITLE</div>
            <div class="title">That's a Wrap</div>
            <div class="stat-label">$YEAR</div>
            <div class="stat-row">
                <div class="mini-stat">
                    <div class="mini-stat-value">$(printf "%'d" $TOTAL_MESSAGES)</div>
                    <div class="mini-stat-label">messages</div>
                </div>
                <div class="mini-stat">
                    <div class="mini-stat-value">$(printf "%'d" $TOTAL_REACTIONS)</div>
                    <div class="mini-stat-label">reactions</div>
                </div>
                <div class="mini-stat">
                    <div class="mini-stat-value">365</div>
                    <div class="mini-stat-label">days</div>
                </div>
            </div>
            <div class="subtitle" style="margin-top: 40px;">Here's to another year of conversations.</div>
        </div>
    </div>
EOF

# Navigation dots
FINAL_SLIDE=$SLIDE_NUM
NAV_DOTS=""
for i in $(seq 0 $FINAL_SLIDE); do
    if [ $i -eq 0 ]; then
        NAV_DOTS="$NAV_DOTS<div class=\"nav-dot active\" onclick=\"goToSlide($i)\"></div>"
    else
        NAV_DOTS="$NAV_DOTS<div class=\"nav-dot\" onclick=\"goToSlide($i)\"></div>"
    fi
done

cat >> "$OUTPUT_FILE" << EOF

    <div class="nav-dots">
        $NAV_DOTS
    </div>

    <div class="nav-arrows">
        <button class="nav-arrow" onclick="prevSlide(event)">‹</button>
        <button class="nav-arrow" onclick="nextSlide(event)">›</button>
    </div>

    <div class="click-hint">Tap to continue</div>

    <script>
        let currentSlide = 0;
        const totalSlides = $((FINAL_SLIDE + 1));

        function goToSlide(n) {
            event?.stopPropagation();
            const slides = document.querySelectorAll('.slide');
            const dots = document.querySelectorAll('.nav-dot');
            slides.forEach(s => s.classList.remove('active'));
            dots.forEach(d => d.classList.remove('active'));
            currentSlide = n;
            slides[currentSlide].classList.add('active');
            dots[currentSlide].classList.add('active');
            document.querySelector('.click-hint').style.opacity = '0';
        }

        function nextSlide(event) {
            event?.stopPropagation();
            if (currentSlide < totalSlides - 1) goToSlide(currentSlide + 1);
        }

        function prevSlide(event) {
            event?.stopPropagation();
            if (currentSlide > 0) goToSlide(currentSlide - 1);
        }

        document.addEventListener('keydown', (e) => {
            if (e.key === 'ArrowRight' || e.key === ' ') nextSlide();
            else if (e.key === 'ArrowLeft') prevSlide();
        });

        let touchStartX = 0;
        document.addEventListener('touchstart', (e) => { touchStartX = e.touches[0].clientX; });
        document.addEventListener('touchend', (e) => {
            const diff = touchStartX - e.changedTouches[0].clientX;
            if (Math.abs(diff) > 50) { diff > 0 ? nextSlide() : prevSlide(); }
        });
    </script>
</body>
</html>
EOF

# Fix the title
sed -i '' "s/TITLE_PLACEHOLDER/$TITLE Wrapped $YEAR/" "$OUTPUT_FILE"

echo ""
echo -e "${GREEN}${BOLD}✅ Generated: $OUTPUT_FILE${NC}"
echo ""
echo -e "${CYAN}Open in browser:${NC}"
echo "  open \"$OUTPUT_FILE\""
echo ""
