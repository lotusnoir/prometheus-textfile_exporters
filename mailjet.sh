#!/usr/bin/env bash

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
# --- Variables avec surcharge possible via ENV ---

API_KEY=${API_KEY:-unset}
API_SECRET=${API_SECRET:-unset}

OUT=${OUT:-/var/lib/node_exporter/mailjet.prom}
TMP="${OUT}.tmp"

BASE_URL="https://api.mailjet.com"

############################################################################
timestamp=$(date +%s)

curl_json() {
    curl -s -u "$API_KEY:$API_SECRET" "$1"
}

echo "# HELP mailjet_up Mailjet API availability" > "$TMP"
echo "# TYPE mailjet_up gauge" >> "$TMP"

if ! curl -s --max-time 10 -u "$API_KEY:$API_SECRET" "$BASE_URL/v3/REST/statcounters" >/dev/null; then
    echo "mailjet_up 0" >> "$TMP"
    mv "$TMP" "$OUT"
    exit 0
fi

echo "mailjet_up 1" >> "$TMP"


############################################
# Global statistics
############################################

stats=$(curl_json \
"$BASE_URL/v3/REST/statcounters?CounterSource=APIKey&CounterTiming=Message&CounterResolution=Lifetime")

get() {
    echo "$stats" | jq -r ".Data[0].$1 // 0"
}

echo "# HELP mailjet_messages_sent_total Total emails sent" >> "$TMP"
echo "# TYPE mailjet_messages_sent_total counter" >> "$TMP"
echo "mailjet_messages_sent_total $(get MessageSentCount)" >> "$TMP"

echo "# HELP mailjet_messages_blocked_total Blocked emails" >> "$TMP"
echo "# TYPE mailjet_messages_blocked_total counter" >> "$TMP"
echo "mailjet_messages_blocked_total $(get MessageBlockedCount)" >> "$TMP"

echo "# HELP mailjet_messages_deferred_total Deferred emails" >> "$TMP"
echo "# TYPE mailjet_messages_deferred_total counter" >> "$TMP"
echo "mailjet_messages_deferred_total $(get MessageDeferredCount)" >> "$TMP"

echo "# HELP mailjet_messages_hardbounce_total Hard bounces" >> "$TMP"
echo "# TYPE mailjet_messages_hardbounce_total counter" >> "$TMP"
echo "mailjet_messages_hardbounce_total $(get MessageHardBouncedCount)" >> "$TMP"

echo "# HELP mailjet_messages_softbounce_total Soft bounces" >> "$TMP"
echo "# TYPE mailjet_messages_softbounce_total counter" >> "$TMP"
echo "mailjet_messages_softbounce_total $(get MessageSoftBouncedCount)" >> "$TMP"

echo "# HELP mailjet_messages_open_total Opens" >> "$TMP"
echo "# TYPE mailjet_messages_open_total counter" >> "$TMP"
echo "mailjet_messages_open_total $(get MessageOpenedCount)" >> "$TMP"

echo "# HELP mailjet_messages_click_total Clicks" >> "$TMP"
echo "# TYPE mailjet_messages_click_total counter" >> "$TMP"
echo "mailjet_messages_click_total $(get MessageClickedCount)" >> "$TMP"

echo "# HELP mailjet_messages_spam_total Spam complaints" >> "$TMP"
echo "# TYPE mailjet_messages_spam_total counter" >> "$TMP"
echo "mailjet_messages_spam_total $(get MessageSpamCount)" >> "$TMP"

echo "# HELP mailjet_messages_unsub_total Unsubscribe events" >> "$TMP"
echo "# TYPE mailjet_messages_unsub_total counter" >> "$TMP"
echo "mailjet_messages_unsub_total $(get MessageUnsubscribedCount)" >> "$TMP"

############################################
# Event metrics
############################################

echo "# HELP mailjet_event_open_total Open events" >> "$TMP"
echo "# TYPE mailjet_event_open_total counter" >> "$TMP"
echo "mailjet_event_open_total $(get EventOpenedCount)" >> "$TMP"

echo "# HELP mailjet_event_click_total Click events" >> "$TMP"
echo "# TYPE mailjet_event_click_total counter" >> "$TMP"
echo "mailjet_event_click_total $(get EventClickedCount)" >> "$TMP"

echo "# HELP mailjet_event_spam_total Spam events" >> "$TMP"
echo "# TYPE mailjet_event_spam_total counter" >> "$TMP"
echo "mailjet_event_spam_total $(get EventSpamCount)" >> "$TMP"

echo "# HELP mailjet_event_unsub_total Unsubscribe events" >> "$TMP"
echo "# TYPE mailjet_event_unsub_total counter" >> "$TMP"
echo "mailjet_event_unsub_total $(get EventUnsubscribedCount)" >> "$TMP"

############################################
# Delay metrics
############################################

echo "# HELP mailjet_open_delay_seconds Avg delay before open" >> "$TMP"
echo "# TYPE mailjet_open_delay_seconds gauge" >> "$TMP"
echo "mailjet_open_delay_seconds $(get EventOpenDelay)" >> "$TMP"

echo "# HELP mailjet_click_delay_seconds Avg delay before click" >> "$TMP"
echo "# TYPE mailjet_click_delay_seconds gauge" >> "$TMP"
echo "mailjet_click_delay_seconds $(get EventClickDelay)" >> "$TMP"

############################################
# Timestamp
############################################

echo "# HELP mailjet_exporter_last_run Last exporter run timestamp" >> "$TMP"
echo "# TYPE mailjet_exporter_last_run gauge" >> "$TMP"
echo "mailjet_exporter_last_run $timestamp" >> "$TMP"

mv "$TMP" "$OUT"
