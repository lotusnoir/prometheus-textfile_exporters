#!/bin/bash

### ANSIBLE BLOCK
PROJECT_PATH="/opt/terraform_core/deploy/vsphere/vms"
REMOVE_PATH_PREFIX="/deploy/vsphere/"
### ANSIBLE BLOCK

# Retrieve all the directories with a terragrunt.hcl configuration
ALL_TERRAGRUNT_PROJECTS_PATH=$(find "$PROJECT_PATH" -name "terragrunt.hcl" -not -path "*terragrunt-cache/*" -execdir pwd \;)

# Prometheus headers
echo "# HELP terragrunt_project_status check plan status on project, 0 = all ok, 1 = error, 2 = changes to apply"
echo "# TYPE terragrunt_project_status gauge"

# Export REMOVE_PATH_PREFIX to be used inside xargs commands
export REMOVE_PATH_PREFIX

# Run terragrunt checks in parallel
printf "%s\n" $ALL_TERRAGRUNT_PROJECTS_PATH | xargs -P 8 -I{} bash -c '
    path="{}"
    short_path="${path#${REMOVE_PATH_PREFIX}}"
    cd "$path" || exit 1
    terragrunt plan -input=false -detailed-exitcode > /dev/null 2>&1
    code=$?
    echo "terragrunt_project_status{path=\"$short_path\"} $code"
'
