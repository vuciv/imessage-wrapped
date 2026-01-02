# iMessage Wrapped

Generate a Spotify Wrapped-style HTML presentation for your iMessage conversations.

![macOS](https://img.shields.io/badge/macOS-only-blue)
![Bash](https://img.shields.io/badge/bash-script-green)

## Features

- **Individual Contacts**: Generate wrapped for any contact by phone number, email, or name
- **Group Chats**: Create wrapped for your group conversations
- **All Messages**: See your entire year of iMessage stats combined
- Beautiful, animated HTML presentation with slides
- Statistics include:
  - Total messages exchanged
  - Message balance (who texts more)
  - Daily average
  - Peak texting hour
  - Reactions breakdown (hearts, likes, laughs, etc.)
  - Late night texting stats
  - Busiest day
  - Monthly breakdown chart
  - Top talkers leaderboard (for groups)
  - Random memorable messages

## Requirements

- macOS (uses the native iMessage database)
- Full Disk Access permission for your terminal app
- `sqlite3` (pre-installed on macOS)
- `bc` (pre-installed on macOS)

## Setup

### Grant Full Disk Access

1. Open **System Settings** > **Privacy & Security** > **Full Disk Access**
2. Click the **+** button
3. Add your terminal app (Terminal, iTerm2, etc.)
4. Restart your terminal

## Usage

```bash
# Make the script executable
chmod +x imessage-wrapped.sh

# Generate wrapped for an individual contact
./imessage-wrapped.sh '+15551234567'
./imessage-wrapped.sh -n 'Helen' '+15551234567'
./imessage-wrapped.sh 'John Smith'

# Generate wrapped for a group chat
./imessage-wrapped.sh --group 'movie club'
./imessage-wrapped.sh --group 'family' -n 'Family Chat'

# Generate wrapped for ALL your messages
./imessage-wrapped.sh --all

# List available group chats
./imessage-wrapped.sh --list-groups

# List top contacts
./imessage-wrapped.sh --list-contacts
```

## Options

| Option | Description |
|--------|-------------|
| `-o, --output FILE` | Specify output HTML filename |
| `-n, --name NAME` | Display name for the contact/group |
| `-y, --your-name NAME` | Your name to display (default: 'You') |
| `--year YEAR` | Year to generate wrapped for (default: 2025) |
| `--group <name>` | Generate wrapped for a group chat |
| `--all` | Generate wrapped for all messages |
| `--list-groups` | List all group chats with message counts |
| `--list-contacts` | List top contacts by message count |
| `-h, --help` | Show help message |

## Examples

```bash
# Individual with custom output file
./imessage-wrapped.sh -n 'Best Friend' -o 'bestie-wrapped.html' '+15551234567'

# Group chat with custom name
./imessage-wrapped.sh --group 'rowers' -n 'Austin Rowing Club' -o 'rowing-wrapped.html'

# Your entire iMessage year
./imessage-wrapped.sh --all -y 'Joshua'

# Generate wrapped for a different year
./imessage-wrapped.sh --year 2024 --all
./imessage-wrapped.sh --year 2023 -n 'Helen' '+15551234567'
```

## Output

The script generates an interactive HTML file that you can open in any browser:

```bash
open your-wrapped-2025.html
```

Navigate through slides by:
- Clicking anywhere on the screen
- Using arrow keys
- Swiping on mobile
- Clicking the navigation dots or arrows

## Privacy

This script runs entirely locally on your machine. No data is sent anywhere - it only reads from your local iMessage database and generates a local HTML file.

## License

MIT
