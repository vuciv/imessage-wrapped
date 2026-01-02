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
trap "rm -f $CONTACT_CACHE" EXIT

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
        echo "$match"
    else
        # Return truncated handle
        if [ ${#handle} -gt 15 ]; then
            echo "...${handle: -10}"
        else
            echo "$handle"
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
    OUTPUT_FILE="${OUTPUT_FILE:-${YOUR_NAME,,}-${SAFE_NAME}-wrapped-${YEAR}.html}"
fi

echo -e "${CYAN}${BOLD}Generating wrapped for: $TITLE${NC}"
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
    SELECT SUM(LENGTH(m.text) - LENGTH(REPLACE(m.text, ' ', '')) + 1)
    $BASE_FROM
    WHERE $WHERE_CLAUSE AND m.text IS NOT NULL;
")
TOTAL_WORDS=${TOTAL_WORDS:-0}

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
                NAME_HTML="<strong style=\"color: #4cc9f0;\">YOU</strong>"
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
    <title>TITLE_PLACEHOLDER</title>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;600;700;900&display=swap" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Outfit', sans-serif; background: #0a0a0a; color: white; overflow: hidden; height: 100vh; }
        .wrapped-container { height: 100vh; width: 100vw; position: relative; }
        .slide { position: absolute; top: 0; left: 0; width: 100%; height: 100%; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 40px; opacity: 0; transform: scale(0.9); transition: all 0.6s cubic-bezier(0.4, 0, 0.2, 1); pointer-events: none; }
        .slide.active { opacity: 1; transform: scale(1); pointer-events: all; }

        .slide-intro { background: linear-gradient(135deg, #1a1a2e 0%, #2d1b4e 50%, #4a1942 100%); }
        .slide-total { background: linear-gradient(135deg, #ff6b6b 0%, #ee5a5a 50%, #c94b4b 100%); }
        .slide-balance { background: linear-gradient(135deg, #a8edea 0%, #fed6e3 100%); color: #333; }
        .slide-daily { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .slide-peak { background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%); }
        .slide-reactions { background: linear-gradient(135deg, #fa709a 0%, #fee140 100%); }
        .slide-late-night { background: linear-gradient(135deg, #0c1445 0%, #1a1b4b 50%, #2d1b4e 100%); }
        .slide-sweet { background: linear-gradient(135deg, #ffafbd 0%, #ffc3a0 100%); color: #333; }
        .slide-random { background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%); color: #333; }
        .slide-busiest { background: linear-gradient(135deg, #fc4a1a 0%, #f7b733 100%); }
        .slide-months { background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%); }
        .slide-day { background: linear-gradient(135deg, #7209b7 0%, #560bad 100%); }
        .slide-leaderboard { background: linear-gradient(135deg, #f72585 0%, #b5179e 100%); }
        .slide-stats { background: linear-gradient(135deg, #00b4d8 0%, #0096c7 100%); }
        .slide-finale { background: linear-gradient(135deg, #ff6b6b 0%, #ee5a5a 30%, #f093fb 70%, #667eea 100%); }

        .pre-title { font-size: 1.2rem; opacity: 0.8; text-transform: uppercase; letter-spacing: 3px; margin-bottom: 20px; }
        .big-number { font-size: clamp(4rem, 15vw, 10rem); font-weight: 900; line-height: 1; text-shadow: 0 10px 30px rgba(0,0,0,0.3); }
        .stat-label { font-size: 1.5rem; opacity: 0.9; margin-top: 10px; }
        .subtitle { font-size: 1.1rem; opacity: 0.7; margin-top: 30px; max-width: 450px; text-align: center; line-height: 1.5; }
        .title { font-size: clamp(2rem, 8vw, 4rem); font-weight: 900; text-align: center; margin-bottom: 20px; }

        .message-card { background: rgba(255,255,255,0.95); border-radius: 20px; padding: 25px 30px; margin: 12px 0; max-width: 500px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); animation: popIn 0.5s ease forwards; opacity: 0; }
        .message-card:nth-child(1) { animation-delay: 0.2s; }
        .message-card:nth-child(2) { animation-delay: 0.4s; }
        .message-card:nth-child(3) { animation-delay: 0.6s; }
        @keyframes popIn { from { opacity: 0; transform: scale(0.8) translateY(20px); } to { opacity: 1; transform: scale(1) translateY(0); } }
        .message-sender { font-weight: 700; margin-bottom: 8px; }
        .message-sender.you { color: #667eea; }
        .message-sender.them { color: #f5576c; }
        .message-text { font-size: 1.1rem; color: #333; line-height: 1.4; }

        .reactions-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-top: 30px; max-width: 400px; }
        .reaction-item { text-align: center; animation: bounceIn 0.5s ease forwards; opacity: 0; }
        .reaction-item:nth-child(1) { animation-delay: 0.1s; }
        .reaction-item:nth-child(2) { animation-delay: 0.2s; }
        .reaction-item:nth-child(3) { animation-delay: 0.3s; }
        .reaction-item:nth-child(4) { animation-delay: 0.4s; }
        .reaction-item:nth-child(5) { animation-delay: 0.5s; }
        .reaction-item:nth-child(6) { animation-delay: 0.6s; }
        @keyframes bounceIn { 0% { opacity: 0; transform: scale(0); } 60% { transform: scale(1.2); } 100% { opacity: 1; transform: scale(1); } }
        .reaction-emoji { font-size: 3rem; display: block; margin-bottom: 5px; }
        .reaction-count { font-size: 1.2rem; font-weight: 700; }

        .nav-dots { position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%); display: flex; gap: 10px; z-index: 100; }
        .nav-dot { width: 10px; height: 10px; border-radius: 50%; background: rgba(255,255,255,0.3); cursor: pointer; transition: all 0.3s ease; }
        .nav-dot.active { background: white; transform: scale(1.3); }
        .nav-arrows { position: fixed; bottom: 30px; right: 30px; display: flex; gap: 15px; z-index: 100; }
        .nav-arrow { width: 50px; height: 50px; border-radius: 50%; background: rgba(255,255,255,0.2); border: none; color: white; font-size: 1.5rem; cursor: pointer; transition: all 0.3s ease; display: flex; align-items: center; justify-content: center; }
        .nav-arrow:hover { background: rgba(255,255,255,0.4); transform: scale(1.1); }

        .intro-logo { font-size: 5rem; margin-bottom: 20px; animation: pulse 2s ease-in-out infinite; }
        @keyframes pulse { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.1); } }
        .click-hint { position: fixed; bottom: 80px; left: 50%; transform: translateX(-50%); font-size: 0.9rem; opacity: 0.6; animation: bounce 2s ease-in-out infinite; }
        @keyframes bounce { 0%, 100% { transform: translateX(-50%) translateY(0); } 50% { transform: translateX(-50%) translateY(-10px); } }

        .balance-bar { display: flex; width: 100%; max-width: 400px; height: 60px; border-radius: 30px; overflow: hidden; margin: 30px 0; box-shadow: 0 10px 30px rgba(0,0,0,0.2); }
        .balance-you { background: linear-gradient(90deg, #667eea, #764ba2); display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 1rem; color: white; padding: 0 10px; }
        .balance-them { background: linear-gradient(90deg, #f5576c, #f093fb); display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 1rem; color: white; padding: 0 10px; }

        .chart-container { display: flex; align-items: flex-end; gap: 6px; height: 180px; margin-top: 30px; max-width: 100%; }
        .chart-bar { flex: 1; background: rgba(255,255,255,0.9); border-radius: 8px 8px 0 0; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; padding: 6px 3px; min-width: 28px; animation: growUp 0.8s ease forwards; transform-origin: bottom; }
        @keyframes growUp { from { transform: scaleY(0); } to { transform: scaleY(1); } }
        .chart-label { font-size: 0.65rem; font-weight: 600; color: #333; margin-top: 5px; }
        .chart-value { font-size: 0.65rem; font-weight: 700; color: #333; }

        .stat-row { display: flex; justify-content: space-around; width: 100%; max-width: 600px; margin-top: 40px; flex-wrap: wrap; gap: 20px; }
        .mini-stat { text-align: center; min-width: 100px; }
        .mini-stat-value { font-size: 2.2rem; font-weight: 900; }
        .mini-stat-label { font-size: 0.85rem; opacity: 0.8; }

        .glow { text-shadow: 0 0 20px rgba(255,255,255,0.5), 0 0 40px rgba(255,255,255,0.3); }

        .vs-container { display: flex; align-items: center; gap: 30px; margin: 30px 0; }
        .vs-person { text-align: center; }
        .vs-name { font-size: 1.5rem; font-weight: 700; margin-bottom: 10px; }
        .vs-count { font-size: 3rem; font-weight: 900; }
        .vs-divider { font-size: 2rem; opacity: 0.5; }

        .leaderboard { width: 100%; max-width: 450px; margin-top: 20px; }
        .leaderboard-item { display: flex; align-items: center; padding: 10px 0; border-bottom: 1px solid rgba(255,255,255,0.2); animation: slideIn 0.5s ease forwards; opacity: 0; }
        .leaderboard-item:nth-child(1) { animation-delay: 0.1s; }
        .leaderboard-item:nth-child(2) { animation-delay: 0.15s; }
        .leaderboard-item:nth-child(3) { animation-delay: 0.2s; }
        .leaderboard-item:nth-child(4) { animation-delay: 0.25s; }
        .leaderboard-item:nth-child(5) { animation-delay: 0.3s; }
        .leaderboard-item:nth-child(6) { animation-delay: 0.35s; }
        .leaderboard-item:nth-child(7) { animation-delay: 0.4s; }
        .leaderboard-item:nth-child(8) { animation-delay: 0.45s; }
        @keyframes slideIn { from { opacity: 0; transform: translateX(-30px); } to { opacity: 1; transform: translateX(0); } }
        .rank { font-size: 1.5rem; font-weight: 700; width: 45px; }
        .rank-name { flex: 1; font-size: 1rem; font-weight: 600; }
        .rank-count { font-size: 1rem; font-weight: 700; }

        .fun-stat { background: rgba(255,255,255,0.15); border-radius: 15px; padding: 20px 30px; margin: 15px; text-align: center; }
        .fun-stat-value { font-size: 2rem; font-weight: 900; }
        .fun-stat-label { font-size: 0.9rem; opacity: 0.8; margin-top: 5px; }
    </style>
</head>
<body>
    <div class="wrapped-container" onclick="nextSlide()">
HTMLEOF

# Determine intro emoji based on mode
if [ "$MODE" = "all" ]; then
    INTRO_EMOJI="📱"
    INTRO_SUBTITLE="Your entire year of texts, wrapped up with a bow"
elif [ "$MODE" = "group" ]; then
    INTRO_EMOJI="👥"
    INTRO_SUBTITLE="A year of group chat chaos, condensed into stats"
else
    INTRO_EMOJI="💬"
    INTRO_SUBTITLE="A year of texts, memories, and conversations"
fi

# Add slides
cat >> "$OUTPUT_FILE" << EOF
        <!-- Slide 0: Intro -->
        <div class="slide slide-intro active" data-slide="0">
            <div class="intro-logo">$INTRO_EMOJI</div>
            <div class="title">$TITLE</div>
            <div class="pre-title">WRAPPED $YEAR</div>
            <div class="subtitle">$INTRO_SUBTITLE</div>
        </div>

        <!-- Slide 1: Total Messages -->
        <div class="slide slide-total" data-slide="1">
            <div class="pre-title">This year, you exchanged...</div>
            <div class="big-number glow">$(printf "%'d" $TOTAL_MESSAGES)</div>
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
            <div class="title">🏆 The Yappers 🏆</div>
            <div class="pre-title">Who carried the conversation?</div>
            $LEADERBOARD_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

# Balance slide (skip for all mode - doesn't make sense)
if [ "$MODE" != "all" ]; then
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Balance -->
        <div class="slide slide-balance" data-slide="$SLIDE_NUM">
            <div class="title">Who Texted More?</div>
            <div class="pre-title">The message balance</div>
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
            <div class="pre-title">On average, that's...</div>
            <div class="big-number">$DAILY_AVG</div>
            <div class="stat-label">messages per day</div>
            <div class="subtitle">$DAILY_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Peak Hour -->
        <div class="slide slide-peak" data-slide="$SLIDE_NUM">
            <div class="pre-title">Your favorite time to talk...</div>
            <div class="big-number">$PEAK_HOUR_FMT</div>
            <div class="stat-label">$(printf "%'d" $PEAK_HOUR_COUNT) messages at this hour</div>
            <div class="subtitle">$PEAK_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Reactions -->
        <div class="slide slide-reactions" data-slide="$SLIDE_NUM">
            <div class="title">Reaction Check</div>
            <div class="pre-title">$(printf "%'d" $TOTAL_REACTIONS) reactions exchanged</div>
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
            <div class="title">🌙 Night Owls 🌙</div>
            <div class="pre-title">Messages sent between 1-5 AM</div>
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
            <div class="title">💕 The Sweet Stuff 💕</div>
            <div class="pre-title">Messages that made hearts melt</div>
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
            <div class="title">💬 Random Moments 💬</div>
            <div class="pre-title">Messages that capture the vibe</div>
            $RANDOM_HTML
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))
fi

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Busiest Day -->
        <div class="slide slide-busiest" data-slide="$SLIDE_NUM">
            <div class="pre-title">Your most intense texting day...</div>
            <div class="big-number" style="font-size: clamp(1.8rem, 7vw, 4rem);">$BUSIEST_DATE_FMT</div>
            <div class="stat-label">$BUSIEST_COUNT messages in one day</div>
            <div class="subtitle">$BUSIEST_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Monthly -->
        <div class="slide slide-months" data-slide="$SLIDE_NUM">
            <div class="title">📈 Your Year in Motion</div>
            <div class="pre-title">Messages by month</div>
            <div class="chart-container">
                $MONTH_BARS
            </div>
            <div class="subtitle">$PEAK_MONTH_NAME was your peak month. The conversation ebbs and flows!</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Day of Week -->
        <div class="slide slide-day" data-slide="$SLIDE_NUM">
            <div class="title">Your Day</div>
            <div class="pre-title">Busiest day of the week</div>
            <div class="big-number" style="font-size: clamp(2.5rem, 10vw, 6rem);">$BUSIEST_DAY_NAME</div>
            <div class="stat-label">$(printf "%'d" $BUSIEST_DOW_COUNT) messages</div>
            <div class="subtitle">$DOW_COMMENT</div>
        </div>
EOF
SLIDE_NUM=$((SLIDE_NUM + 1))

# Fun stats slide
cat >> "$OUTPUT_FILE" << EOF

        <!-- Slide: Fun Stats -->
        <div class="slide slide-stats" data-slide="$SLIDE_NUM">
            <div class="title">📊 By The Numbers 📊</div>
            <div class="stat-row">
                <div class="fun-stat">
                    <div class="fun-stat-value">$(printf "%'d" $TOTAL_WORDS)</div>
                    <div class="fun-stat-label">words typed</div>
                </div>
                <div class="fun-stat">
                    <div class="fun-stat-value">$(printf "%'d" $PHOTO_COUNT)</div>
                    <div class="fun-stat-label">photos/videos</div>
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
            <div class="intro-logo">$INTRO_EMOJI</div>
            <div class="title">That's a Wrap!</div>
            <div class="pre-title">$TITLE $YEAR</div>
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
            <div class="subtitle" style="margin-top: 40px;">Here's to another year of conversations, reactions, and memories. See you in 2026! ✨</div>
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
        <button class="nav-arrow" onclick="prevSlide(event)">←</button>
        <button class="nav-arrow" onclick="nextSlide(event)">→</button>
    </div>

    <div class="click-hint">Click anywhere or use arrows to continue →</div>

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
