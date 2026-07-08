#!/bin/bash
# Setup auto-reminder cron job
# Runs every 5 minutes to check and remind agents

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMINDER_SCRIPT="$SCRIPT_DIR/reminder.sh"
CRON_LOG="$SCRIPT_DIR/shared/state/cron.log"

echo "Setting up auto-reminder cron job..."

# Create cron entry
CRON_ENTRY="*/5 * * * * cd $SCRIPT_DIR && $REMINDER_SCRIPT B >> $CRON_LOG 2>&1"

# Check if already exists
if crontab -l 2>/dev/null | grep -q "reminder.sh"; then
    echo "Cron job already exists!"
    crontab -l | grep "reminder.sh"
else
    # Add to crontab
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "Added cron job:"
    echo "$CRON_ENTRY"
fi

echo ""
echo "To view: crontab -l"
echo "To remove: crontab -l | grep -v reminder.sh | crontab -"
echo "Logs: $CRON_LOG"
