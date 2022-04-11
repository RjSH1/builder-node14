#!/bin/bash

git_branch=
git_resource=

function pipeline_getIntegrationPropertyValue() {
  local integration_name="${1}"
  local property_name="${2}"
  local integration_property="int_${integration_name}_${property_name}"

  echo "${!integration_property}"
}

function pipeline_getResourcePropertyValue() {
  local resource_name="${1}"
  local property_name="${2}"
  local resource_property="res_${resource_name}_${property_name}"

  echo "${!resource_property}"
}

function pipeline_getGitRepoPath() {
  local git_resource="$1"
  pipeline_getResourcePropertyValue "${git_resource}" "path"
}

function _sonar_detectPullRequest() {
    echo -e "\n\n==> Detecting opened PR." >&2

    local git_url git_user git_password

    echo "=> INFO: Resolving Bitbucket properties based on input GitRepo resource: ${git_resource}" >&2
    git_url="$(pipeline_getResourcePropertyValue "${git_resource}" "gitProvider_url")"
    git_user="$(pipeline_getResourcePropertyValue "${git_resource}" "gitProvider_username")"
    git_password="$(pipeline_getResourcePropertyValue "${git_resource}" "gitProvider_password")"

    if [ -z "${git_url}" ]; then
        echo "=> WARN: Skipping PR checking - Bitbucket connection properties not found." >&2
        return 0
    fi

    local git_project="${SONAR_GIT_PROJECT}"
    local git_repository="${SONAR_GIT_REPO}"

    if [[ -z "${git_branch}" ]]; then
      echo "=> WARN: Skipping PR checking - Bitbucket branch not found." >&2
    fi

    local pull_request_result pull_request_count pull_request_list

    # Checking project and repository
    if [ -z "${git_project}" ] || [ -z "${git_repository}" ]; then
        if [[ -n "${git_project}" ]] || [[ -n "${git_repository}" ]]; then
            echo "=> WARN: Skipping PR checking - only one of Project or Git Repo was explicitly provided." >&2
            echo "=> WARN: Either specify both SONAR_GIT_PROJECT & SONAR_GIT_REPO, or let it be auto resolved." >&2
            return 0
        fi

        local git_repo_path

        if ! git_repo_path="$(pipeline_getGitRepoPath "${git_resource}")" || [[ -z "${git_repo_path}" ]]; then
            echo "=> WARN: Skipping PR checking - could not resolve git repository path." >&2
            echo "=> WARN: Either fix the root cause, or specify both SONAR_GIT_PROJECT & SONAR_GIT_REPO explicitly." >&2
            return 0
        fi

        git_project="${git_repo_path%/*}"
        git_repository="${git_repo_path#*/}"
        echo "=> INFO: Resolved git project: '${git_project}', and git repository: '${git_repository}'" >&2
    fi

    # Getting PR from Bitbucket
    echo "=> INFO: Using following data to fetch PRs from GIT" >&2
    echo "=> INFO: url: ${git_url}, user: ${git_user}" >&2
    if ! pull_request_result=$(curl -sS --fail -u "${git_user}:${git_password}" "https://git.jfrog.info/rest/api/latest/projects/${git_project}/repos/${git_repository}/pull-requests?state=OPEN&at=refs/heads/${git_branch}&direction=OUTGOING"); then
      echo "=> ERROR: Can't get the PRs from Bitbucket." >&2
      return 1
    fi

    pull_request_count=$(jq '.values | length' <<< "${pull_request_result}")

    if [[ ${pull_request_count} -ge 1 ]];then
        echo "=> INFO: ${pull_request_count} Opened PRs found (note- only the first will be taken if there are more than 1)." >&2
        pull_request_list=$( jq '.values[0] | .id, .toRef.displayId' <<< "${pull_request_result}" )

        # Make it in one line
        pull_request_list=$( echo ${pull_request_list} )
    elif [[ ${pull_request_count} -eq 0 ]]; then
        echo "=> INFO: No open PRs were found." >&2
    fi

    echo "${pull_request_list}"
}

function isPropertyExistsInSonarPropertiesFile() {
  local sonar_property="${1}"
  local log_level="${2}"
  if ! grep -q "sonar-project.properties" -e "^sonar\.${sonar_property}=[A-z0-9_.:\-]*" 1>&2; then
    echo "=> ${log_level}: 'sonar.${sonar_property}' was absent in sonar-project.properties file"
    return 1
  fi
}

function buildCommandVars() {
  local sonar_integration="sonar_jfrog_info"
  local sonar_url_var="int_${sonar_integration}_url"
  local sonar_login_var="int_${sonar_integration}_login"

  if [[ -z "${!sonar_url_var}" ]]; then
    echo "=> ERROR: Integration '${sonar_integration}' was not detected." >&2
    return 1
  fi

  sonar_host_url="${SONAR_HOST_URL:-${!sonar_url_var}}"
  sonar_login="${SONAR_LOGIN:-${!sonar_login_var}}"
  sonar_additional_options="${SONAR_ADDITIONAL_OPTIONS:-}"

  if [[ ! -f "sonar-project.properties" ]]; then
    echo "=> ERROR: could not detect 'sonar-project.properties' file in the current location"
    return 1
  fi

  if ! isPropertyExistsInSonarPropertiesFile 'projectKey' 'ERROR' \
  || ! isPropertyExistsInSonarPropertiesFile 'projectName' 'ERROR' \
  || ! isPropertyExistsInSonarPropertiesFile 'testExecutionReportPaths' 'ERROR' \
  || ! isPropertyExistsInSonarPropertiesFile 'javascript.lcov.reportPaths' 'ERROR'; then
    return 1
  fi

  if ! isPropertyExistsInSonarPropertiesFile 'qualitygate.wait' 'INFO'; then
    echo "=> INFO: using 'qualitygate.wait' default value: false" >&2
    sonar_qualitygate_wait="-Dsonar.qualitygate.wait=false"
  fi

  if ! isPropertyExistsInSonarPropertiesFile 'qualitygate.timeout' 'INFO'; then
    echo "=> INFO: using 'qualitygate.timeout' default value: 300" >&2
    sonar_qualitygate_timeout="-Dsonar.qualitygate.timeout=300"
  fi

  # Getting PRs
  local pull_request_list=$(_sonar_detectPullRequest)

  # Checking the PRs result
  if [ -n "${pull_request_list}" ];then
      pull_request_list=(${pull_request_list})
      echo "=> INFO: PR info fetched: branchName: '${git_branch}', pullRequestKey: '${pull_request_list[0]}', pullRequestBase: '${pull_request_list[1]}'" >&2
      sonar_branch_pr_option="-Dsonar.pullrequest.branch='${git_branch}' -Dsonar.pullrequest.key='${pull_request_list[0]}' -Dsonar.pullrequest.base='${pull_request_list[1]}'"
  else
      sonar_branch_pr_option="-Dsonar.branch.name='${git_branch}'"
  fi

  if [[ -f "tsconfig.json" ]]; then
    echo "=> INFO: 'tsconfig.json' file found" >&2
    export BROWSERSLIST_IGNORE_OLD_DATA=true
    isUseUnknownInCatchVariablesPropertyExists=$(cat "tsconfig.json" | grep 'useUnknownInCatchVariables' | xargs)

    if [[ -n "$isUseUnknownInCatchVariablesPropertyExists" ]]; then
      echo "=> INFO: 'useUnknownInCatchVariables' not supported option was found in 'tsconfig.json'. generating a new file" >&2
      cat "tsconfig.json" | grep -v 'useUnknownInCatchVariables' > "sonar-tsconfig.json"
      sonar_ts_config="-Dsonar.typescript.tsconfigPath=sonar-tsconfig.json"
    fi
  fi
}

if [[ "${SKIP_SONAR}" == 'true' ]]; then
  exit 0
fi

if [[ "$1" != '--git-repo-resource-name' ]]; then
  echo "=> ERROR: First argument must be '--git-repo-resource-name'" >&2
  exit 1
fi

if [[ -z "$2" ]]; then
  echo "=> ERROR: Second argument must be a git repo resource name" >&2
  exit 1
fi

git_resource=$2

git_branch="$(pipeline_getResourcePropertyValue "${git_resource}" "branchName")"

if [[ -z "${git_branch}" ]]; then
  echo "=> ERROR: Could not determine Git branch" >&2
  exit 1
fi

echo "=> INFO: Target Git branch name is '${git_branch}'" >&2

buildCommandVars || exit 1

eval "sonar-scanner" \
  -Dsonar.scm.exclusions.disabled=true \
  -Dsonar.scm.provider=git \
  -Dsonar.host.url="${sonar_host_url}" \
  -Dsonar.login="${sonar_login}" \
  "${sonar_ts_config}" \
  "${sonar_qualitygate_wait}" \
  "${sonar_qualitygate_timeout}" \
  "${sonar_branch_pr_option}" \
  "${sonar_additional_options}"
