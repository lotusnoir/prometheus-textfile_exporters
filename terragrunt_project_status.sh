#!/bin/bash

### UPDATE
#PROJECT_PATH="/path/to/terragrunt/"
#REMOVE_PATH_PREFIX="prefix/path/"

#Retrieve all the directories with a terragrunt.hcl configuration
ALL_TERRAGRUNT_PROJECTS_PATH=$(find $PROJECT_PATH -name "terragrunt.hcl" -not -path "*terragrunt-cache/*" -execdir pwd \;)

function terragrunt_check_projects_status () {
    ACTUAL_PATH=$(pwd)
    echo "# HELP terragrunt_project_status check plan status on project, 0 = all ok, 1 error, 2 changes to apply"
    echo "# TYPE terragrunt_project_status gauge"
    for path in ${ALL_TERRAGRUNT_PROJECTS_PATH}; do
        cd "${path}" || return
        short_path="${path#*$REMOVE_PATH_PREFIX}"
        terragrunt plan -input=false -detailed-exitcode > /dev/null 2>&1
        CODE=$?
        echo "terragrunt_project_status{path=\"$short_path\"} $CODE"
    done
}

terragrunt_check_projects_status
