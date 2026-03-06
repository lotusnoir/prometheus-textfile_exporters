#!/usr/bin/env bash

LOG_FILE="/var/log/postfix.log"
STATE_FILE="/var/lib/node_exporter/postfix.state"

declare -A sender
declare -A recipient
declare -A relay
declare -A size
declare -A delay
declare -A sasl
declare -A client

declare -A count_sasl
declare -A count_client
declare -A count_domain
declare -A count_recipient_domain
declare -A count_relay
declare -A count_sender
declare -A auth_fail_user

# bounce by client + reason
declare -A bounce_by_client_reason

sent_total=0
bounce_total=0
deferred_total=0
auth_fail_total=0

spam_threshold=100
spam_burst=0

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

queue_active=0
queue_deferred=0
queue_age=0

# load last position
if [[ -f "$STATE_FILE" ]]; then
    last_line=$(cat "$STATE_FILE")
else
    last_line=0
fi

total_lines=$(wc -l < "$LOG_FILE")

if (( total_lines < last_line )); then
    last_line=0
fi

current=0

while read -r line; do
    ((current++))

    # authentication failure detection
    if [[ "$line" =~ authentication\ failure ]]; then
        ((auth_fail_total++))

        if [[ "$line" =~ sasl_username=([^[:space:]]+) ]]; then
            u="${BASH_REMATCH[1]}"
            ((auth_fail_user[$u]++))
        fi
    fi

    # queue id extraction
    if [[ $line =~ postfix/[a-z]+\[[0-9]+\]:\ ([A-F0-9]+): ]]; then
        qid="${BASH_REMATCH[1]}"
    else
        continue
    fi

    [[ "$line" =~ from=\<([^>]*)\> ]] && sender[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ to=\<([^>]*)\> ]] && recipient[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ relay=([^,\[]+) ]] && relay[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ size=([0-9]+) ]] && size[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ delay=([0-9.]+) ]] && delay[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ sasl_username=([^[:space:]]+) ]] && sasl[$qid]="${BASH_REMATCH[1]}"
    [[ "$line" =~ client=([^[]+) ]] && client[$qid]="${BASH_REMATCH[1]}"

# bounce detection (with reason and client = recipient)
if [[ "$line" =~ status=bounced ]]; then
    ((bounce_total++))

    # client = recipient address (to=<...>)
    cl="${recipient[$qid]}"
    reason=$(echo "$line" | grep -oP '\([^)]+\)' | head -1)

    if [[ -z "$reason" ]]; then
        reason="unknown"
    else
        # strip parentheses
        reason="${reason:1:-1}"
    fi

    if [[ -n "$cl" ]]; then
        key="${cl}|${reason}"
        ((bounce_by_client_reason[$key]++))
    else
        key="unknown|${reason}"
        ((bounce_by_client_reason[$key]++))
    fi
fi

    if [[ "$line" =~ status=sent ]]; then

        ((sent_total++))

        s="${sender[$qid]}"
        r="${recipient[$qid]}"
        rel="${relay[$qid]}"
        user="${sasl[$qid]}"
        cl="${client[$qid]}"
        sz="${size[$qid]}"
        dl="${delay[$qid]}"

        [[ -n "$s" ]] && ((count_sender[$s]++))
        [[ -n "$user" ]] && ((count_sasl[$user]++))
        [[ -n "$cl" ]] && ((count_client[$cl]++))
        [[ -n "$rel" ]] && ((count_relay[$rel]++))

        if [[ "$s" =~ @(.+) ]]; then
            ((count_domain["${BASH_REMATCH[1]}"]++))
        fi

        if [[ "$r" =~ @(.+) ]]; then
            ((count_recipient_domain["${BASH_REMATCH[1]}"]++))
        fi

        if [[ -n "$sz" ]]; then
            if (( sz < 1024 )); then ((size_1k++))
            elif (( sz < 10240 )); then ((size_10k++))
            elif (( sz < 102400 )); then ((size_100k++))
            elif (( sz < 1048576 )); then ((size_1m++))
            else ((size_inf++))
            fi
        fi

        if [[ -n "$dl" ]]; then
            d=$(printf "%.0f" "$dl")

            if (( d < 1 )); then ((delay_1++))
            elif (( d < 5 )); then ((delay_5++))
            elif (( d < 10 )); then ((delay_10++))
            elif (( d < 30 )); then ((delay_30++))
            else ((delay_inf++))
            fi
        fi

    fi

    [[ "$line" =~ status=deferred ]] && ((deferred_total++))

done < <(tail -n +"$((last_line + 1))" "$LOG_FILE")

# spam burst detection
if (( sent_total >= spam_threshold )); then
    spam_burst=1
else
    spam_burst=0
fi

# queue metrics
queue_active=$(postqueue -p 2>/dev/null | grep -c "^[A-F0-9]")
queue_deferred=$(postqueue -p 2>/dev/null | grep -c "deferred")

# queue age (approx)
queue_age=$(postqueue -p 2>/dev/null | grep -oP '(?<=in queue for )[0-9]+')

if [[ -z "$queue_age" ]]; then
    queue_age=0
fi

# output metrics (stdout)
echo "# TYPE postfix_mail_sent_total counter"
echo "postfix_mail_sent_total $sent_total"

echo "# TYPE postfix_mail_bounced_total counter"
echo "postfix_mail_bounced_total $bounce_total"

echo "# TYPE postfix_mail_deferred_total counter"
echo "postfix_mail_deferred_total $deferred_total"

echo "# TYPE postfix_sasl_auth_fail_total counter"
echo "postfix_sasl_auth_fail_total $auth_fail_total"

echo "# TYPE postfix_queue_active gauge"
echo "postfix_queue_active $queue_active"

echo "# TYPE postfix_queue_deferred gauge"
echo "postfix_queue_deferred $queue_deferred"

echo "# TYPE postfix_queue_age_seconds gauge"
echo "postfix_queue_age_seconds $queue_age"

echo "# TYPE postfix_spam_burst gauge"
echo "postfix_spam_burst $spam_burst"

# per-user auth failures
echo "# TYPE postfix_sasl_auth_fail_by_user_total counter"
for u in "${!auth_fail_user[@]}"; do
echo "postfix_sasl_auth_fail_by_user_total{user=\"$u\"} ${auth_fail_user[$u]}"
done

# per-sender full email metric
echo "# TYPE postfix_mail_sent_by_sender_total counter"
for k in "${!count_sender[@]}"; do
echo "postfix_mail_sent_by_sender_total{sender=\"$k\"} ${count_sender[$k]}"
done

# per-user sent
echo "# TYPE postfix_mail_sent_by_user_total counter"
for k in "${!count_sasl[@]}"; do
echo "postfix_mail_sent_by_user_total{user=\"$k\"} ${count_sasl[$k]}"
done

# per-client sent
echo "# TYPE postfix_mail_sent_by_client_total counter"
for k in "${!count_client[@]}"; do
echo "postfix_mail_sent_by_client_total{client=\"$k\"} ${count_client[$k]}"
done

# per-domain
echo "# TYPE postfix_mail_sent_by_sender_domain_total counter"
for k in "${!count_domain[@]}"; do
echo "postfix_mail_sent_by_sender_domain_total{domain=\"$k\"} ${count_domain[$k]}"
done

echo "# TYPE postfix_mail_sent_by_recipient_domain_total counter"
for k in "${!count_recipient_domain[@]}"; do
echo "postfix_mail_sent_by_recipient_domain_total{domain=\"$k\"} ${count_recipient_domain[$k]}"
done

# relays
echo "# TYPE postfix_mail_sent_by_relay_total counter"
for k in "${!count_relay[@]}"; do
echo "postfix_mail_sent_by_relay_total{relay=\"$k\"} ${count_relay[$k]}"
done

# bounce by client and reason
echo "# TYPE postfix_mail_bounced_by_client_total counter"
for k in "${!bounce_by_client_reason[@]}"; do
    client=$(echo "$k" | cut -d'|' -f1)
    reason=$(echo "$k" | cut -d'|' -f2)
    val=${bounce_by_client_reason[$k]}
    echo "postfix_mail_bounced_by_client_total{client=\"$client\",reason=\"$reason\"} $val"
done

# size histogram
echo "# TYPE postfix_mail_size_bytes_bucket counter"
echo "postfix_mail_size_bytes_bucket{le=\"1k\"} $size_1k"
echo "postfix_mail_size_bytes_bucket{le=\"10k\"} $size_10k"
echo "postfix_mail_size_bytes_bucket{le=\"100k\"} $size_100k"
echo "postfix_mail_size_bytes_bucket{le=\"1M\"} $size_1m"
echo "postfix_mail_size_bytes_bucket{le=\"+Inf\"} $size_inf"

# delay histogram
echo "# TYPE postfix_mail_delay_seconds_bucket counter"
echo "postfix_mail_delay_seconds_bucket{le=\"1\"} $delay_1"
echo "postfix_mail_delay_seconds_bucket{le=\"5\"} $delay_5"
echo "postfix_mail_delay_seconds_bucket{le=\"10\"} $delay_10"
echo "postfix_mail_delay_seconds_bucket{le=\"30\"} $delay_30"
echo "postfix_mail_delay_seconds_bucket{le=\"+Inf\"} $delay_inf"

# update state
echo "$total_lines" > "$STATE_FILE"
