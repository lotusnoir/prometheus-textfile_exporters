#!/usr/bin/env bash
#===============================================================================
#         FILE:  terragrunt_project_status.sh
#
#        USAGE:  ./terragrunt_project_status.sh
#
#  DESCRIPTION:
#
#  REQUIREMENTS: bash 5.1+, curl, jq
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION: 3.1
#      CREATED: 2025-10-02
#===============================================================================
set -euo pipefail  # Strict error handling
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

### CONFIGURATION
BASE_REPO_URL="${BASE_REPO_URL:-}"
BRANCH="${BRANCH:-main}"
GIT_TOKEN="${GIT_TOKEN:-}"
REPO_CLONE_DIR="${REPO_CLONE_DIR:-/tmp/terraform_core}"
PROJECT_PATH="${PROJECT_PATH:-${REPO_CLONE_DIR}/deploy/vsphere/vms}"
REMOVE_PATH_PREFIX="${REMOVE_PATH_PREFIX:-${REPO_CLONE_DIR}/deploy/vsphere/}"
MAX_JOBS="${MAX_JOBS:-8}"
MAX_RETRIES="${MAX_RETRIES:-3}"
PLAN_TIMEOUT="${PLAN_TIMEOUT:-300}"   # sécurité anti-blocage (secondes)
INIT_TIMEOUT="${INIT_TIMEOUT:-180}"
CLEAN_PLUGIN_CACHE="${CLEAN_PLUGIN_CACHE:-false}"   # mettre à true pour repartir d'un cache propre

#################################
# Debug mode (set DEBUG=on to enable verbose output)
DEBUG="${DEBUG:-off}"

# Forcer le mode non interactif partout (évite les prompts qui bloquent indéfiniment)
export GIT_TERMINAL_PROMPT=0
export TF_INPUT=false
export TF_IN_AUTOMATION=1
export TERRAGRUNT_NON_INTERACTIVE=true

# Le code Terraform référence var.terraform_path / var.ansible_path avec un default
# pointant vers /opt/... ; on surcharge pour qu'il pointe vers le clone réel de ce script.
export TF_VAR_terraform_path="$REPO_CLONE_DIR"
export TF_VAR_ansible_path="${ANSIBLE_CLONE_DIR:-/opt/ansible_core}"

# Build authenticated repo URL
AUTH_REPO_URL="https://oauth2:${GIT_TOKEN}@${BASE_REPO_URL}"

### FUNCTIONS
log() {
    if [ "$DEBUG" = "on" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    fi
}

debug() {
    if [ "$DEBUG" = "on" ]; then
        echo "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    fi
}

error() {
    echo "[ERROR][$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    exit 1
}

# Trace step-by-step : affiche l'étape, exécute la commande, affiche le résultat (si DEBUG=on)
step() {
    local description="$1"; shift
    if [ "$DEBUG" = "on" ]; then
        echo "[STEP][$(date '+%Y-%m-%d %H:%M:%S')] >>> $description" >&2
        echo "[STEP][$(date '+%Y-%m-%d %H:%M:%S')]     cmd: $*" >&2
        local start_ts end_ts
        start_ts=$(date +%s)
        if "$@"; then
            end_ts=$(date +%s)
            echo "[STEP][$(date '+%Y-%m-%d %H:%M:%S')] <<< OK ($description) en $((end_ts - start_ts))s" >&2
            return 0
        else
            local rc=$?
            end_ts=$(date +%s)
            echo "[STEP][$(date '+%Y-%m-%d %H:%M:%S')] <<< ECHEC ($description) code=$rc en $((end_ts - start_ts))s" >&2
            return $rc
        fi
    else
        "$@"
    fi
}

update_submodules() {
    log "Updating submodules..."
    if ! step "git submodule update" timeout 120 git submodule update --init --recursive --remote >/dev/null 2>&1; then
        log "Submodule update failed, attempting fallback..."

        step "git submodule foreach fallback" timeout 120 git submodule foreach --quiet --recursive '
            if git fetch origin >/dev/null 2>&1; then
                if git show-ref --verify --quiet refs/remotes/origin/main; then
                    git checkout -B main origin/main >/dev/null 2>&1 && git reset --hard origin/main >/dev/null 2>&1
                elif git show-ref --verify --quiet refs/remotes/origin/master; then
                    git checkout -B master origin/master >/dev/null 2>&1 && git reset --hard origin/master >/dev/null 2>&1
                fi
            fi
        ' >/dev/null 2>&1
    fi
}

retry() {
    local retries=$1; shift
    local count=0
    local exit_code=0

    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            log "Command failed with exit code $exit_code. Retrying ($count/$retries)..."
            sleep 2
        else
            log "Command failed after $retries attempts."
            return $exit_code
        fi
    done
    return 0
}

run_terragrunt_plan() {
    local path="$1"
    local short_path="$2"
    local job_number="$3"

    # Cache de providers dédié et EXCLUSIF à ce job_number (slot réellement libre, voir ordonnancement plus bas)
    export TF_PLUGIN_CACHE_DIR="/var/tmp/terraform_modules_cache_$job_number"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"

    cd "$path" || return 1

    debug "[$short_path] Entering directory: $path (job_number=$job_number)"

    # Initialize (timeout pour éviter tout blocage sur prompt résiduel)
    if ! retry "$MAX_RETRIES" timeout "$INIT_TIMEOUT" terragrunt init -input=false -no-color > "/tmp/tg_init_${job_number}.log" 2>&1; then
        log "Init failed for $short_path"
        if [ "$DEBUG" = "on" ]; then
            echo "[DEBUG][$short_path] --- terragrunt init output ---" >&2
            tail -20 "/tmp/tg_init_${job_number}.log" >&2
        fi
        return 1
    fi
    debug "[$short_path] terragrunt init OK"

    # Run plan and capture output, avec retry sur erreurs transitoires (ex: text file busy)
    local plan_output
    local exit_code
    local plan_attempt=0

    debug "[$short_path] Running terragrunt plan (timeout ${PLAN_TIMEOUT}s)..."
    while :; do
        plan_attempt=$((plan_attempt + 1))
        if plan_output=$(timeout "$PLAN_TIMEOUT" terragrunt plan -input=false -no-color -detailed-exitcode 2>&1); then
            exit_code=0  # No changes
            debug "[$short_path] Plan: no changes"
            break
        else
            exit_code=$?
            if [ $exit_code -eq 124 ]; then
                log "Plan TIMEOUT after ${PLAN_TIMEOUT}s for $short_path"
                break
            fi
            # Erreurs transitoires connues (cache providers en cours d'écriture) : on retente
            if echo "$plan_output" | grep -qi "text file busy\|fork/exec" && [ "$plan_attempt" -lt "$MAX_RETRIES" ]; then
                log "[$short_path] Transient provider error, retry $plan_attempt/$MAX_RETRIES"
                sleep 3
                continue
            fi
            break
        fi
    done

    if [ "$DEBUG" = "on" ] && [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 2 ]; then
        echo "$plan_output" | grep -i -E "error:|warning:|fail|invalid|denied|forbidden|timeout|not found|critical" | head -10 >&2
        log "Plan failed with exit code $exit_code in path: $short_path"
        # Dump complet en cas d'échec persistant, pour diagnostic fin
        echo "[DEBUG][$short_path] --- FULL PLAN OUTPUT ---" >&2
        echo "$plan_output" >&2
        echo "[DEBUG][$short_path] --- END PLAN OUTPUT ---" >&2
    fi

    # Always output Prometheus metrics
    echo "terragrunt_project_status{path=\"$short_path\"} $exit_code"
    return 0
}

### MAIN EXECUTION
if [ "$DEBUG" = "on" ]; then
    log "Debug mode enabled"
    log "Starting Terraform plan checks..."
fi

if [ "$CLEAN_PLUGIN_CACHE" = "true" ]; then
    log "Cleaning stale plugin caches..."
    rm -rf /var/tmp/terraform_modules_cache_*
fi

# Clone or update repository
if [ ! -d "$REPO_CLONE_DIR/.git" ]; then
    log "Cloning repository..."
    if ! step "git clone" git clone --branch "$BRANCH" "$AUTH_REPO_URL" "$REPO_CLONE_DIR" >/dev/null 2>&1; then
        error "Failed to clone repository"
    fi
    cd "$REPO_CLONE_DIR" || error "Failed to change to repo directory"
else
    log "Updating existing repository..."
    cd "$REPO_CLONE_DIR" || error "Failed to change to repo directory"

    # Reset and clean repository
    step "git fetch" git fetch origin "$BRANCH" >/dev/null 2>&1 || error "Failed to fetch from origin"
    step "git checkout" git checkout "$BRANCH" >/dev/null 2>&1 || error "Failed to checkout branch"
    step "git reset --hard" git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || error "Failed to reset branch"
    step "git clean -fd" git clean -fd >/dev/null 2>&1 || error "Failed to clean repository"
    step "git submodule sync" git submodule sync --recursive >/dev/null 2>&1 || error "Failed to sync submodules"
fi

# Nettoyage des caches terragrunt résiduels d'un run précédent interrompu
step "clean terragrunt-cache dirs" bash -c "find '$PROJECT_PATH' -type d -name '.terragrunt-cache' -exec rm -rf {} + 2>/dev/null || true"

update_submodules

# Prometheus headers (always output)
echo "# HELP terragrunt_project_status check plan status on project, 0 = all ok, 1 = error, 2 = changes to apply"
echo "# TYPE terragrunt_project_status gauge"

# Find all terragrunt projects
log "Finding Terragrunt projects..."
mapfile -t ALL_TERRAGRUNT_PROJECTS_PATH < <(
    find "$PROJECT_PATH" -name "terragrunt.hcl" -not -path "*terragrunt-cache*" -exec dirname {} \; | sort -u
)

log "Found ${#ALL_TERRAGRUNT_PROJECTS_PATH[@]} projects to process"

#-------------------------------------------------------------------------------
# Ordonnancement par SLOTS RÉELLEMENT LIBRES (évite la collision sur
# TF_PLUGIN_CACHE_DIR quand deux jobs reçoivent le même job_number en même temps)
#-------------------------------------------------------------------------------
declare -A pids                    # pid -> short_path (pour le rapport final)
declare -A job_slot_free           # numéro de slot -> 1 (libre) / 0 (occupé)
declare -A job_slots_pid_to_num    # pid -> numéro de slot qu'il occupe

for i in $(seq 1 "$MAX_JOBS"); do
    job_slot_free[$i]=1
done

running=0
failed_projects=0

free_finished_slot() {
    local finished_pid="$1"
    local rc="$2"
    local freed_num="${job_slots_pid_to_num[$finished_pid]:-}"
    if [ -n "$freed_num" ]; then
        job_slot_free[$freed_num]=1
        unset "job_slots_pid_to_num[$finished_pid]"
    fi
    if [ "$rc" -ne 0 ]; then
        log "Failed: ${pids[$finished_pid]:-unknown} (code $rc)"
        failed_projects=$((failed_projects + 1))
    else
        log "Completed: ${pids[$finished_pid]:-unknown}"
    fi
    running=$((running - 1))
}

for path in "${ALL_TERRAGRUNT_PROJECTS_PATH[@]}"; do
    short_path="${path#$REMOVE_PATH_PREFIX}"

    # Attendre qu'un slot se libère si on est au maximum
    while [ "$running" -ge "$MAX_JOBS" ]; do
        if wait -n -p finished_pid; then rc=0; else rc=$?; fi
        free_finished_slot "$finished_pid" "$rc"
    done

    # Trouver le premier slot libre
    job_number=""
    for i in $(seq 1 "$MAX_JOBS"); do
        if [ "${job_slot_free[$i]}" = "1" ]; then
            job_number=$i
            job_slot_free[$i]=0
            break
        fi
    done

    log "Processing $short_path (job $job_number)"

    run_terragrunt_plan "$path" "$short_path" "$job_number" &
    pid=$!
    pids[$pid]="$short_path"
    job_slots_pid_to_num[$pid]=$job_number
    running=$((running + 1))
done

# Attendre les jobs restants
while [ "$running" -gt 0 ]; do
    if wait -n -p finished_pid; then rc=0; else rc=$?; fi
    free_finished_slot "$finished_pid" "$rc"
done

if [ "$DEBUG" = "on" ]; then
    log "Processing complete. Failed projects: $failed_projects"
fi

exit $((failed_projects > 0 ? 1 : 0))
