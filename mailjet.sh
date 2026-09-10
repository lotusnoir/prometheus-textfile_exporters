#!/usr/bin/env bash
#
# mailjet.sh
#
# Prometheus exporter for Mailjet API statistics.
#
# This script:
#   - Queries the Mailjet REST API
#   - Exposes Mailjet message and event statistics
#   - Exposes delivery delay metrics
#   - Exposes Mailjet API availability
#   - Writes Prometheus metrics to stdout
#
# Metrics:
#   - mailjet_up
#   - mailjet_messages_sent_total
#   - mailjet_messages_blocked_total
#   - mailjet_messages_deferred_total
#   - mailjet_messages_hardbounce_total
#   - mailjet_messages_softbounce_total
#   - mailjet_messages_open_total
#   - mailjet_messages_click_total
#   - mailjet_messages_spam_total
#   - mailjet_messages_unsub_total
#   - mailjet_event_open_total
#   - mailjet_event_click_total
#   - mailjet_event_spam_total
#   - mailjet_event_unsub_total
#   - mailjet_open_delay_seconds
#   - mailjet_click_delay_seconds
#   - mailjet_exporter_last_run
#
# Required environment variables:
#   - API_KEY
#   - API_SECRET
#
# Optional environment variables:
#   - None
#
############################################################################

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
# Mailjet Prometheus exporter
#
# Output:
#   Prometheus metrics on stdout
############################################################################

API_KEY=${API_KEY:-unset}
API_SECRET=${API_SECRET:-unset}

BASE_URL="https://api.mailjet.com"

############################################################################
# Timestamp
############################################################################

timestamp=${EPOCHSECONDS:-$(date +%s)}

############################################################################
# Mailjet API
############################################################################

STATS_URL="${BASE_URL}/v3/REST/statcounters?CounterSource=APIKey&CounterTiming=Message&CounterResolution=Lifetime"

if ! stats=$(
    curl -sS \
        --max-time 10 \
        -u "$API_KEY:$API_SECRET" \
        "$STATS_URL"
); then

    cat <<EOF
# HELP mailjet_up Mailjet API availability
# TYPE mailjet_up gauge
mailjet_up 0
EOF

    exit 0
fi

############################################################################
# Extract all values with a single jq
############################################################################

stats_values=$(
    printf '%s\n' "$stats" |
    jq -r '
        .Data[0] // {} |
        [
            (.MessageSentCount // 0),
            (.MessageBlockedCount // 0),
            (.MessageDeferredCount // 0),
            (.MessageHardBouncedCount // 0),
            (.MessageSoftBouncedCount // 0),
            (.MessageOpenedCount // 0),
            (.MessageClickedCount // 0),
            (.MessageSpamCount // 0),
            (.MessageUnsubscribedCount // 0),
            (.EventOpenedCount // 0),
            (.EventClickedCount // 0),
            (.EventSpamCount // 0),
            (.EventUnsubscribedCount // 0),
            (.EventOpenDelay // 0),
            (.EventClickDelay // 0)
        ] |
        @tsv
'
)

############################################################################
# Parse values
############################################################################

IFS=$'\t' read -r \
    message_sent \
    message_blocked \
    message_deferred \
    message_hardbounced \
    message_softbounced \
    message_opened \
    message_clicked \
    message_spam \
    message_unsubscribed \
    event_opened \
    event_clicked \
    event_spam \
    event_unsubscribed \
    event_open_delay \
    event_click_delay <<< "$stats_values"

############################################################################
# Prometheus output
############################################################################

cat <<EOF
# HELP mailjet_up Mailjet API availability
# TYPE mailjet_up gauge
mailjet_up 1

# HELP mailjet_messages_sent_total Total emails sent
# TYPE mailjet_messages_sent_total counter
mailjet_messages_sent_total $message_sent

# HELP mailjet_messages_blocked_total Blocked emails
# TYPE mailjet_messages_blocked_total counter
mailjet_messages_blocked_total $message_blocked

# HELP mailjet_messages_deferred_total Deferred emails
# TYPE mailjet_messages_deferred_total counter
mailjet_messages_deferred_total $message_deferred

# HELP mailjet_messages_hardbounce_total Hard bounces
# TYPE mailjet_messages_hardbounce_total counter
mailjet_messages_hardbounce_total $message_hardbounced

# HELP mailjet_messages_softbounce_total Soft bounces
# TYPE mailjet_messages_softbounce_total counter
mailjet_messages_softbounce_total $message_softbounced

# HELP mailjet_messages_open_total Opens
# TYPE mailjet_messages_open_total counter
mailjet_messages_open_total $message_opened

# HELP mailjet_messages_click_total Clicks
# TYPE mailjet_messages_click_total counter
mailjet_messages_click_total $message_clicked

# HELP mailjet_messages_spam_total Spam complaints
# TYPE mailjet_messages_spam_total counter
mailjet_messages_spam_total $message_spam

# HELP mailjet_messages_unsub_total Unsubscribe events
# TYPE mailjet_messages_unsub_total counter
mailjet_messages_unsub_total $message_unsubscribed

# HELP mailjet_event_open_total Open events
# TYPE mailjet_event_open_total counter
mailjet_event_open_total $event_opened

# HELP mailjet_event_click_total Click events
# TYPE mailjet_event_click_total counter
mailjet_event_click_total $event_clicked

# HELP mailjet_event_spam_total Spam events
# TYPE mailjet_event_spam_total counter
mailjet_event_spam_total $event_spam

# HELP mailjet_event_unsub_total Unsubscribe events
# TYPE mailjet_event_unsub_total counter
mailjet_event_unsub_total $event_unsubscribed

# HELP mailjet_open_delay_seconds Avg delay before open
# TYPE mailjet_open_delay_seconds gauge
mailjet_open_delay_seconds $event_open_delay

# HELP mailjet_click_delay_seconds Avg delay before click
# TYPE mailjet_click_delay_seconds gauge
mailjet_click_delay_seconds $event_click_delay

# HELP mailjet_exporter_last_run Last exporter run timestamp
# TYPE mailjet_exporter_last_run gauge
mailjet_exporter_last_run $timestamp
EOF

exit 0
