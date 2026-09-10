#!/usr/bin/env bash                                                                                                                                                                                                  
#
# postfix_exporter.sh
#
# Collects Postfix mail statistics and exposes them as Prometheus
# metrics on stdout.
#
# Tracks:
#   - sent, bounced, deferred and authentication failures
#   - mail size and delivery delay histograms
#   - SASL authentication failures by user
#   - bounced mails by client and reason
#   - sent mails by sender, SASL user and client
#   - sent mails by sender/recipient domain
#   - sent mails by relay
#   - Postfix queue statistics
#   - Postfix service status
#   - spam burst detection
#
# Log processing is incremental and uses a persistent state file to avoid
# reprocessing previously handled log entries.
#
# Prometheus metrics are written to stdout.
#
###############################################################################

############################################################################
### Defaults
############################################################################

LOG_FILE="/var/log/postfix.log"
STATE_FILE="/var/tmp/postfix.state"
TEMP_STATE="${STATE_FILE}.$$"

# Default values
offset=0
sent_total=0
bounce_total=0
deferred_total=0
auth_fail_total=0
size_1k=0 size_10k=0 size_100k=0 size_1m=0 size_inf=0
delay_1=0 delay_5=0 delay_10=0 delay_30=0 delay_inf=0
last_inode=0

declare -A auth_fail_user_cum
declare -A bounce_by_client_reason_cum
declare -A count_sender_cum
declare -A count_sasl_cum
declare -A count_client_cum
declare -A count_domain_cum
declare -A count_recipient_domain_cum
declare -A count_relay_cum

# ---------------------------------------------------------------------------
# Load previous state
# ---------------------------------------------------------------------------

if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue

        value="${value%\"}"
        value="${value#\"}"

        case "$key" in
            offset) offset=$value ;;
            last_inode) last_inode=$value ;;
            sent_total) sent_total=$value ;;
            bounce_total) bounce_total=$value ;;
            deferred_total) deferred_total=$value ;;
            auth_fail_total) auth_fail_total=$value ;;
            size_1k) size_1k=$value ;;
            size_10k) size_10k=$value ;;
            size_100k) size_100k=$value ;;
            size_1m) size_1m=$value ;;
            size_inf) size_inf=$value ;;
            delay_1) delay_1=$value ;;
            delay_5) delay_5=$value ;;
            delay_10) delay_10=$value ;;
            delay_30) delay_30=$value ;;
            delay_inf) delay_inf=$value ;;
            auth_fail_user_cum) eval "auth_fail_user_cum=$value" ;;
            bounce_by_client_reason_cum) eval "bounce_by_client_reason_cum=$value" ;;
            count_sender_cum) eval "count_sender_cum=$value" ;;
            count_sasl_cum) eval "count_sasl_cum=$value" ;;
            count_client_cum) eval "count_client_cum=$value" ;;
            count_domain_cum) eval "count_domain_cum=$value" ;;
            count_recipient_domain_cum) eval "count_recipient_domain_cum=$value" ;;
            count_relay_cum) eval "count_relay_cum=$value" ;;
        esac
    done < "$STATE_FILE"
fi

# ---------------------------------------------------------------------------
# Log rotation detection
# ---------------------------------------------------------------------------

current_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
current_inode=$(stat -c %i "$LOG_FILE" 2>/dev/null || echo 0)

if (( current_size < offset )); then
    offset=0
fi

if [[ "$current_inode" != "$last_inode" && "$last_inode" != "0" ]]; then
    offset=0
fi

last_inode=$current_inode

# ---------------------------------------------------------------------------
# Incremental counters
# ---------------------------------------------------------------------------

sent_inc=0
bounce_inc=0
deferred_inc=0
auth_fail_inc=0

size_1k_inc=0
size_10k_inc=0
size_100k_inc=0
size_1m_inc=0
size_inf_inc=0

delay_1_inc=0
delay_5_inc=0
delay_10_inc=0
delay_30_inc=0
delay_inf_inc=0

declare -A auth_fail_user_inc
declare -A bounce_by_client_reason_inc
declare -A count_sender_inc
declare -A count_sasl_inc
declare -A count_client_inc
declare -A count_domain_inc
declare -A count_recipient_domain_inc
declare -A count_relay_inc

# ---------------------------------------------------------------------------
# Process new log data
# ---------------------------------------------------------------------------

if (( offset < current_size )); then

    dd if="$LOG_FILE" bs=1 skip="$offset" 2>/dev/null |
    awk '
    BEGIN {
        sent=0
        bounce=0
        deferred=0
        auth_fail=0

        size_1k=0
        size_10k=0
        size_100k=0
        size_1m=0
        size_inf=0

        delay_1=0
        delay_5=0
        delay_10=0
        delay_30=0
        delay_inf=0
    }

    {
        line = $0

        # Queue ID
        qid = ""
        if (match(line, /postfix\/[a-z]+\[[0-9]+\]: [A-F0-9]+:/)) {
            start = RSTART + index(substr(line, RSTART), ": ") + 1
            end = index(substr(line, start), ":") - 1

            if (end > 0)
                qid = substr(line, start, end)
        }

        # Message size from qmgr
        if (qid != "" &&
            index(line, "postfix/qmgr") > 0 &&
            index(line, "size=") > 0) {

            pos = index(line, "size=")
            size_part = substr(line, pos + 5)

            match(size_part, /^[0-9]+/)

            if (RLENGTH > 0)
                size_by_qid[qid] = substr(size_part, 1, RLENGTH) + 0
        }

        # Status lines
        if (index(line, "status=") > 0) {

            if (qid != "" && qid in size_by_qid) {
                size = size_by_qid[qid]
                delete size_by_qid[qid]
            } else {
                size = ""
            }

            # Delay
            pos = index(line, "delay=")

            if (pos > 0) {
                delay_part = substr(line, pos + 6)

                match(delay_part, /^[0-9.]+/)

                if (RLENGTH > 0) {
                    delay = substr(delay_part, 1, RLENGTH) + 0.5
                    d = int(delay)

                    if (d < 1)
                        delay_1++
                    else if (d < 5)
                        delay_5++
                    else if (d < 10)
                        delay_10++
                    else if (d < 30)
                        delay_30++
                    else
                        delay_inf++
                }
            }

            # Sent
            if (index(line, "status=sent") > 0) {

                sent++

                if (size != "") {
                    if (size < 1024)
                        size_1k++
                    else if (size < 10240)
                        size_10k++
                    else if (size < 102400)
                        size_100k++
                    else if (size < 1048576)
                        size_1m++
                    else
                        size_inf++
                }

                # Sender
                pos = index(line, "from=<")

                if (pos > 0) {
                    from = substr(line, pos + 6)
                    gsub(/>.*$/, "", from)

                    if (from != "") {
                        sender_count[from]++

                        at_pos = index(from, "@")

                        if (at_pos > 0) {
                            domain = substr(from, at_pos + 1)
                            domain_count[domain]++
                        }
                    }
                }

                # Recipient
                pos = index(line, "to=<")

                if (pos > 0) {
                    to = substr(line, pos + 4)
                    gsub(/>.*$/, "", to)

                    if (to != "") {
                        at_pos = index(to, "@")

                        if (at_pos > 0) {
                            recip_domain = substr(to, at_pos + 1)
                            recip_domain_count[recip_domain]++
                        }
                    }
                }

                # Relay
                pos = index(line, "relay=")

                if (pos > 0) {
                    relay = substr(line, pos + 6)
                    gsub(/[,[:space:]].*$/, "", relay)
                    gsub(/\[[0-9.]+\]|[0-9.]+/, "", relay)
                    gsub(/:[0-9]+$/, "", relay)

                    if (relay != "")
                        relay_count[relay]++
                }

                # SASL username
                pos = index(line, "sasl_username=")

                if (pos > 0) {
                    sasl = substr(line, pos + 14)
                    gsub(/[[:space:]].*$/, "", sasl)
                    gsub(/[<>"]/, "", sasl)

                    if (sasl != "")
                        sasl_count[sasl]++
                }

                # Client
                pos = index(line, "client=")

                if (pos > 0) {
                    client = substr(line, pos + 7)
                    gsub(/[,[:space:]].*$/, "", client)
                    gsub(/[\[\]]/, "", client)

                    if (client != "")
                        client_count[client]++
                }
            }

            # Bounced
            else if (index(line, "status=bounced") > 0) {

                bounce++

                reason = "unknown"

                pos = index(line, " (")

                if (pos > 0) {
                    end = index(substr(line, pos + 2), ")")

                    if (end > 0)
                        reason = substr(line, pos + 2, end - 1)
                }

                client = "unknown"

                pos = index(line, "to=<")

                if (pos > 0) {
                    client = substr(line, pos + 4)
                    gsub(/>.*$/, "", client)
                }

                key = client "|" reason
                bounce_count[key]++
            }

            # Deferred
            else if (index(line, "status=deferred") > 0) {
                deferred++
            }
        }

        # Authentication failures
        if (index(line, "authentication failure") > 0) {

            auth_fail++

            pos = index(line, "sasl_username=")

            if (pos > 0) {
                user = substr(line, pos + 14)
                gsub(/[[:space:]].*$/, "", user)
                gsub(/[<>"]/, "", user)

                if (user != "")
                    auth_fail_user_count[user]++
            }
        }
    }

    END {
        print sent
        print bounce
        print deferred
        print auth_fail

        print size_1k
        print size_10k
        print size_100k
        print size_1m
        print size_inf

        print delay_1
        print delay_5
        print delay_10
        print delay_30
        print delay_inf

        for (u in auth_fail_user_count)
            print "auth_fail_user:" u "=" auth_fail_user_count[u]

        for (b in bounce_count)
            print "bounce_reason:" b "=" bounce_count[b]

        for (s in sender_count)
            print "sender:" s "=" sender_count[s]

        for (s in sasl_count)
            print "sasl:" s "=" sasl_count[s]

        for (c in client_count)
            print "client:" c "=" client_count[c]

        for (d in domain_count)
            print "domain:" d "=" domain_count[d]

        for (r in recip_domain_count)
            print "recip_domain:" r "=" recip_domain_count[r]

        for (r in relay_count)
            print "relay:" r "=" relay_count[r]
    }' > "${TEMP_STATE}.counts"

    if [[ -s "${TEMP_STATE}.counts" ]]; then

        {
            read sent_inc
            read bounce_inc
            read deferred_inc
            read auth_fail_inc

            read size_1k_inc
            read size_10k_inc
            read size_100k_inc
            read size_1m_inc
            read size_inf_inc

            read delay_1_inc
            read delay_5_inc
            read delay_10_inc
            read delay_30_inc
            read delay_inf_inc

            while IFS= read -r line; do

                case "$line" in

                    auth_fail_user:*)
                        key="${line#auth_fail_user:}"
                        auth_fail_user_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    bounce_reason:*)
                        key="${line#bounce_reason:}"
                        bounce_by_client_reason_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    sender:*)
                        key="${line#sender:}"
                        count_sender_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    sasl:*)
                        key="${line#sasl:}"
                        count_sasl_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    client:*)
                        key="${line#client:}"
                        count_client_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    domain:*)
                        key="${line#domain:}"
                        count_domain_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    recip_domain:*)
                        key="${line#recip_domain:}"
                        count_recipient_domain_inc["${key%%=*}"]="${key#*=}"
                        ;;

                    relay:*)
                        key="${line#relay:}"
                        count_relay_inc["${key%%=*}"]="${key#*=}"
                        ;;

                esac

            done
        } < "${TEMP_STATE}.counts"

    fi

    rm -f "${TEMP_STATE}.counts"

    # Update totals
    sent_total=$((sent_total + sent_inc))
    bounce_total=$((bounce_total + bounce_inc))
    deferred_total=$((deferred_total + deferred_inc))
    auth_fail_total=$((auth_fail_total + auth_fail_inc))

    size_1k=$((size_1k + size_1k_inc))
    size_10k=$((size_10k + size_10k_inc))
    size_100k=$((size_100k + size_100k_inc))
    size_1m=$((size_1m + size_1m_inc))
    size_inf=$((size_inf + size_inf_inc))

    delay_1=$((delay_1 + delay_1_inc))
    delay_5=$((delay_5 + delay_5_inc))
    delay_10=$((delay_10 + delay_10_inc))
    delay_30=$((delay_30 + delay_30_inc))
    delay_inf=$((delay_inf + delay_inf_inc))

    # Update labelled counters
    for key in "${!auth_fail_user_inc[@]}"; do
        auth_fail_user_cum["$key"]=$(
            ((${auth_fail_user_cum["$key"]:-0} + auth_fail_user_inc["$key"]))
        )
    done

    for key in "${!bounce_by_client_reason_inc[@]}"; do
        bounce_by_client_reason_cum["$key"]=$(
            ((${bounce_by_client_reason_cum["$key"]:-0} + bounce_by_client_reason_inc["$key"]))
        )
    done

    for key in "${!count_sender_inc[@]}"; do
        count_sender_cum["$key"]=$(
            ((${count_sender_cum["$key"]:-0} + count_sender_inc["$key"]))
        )
    done

    for key in "${!count_sasl_inc[@]}"; do
        count_sasl_cum["$key"]=$(
            ((${count_sasl_cum["$key"]:-0} + count_sasl_inc["$key"]))
        )
    done

    for key in "${!count_client_inc[@]}"; do
        count_client_cum["$key"]=$(
            ((${count_client_cum["$key"]:-0} + count_client_inc["$key"]))
        )
    done

    for key in "${!count_domain_inc[@]}"; do
        count_domain_cum["$key"]=$(
            ((${count_domain_cum["$key"]:-0} + count_domain_inc["$key"]))
        )
    done

    for key in "${!count_recipient_domain_inc[@]}"; do
        count_recipient_domain_cum["$key"]=$(
            ((${count_recipient_domain_cum["$key"]:-0} + count_recipient_domain_inc["$key"]))
        )
    done

    for key in "${!count_relay_inc[@]}"; do
        count_relay_cum["$key"]=$(
            ((${count_relay_cum["$key"]:-0} + count_relay_inc["$key"]))
        )
    done

    offset=$current_size
fi

# ---------------------------------------------------------------------------
# Current Postfix queue
# ---------------------------------------------------------------------------

queue_output=$(postqueue -p 2>/dev/null || true)

queue_active=$(awk '
    /^[A-F0-9]/ { count++ }
    END { print count+0 }
' <<< "$queue_output")

queue_deferred=$(grep -c "deferred" <<< "$queue_output" || true)
queue_age=$(grep -oP '(?<=in queue for )[0-9]+' <<< "$queue_output" | head -1)
queue_age=${queue_age:-0}

# ---------------------------------------------------------------------------
# Other metrics
# ---------------------------------------------------------------------------

spam_burst=0
if (( sent_inc >= 100 )); then
    spam_burst=1
fi

if systemctl is-active --quiet postfix; then
    POSTFIX_STATUS=1
else
    POSTFIX_STATUS=0
fi

# ---------------------------------------------------------------------------
# Prometheus output -> STDOUT
# ---------------------------------------------------------------------------

echo "# HELP postfix_up (1 = active / 0 = down)"
echo "# TYPE postfix_up gauge"
echo "postfix_up $POSTFIX_STATUS"

echo "# HELP postfix_mail_sent_total Total number of sent emails"
echo "# TYPE postfix_mail_sent_total counter"
echo "postfix_mail_sent_total $sent_total"

echo "# HELP postfix_mail_bounced_total Total number of bounced emails"
echo "# TYPE postfix_mail_bounced_total counter"
echo "postfix_mail_bounced_total $bounce_total"

echo "# HELP postfix_mail_deferred_total Total number of deferred emails"
echo "# TYPE postfix_mail_deferred_total counter"
echo "postfix_mail_deferred_total $deferred_total"

echo "# HELP postfix_sasl_auth_fail_total Total number of SASL authentication failures"
echo "# TYPE postfix_sasl_auth_fail_total counter"
echo "postfix_sasl_auth_fail_total $auth_fail_total"

echo "# HELP postfix_queue_active Current number of active queue items"
echo "# TYPE postfix_queue_active gauge"
echo "postfix_queue_active $queue_active"

echo "# HELP postfix_queue_deferred Current number of deferred queue items"
echo "# TYPE postfix_queue_deferred gauge"
echo "postfix_queue_deferred $queue_deferred"

echo "# HELP postfix_queue_age_seconds Age of oldest message in queue"
echo "# TYPE postfix_queue_age_seconds gauge"
echo "postfix_queue_age_seconds $queue_age"

echo "# HELP postfix_spam_burst Indicates if spam burst detected (1 if sent > 100 in last interval)"
echo "# TYPE postfix_spam_burst gauge"
echo "postfix_spam_burst $spam_burst"

# Per-user auth failures
if (( ${#auth_fail_user_cum[@]} > 0 )); then
    echo "# HELP postfix_sasl_auth_fail_by_user_total Total SASL authentication failures by user"
    echo "# TYPE postfix_sasl_auth_fail_by_user_total counter"

    for u in "${!auth_fail_user_cum[@]}"; do
        echo "postfix_sasl_auth_fail_by_user_total{user=\"$u\"} ${auth_fail_user_cum[$u]}"
    done
fi

# Bounce by client/reason
if (( ${#bounce_by_client_reason_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_bounced_by_client_total Total bounced emails by client and reason"
    echo "# TYPE postfix_mail_bounced_by_client_total counter"

    for key in "${!bounce_by_client_reason_cum[@]}"; do
        client="${key%%|*}"
        reason="${key#*|}"

        echo "postfix_mail_bounced_by_client_total{client=\"$client\",reason=\"$reason\"} ${bounce_by_client_reason_cum[$key]}"
    done
fi

# Per sender
if (( ${#count_sender_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_sender_total Total sent emails by sender"
    echo "# TYPE postfix_mail_sent_by_sender_total counter"

    for k in "${!count_sender_cum[@]}"; do
        echo "postfix_mail_sent_by_sender_total{sender=\"$k\"} ${count_sender_cum[$k]}"
    done
fi

# Per SASL user
if (( ${#count_sasl_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_user_total Total sent emails by SASL user"
    echo "# TYPE postfix_mail_sent_by_user_total counter"

    for k in "${!count_sasl_cum[@]}"; do
        echo "postfix_mail_sent_by_user_total{user=\"$k\"} ${count_sasl_cum[$k]}"
    done
fi

# Per client
if (( ${#count_client_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_client_total Total sent emails by client"
    echo "# TYPE postfix_mail_sent_by_client_total counter"

    for k in "${!count_client_cum[@]}"; do
        echo "postfix_mail_sent_by_client_total{client=\"$k\"} ${count_client_cum[$k]}"
    done
fi

# Per sender domain
if (( ${#count_domain_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_sender_domain_total Total sent emails by sender domain"
    echo "# TYPE postfix_mail_sent_by_sender_domain_total counter"

    for k in "${!count_domain_cum[@]}"; do
        echo "postfix_mail_sent_by_sender_domain_total{domain=\"$k\"} ${count_domain_cum[$k]}"
    done
fi

# Per recipient domain
if (( ${#count_recipient_domain_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_recipient_domain_total Total sent emails by recipient domain"
    echo "# TYPE postfix_mail_sent_by_recipient_domain_total counter"

    for k in "${!count_recipient_domain_cum[@]}"; do
        echo "postfix_mail_sent_by_recipient_domain_total{domain=\"$k\"} ${count_recipient_domain_cum[$k]}"
    done
fi

# Relays
if (( ${#count_relay_cum[@]} > 0 )); then
    echo "# HELP postfix_mail_sent_by_relay_total Total sent emails by relay"
    echo "# TYPE postfix_mail_sent_by_relay_total counter"

    for k in "${!count_relay_cum[@]}"; do
        echo "postfix_mail_sent_by_relay_total{relay=\"$k\"} ${count_relay_cum[$k]}"
    done
fi

# Size histogram
echo "# HELP postfix_mail_size_bytes Distribution of email sizes"
echo "# TYPE postfix_mail_size_bytes histogram"
echo "postfix_mail_size_bytes_bucket{le=\"1024\"} $size_1k"
echo "postfix_mail_size_bytes_bucket{le=\"10240\"} $size_10k"
echo "postfix_mail_size_bytes_bucket{le=\"102400\"} $size_100k"
echo "postfix_mail_size_bytes_bucket{le=\"1048576\"} $size_1m"
echo "postfix_mail_size_bytes_bucket{le=\"+Inf\"} $size_inf"
echo "postfix_mail_size_bytes_count $sent_total"
echo "postfix_mail_size_bytes_sum 0"

# Delay histogram
echo "# HELP postfix_mail_delay_seconds Distribution of email delays"
echo "# TYPE postfix_mail_delay_seconds histogram"
echo "postfix_mail_delay_seconds_bucket{le=\"1\"} $delay_1"
echo "postfix_mail_delay_seconds_bucket{le=\"5\"} $delay_5"
echo "postfix_mail_delay_seconds_bucket{le=\"10\"} $delay_10"
echo "postfix_mail_delay_seconds_bucket{le=\"30\"} $delay_30"
echo "postfix_mail_delay_seconds_bucket{le=\"+Inf\"} $delay_inf"
echo "postfix_mail_delay_seconds_count $sent_total"
echo "postfix_mail_delay_seconds_sum 0"

# ---------------------------------------------------------------------------
# Save state
# ---------------------------------------------------------------------------

{
    echo "offset=$offset"
    echo "last_inode=$last_inode"
    echo "sent_total=$sent_total"
    echo "bounce_total=$bounce_total"
    echo "deferred_total=$deferred_total"
    echo "auth_fail_total=$auth_fail_total"

    echo "size_1k=$size_1k"
    echo "size_10k=$size_10k"
    echo "size_100k=$size_100k"
    echo "size_1m=$size_1m"
    echo "size_inf=$size_inf"

    echo "delay_1=$delay_1"
    echo "delay_5=$delay_5"
    echo "delay_10=$delay_10"
    echo "delay_30=$delay_30"
    echo "delay_inf=$delay_inf"

    if (( ${#auth_fail_user_cum[@]} > 0 )); then
        declare -p auth_fail_user_cum | sed 's/declare -A //'
    fi

    if (( ${#bounce_by_client_reason_cum[@]} > 0 )); then
        declare -p bounce_by_client_reason_cum | sed 's/declare -A //'
    fi

    if (( ${#count_sender_cum[@]} > 0 )); then
        declare -p count_sender_cum | sed 's/declare -A //'
    fi

    if (( ${#count_sasl_cum[@]} > 0 )); then
        declare -p count_sasl_cum | sed 's/declare -A //'
    fi

    if (( ${#count_client_cum[@]} > 0 )); then
        declare -p count_client_cum | sed 's/declare -A //'
    fi

    if (( ${#count_domain_cum[@]} > 0 )); then
        declare -p count_domain_cum | sed 's/declare -A //'
    fi

    if (( ${#count_recipient_domain_cum[@]} > 0 )); then
        declare -p count_recipient_domain_cum | sed 's/declare -A //'
    fi

    if (( ${#count_relay_cum[@]} > 0 )); then
        declare -p count_relay_cum | sed 's/declare -A //'
    fi

    echo "# State saved at $(date)"

} > "$TEMP_STATE"

mv "$TEMP_STATE" "$STATE_FILE"
