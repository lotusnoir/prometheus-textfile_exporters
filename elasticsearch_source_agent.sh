#!/bin/bash

# Simple one-shot metrics output
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
INDEX_PATTERN="${INDEX_PATTERN:-.ds-logs*}"
USERNAME="${USERNAME:-elastic}"
PASSWORD="${PASSWORD:-}"
TIME_RANGE="${TIME_RANGE:-24h}"

# Get metrics and format for Prometheus
echo "# HELP elasticsearch_source_agent Number of documents per agent hostname in last ${TIME_RANGE}"
echo "# TYPE elasticsearch_source_agent gauge"

curl -s -u "$USERNAME:$PASSWORD" -X GET "$ELASTICSEARCH_URL/$INDEX_PATTERN/_search" -H 'Content-Type: application/json' -d'
{
  "size": 0,
  "query": {
    "range": {
      "@timestamp": {
        "gte": "now-'${TIME_RANGE}'"
      }
    }
  },
  "aggs": {
    "distinct_agent_names": {
      "terms": {
        "field": "agent.name", 
        "size": 2000
      }
    }
  }
}' | jq -r '.aggregations.distinct_agent_names.buckets[] | "elasticsearch_source_agent{hostname=\"" + (.key | gsub("\""; "\\\"")) + "\"} " + (.doc_count | tostring)' | sort -u
