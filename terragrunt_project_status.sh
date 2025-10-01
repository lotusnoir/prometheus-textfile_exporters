#!/bin/bash
set -euo pipefail  # Strict error handling

### CONFIGURATION
#BASE_REPO_URL="gitlab.url/terraform_core.git"
#BRANCH="main"
#REPO_DIR="/tmp/terraform_core"
#PROJECT_PATH="${REPO_DIR}/deploy/vsphere/vms"
#REMOVE_PATH_PREFIX="${REPO_DIR}/deploy/vsphere/"
#GIT_TOKEN="xxxxxxxxxxxx"  # Consider using environment variable instead
#MAX_JOBS=8
#MAX_RETRIES=3

#################################
# Debug mode (set DEBUG=on to enable verbose output)
DEBUG="${DEBUG:-off}"
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

update_submodules() {
    log "Updating submodules..."
    if ! git submodule update --init --recursive --remote >/dev/null 2>&1; then
        log "Submodule update failed, attempting fallback..."
        
        git submodule foreach --quiet --recursive '
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
    
    export TF_PLUGIN_CACHE_DIR="/var/tmp/terraform_modules_cache_$job_number"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
    
    cd "$path" || return 1
    
    # Initialize
    if ! retry $MAX_RETRIES terragrunt init > /dev/null 2>&1; then
        log "Init failed for $short_path"
        return 1
    fi
    
    # Run plan and capture output
    local plan_output
    local exit_code
    
    if plan_output=$(terragrunt plan -input=false -detailed-exitcode 2>&1); then
        exit_code=0  # No changes
    else
        exit_code=$?
        # Only show errors in debug mode
        if [ "$DEBUG" = "on" ] && [ $exit_code -ne 0 ]; then
            echo "$plan_output" | grep -i -E "error:|warning:|fail|invalid|denied|forbidden|timeout|not found|critical" | head -10 >&2
            log "Plan failed with exit code $exit_code in path: $short_path"
        fi
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

# Clone or update repository
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning repository..."
    if ! git clone --branch "$BRANCH" "$AUTH_REPO_URL" "$REPO_DIR" >/dev/null 2>&1; then
        error "Failed to clone repository"
    fi
    cd "$REPO_DIR" || error "Failed to change to repo directory"
else
    log "Updating existing repository..."
    cd "$REPO_DIR" || error "Failed to change to repo directory"
    
    # Reset and clean repository
    git fetch origin "$BRANCH" >/dev/null 2>&1 || error "Failed to fetch from origin"
    git checkout "$BRANCH" >/dev/null 2>&1 || error "Failed to checkout branch"
    git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || error "Failed to reset branch"
    git clean -fd >/dev/null 2>&1 || error "Failed to clean repository"
    git submodule sync --recursive >/dev/null 2>&1 || error "Failed to sync submodules"
fi

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

# Process projects in parallel
job_count=0
declare -A pids

for path in "${ALL_TERRAGRUNT_PROJECTS_PATH[@]}"; do
    job_count=$((job_count + 1))
    job_number=$(( (job_count - 1) % MAX_JOBS + 1 ))
    short_path="${path#$REMOVE_PATH_PREFIX}"
    
    log "Processing $short_path (job $job_number)"
    
    # Run in background
    run_terragrunt_plan "$path" "$short_path" "$job_number" &
    pids[$!]="$short_path"
    
    # Limit concurrent jobs
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
        sleep 1
    done
done

# Wait for all jobs and capture failures
failed_projects=0
for pid in "${!pids[@]}"; do
    if wait "$pid"; then
        log "Completed: ${pids[$pid]}"
    else
        log "Failed: ${pids[$pid]}"
        failed_projects=$((failed_projects + 1))
    fi
done

if [ "$DEBUG" = "on" ]; then
    log "Processing complete. Failed projects: $failed_projects"
fi

exit $((failed_projects > 0 ? 1 : 0))
