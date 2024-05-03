#!/usr/bin/env bash

####
# Copyright (c) 2024 Kong, Inc.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#  - Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#  - Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUsed AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVIsed OF THE POSSIBILITY OF SUCH DAMAGE.
####

# Generic method for hitting endpoints on the Admin API
function kong_gateway_fetch_from_admin_api() {
  local api="$1"
  local token="$2"
  local path="$3"
  local flag=""

  if [[ -n "$4" ]]; then
    flag="$4"
  fi

  if output=$(curl -k -s $flag -X GET "${api}${path}" -H "Kong-Admin-Token: ${token}" -H "Content-Type: application/json"); then
    response="$output"
  else
    echo "Error: Failed to fetch ${path} from ${api}" >&2
    return 1
  fi

  echo "$response"
}

# Gets the license report 
function kong_gateway_fetch_license_report() {
  local name="$1"
  local api="$2"
  local token="$3"
  local path="/license/report"

  echo $(kong_gateway_fetch_from_admin_api $api $token $path) | jq -s 'add'
}

function kong_gateway_fetch_gateway_status() {
  local api="$1"
  local token="$2"
  local path="/status"
  local flag="-I"

  status=$(kong_gateway_fetch_from_admin_api $api $token $path $flag | head -n 1)

  if [[ -n $(echo $status | grep 200) ]]; then
    status="Healthy"
  fi

  # remove the trailing newline first, and then the white space
  echo "${status//[$'\t\r\n']}"
}

function kong_gateway_fetch_gateway_version() {
  local api="$1"
  local token="$2"
  local path="/default/kong"

  version=$(kong_gateway_fetch_from_admin_api $api $token $path | jq -r '.version')

  echo $version
}

function kong_gateway_fetch_workspaces() {
  local size=1000
  local api="$1"
  local token="$2"
  local path="/workspaces?size=$size"

  # get the first batch of $size workspaces
  local raw=$(kong_gateway_fetch_from_admin_api $api $token $path | jq)
  local workspaces=$(echo $raw | jq -r '.data[].name')

  # we need to make sure we check all the "pages" in case there are more than 1000 workspaces,
  local offset=$(echo $raw | jq -r '.next // empty')

  # let's grab $size workspaces at a time until we run out
  while [[ -n "${offset}" ]]; do
    raw=$(kong_gateway_fetch_from_admin_api $api $token $offset | jq)
    workspaces="$workspaces $(echo $raw | jq -r '.data[].name')"
    offset=$(echo $raw | jq -r '.next // empty')
  done  

  echo $workspaces | xargs -n1 | sort | xargs
}

# Get a list of services in the workspace
function kong_gateway_fetch_workspace_services() {
  local size=1000
  local api="$1"
  local token="$2"
  local path="/$3/services?size=$size"

  # get the first batch of $size workspaces
  local raw=$(kong_gateway_fetch_from_admin_api $api $token $path | jq)
  local services=$(echo $raw | jq -r '[.data[] | {service: "\(.protocol)://\(.host):\(.port)\(.path)"}]')

  # we need to make sure we check all the "pages" in case there are more than 1000 workspaces,
  local offset=$(echo $raw | jq -r '.next // empty')

  # let's grab $size workspaces at a time until we run out
  while [[ -n "${offset}" ]]; do
    raw=$(kong_gateway_fetch_from_admin_api $api $token $offset | jq)
    nextBatch=$(echo $raw | jq -r '[.data[] | {service: "\(.protocol)://\(.host):\(.port)\(.path)"}]')
    services=$(jq --argjson arr1 "$services" --argjson arr2 "$nextBatch" -n '$arr1 + $arr2')
    offset=$(echo $raw | jq -r '.next // empty')
  done

  if [[ ! -z "$4" && ! -z "$5" ]]; then    
    services=$(echo $services | jq -r -s --arg master $4 --arg minions $5 'add | .[].service |= sub($minions;$master)')
  fi

  echo $services
}

# Get a list of all control planes, but only if a control plane ID wasn't provided
function kong_konnect_fetch_control_planes() {
  # page size must be 100 or less
  local size=100
  local api="$1"
  local token="$2"
  local cp="$3"

  if [ "$cp" == "null" ]; then
    local path="/control-planes?page%5Bsize%5D=$size&page%5Bnumber%5D="
    local raw=$(kong_konnect_fetch_from_api $api $token "${path}1" | jq)

    # no need to keep on going if we got nothing back 
    if [ -z "$raw" ]; then
      return
    fi

    local control_planes=$(echo $raw | jq -r '[.data[] | {id: "\(.id)", name: "\(.name)"}]')
    local total_cps=$(echo $raw | jq -r '.meta.page.total')
    
    # if we have more control planes than our page size, it's time to loop some
    if [[ $total_cps -gt $size ]]; then 
      # first things first, let's see how many iterations we have to go through
      local pages=$(( ($total_cps + $size - 1)/$size ))

      # start at page 2, since we already got the first page above
      for (( page=2; page<=$pages; page++ )); do        
        raw=$(kong_konnect_fetch_from_api $api $token "${path}${page}" | jq)
        nextBatch=$(echo $raw | jq -r '[.data[] | {id: "\(.id)", name: "\(.name)"}]')
        control_planes=$(jq  --argjson arr1 "$control_planes" --argjson arr2 "$nextBatch" -n '$arr1 + $arr2')
      done
    fi
  else
    local path="/control-planes/$cp"
    local control_planes=$(kong_konnect_fetch_from_api $api $token $path | jq -r '[{id: "\(.id)", name: "\(.name)"}]')
  fi

  echo $control_planes | jq -r 'sort_by(.name) | .[].id'
}

# Gets a control plane name
function kong_konnect_fetch_control_plane_info() {
  local api="$1"
  local token="$2"
  local path="/control-planes/$3"

  local info=$(kong_konnect_fetch_from_api $api $token $path | jq)

  echo $info
}

# Get a list of services in the control plane
function kong_konnect_fetch_control_plane_services() {
  local size=1000
  local api="$1"
  local token="$2"
  local path="/control-planes/$3/core-entities/services?size=$size"

  local raw=$(kong_konnect_fetch_from_api $api $token $path | jq)
  local services=$(echo $raw | jq -r '[.data[] | {name: "\(.name)", service: "\(.protocol)://\(.host):\(.port)\(.path)"}]')

  # we need to make sure we check all the "pages" in case there are more than 1000 workspaces,
  local offset=$(echo $raw | jq -r '.next // empty')

  # let's grab $size workspaces at a time until we run out
  while [[ -n "${offset}" ]]; do
    raw=$(kong_konnect_fetch_from_api $api $token $offset | jq)
    nextBatch=$(echo $raw | jq -r '[.data[] | {service: "\(.protocol)://\(.host):\(.port)\(.path)"}]')
    services=$(jq --argjson arr1 "$services" --argjson arr2 "$nextBatch" -n '$arr1 + $arr2')
    offset=$(echo $raw | jq -r '.next // empty')
  done  

  echo $services
}

api="$1"
token="$2" 

control_planes=$(kong_konnect_fetch_control_planes $api $token "null")

json="["

for cp in $control_planes; do
  cp_info=$(kong_konnect_fetch_control_plane_info $api $token $cp)
  cp_type=$(echo $cp_info | jq -r '.config.cluster_type')
  cp_name="$(echo $cp_info | jq '.name')"
  cp_id="$(echo $cp_info | jq '.id')"

  match_found=$(echo $cp_type | grep -E "(CLUSTER_TYPE_CONTROL_PLANE$)")
  
  if [ -z "$match_found" ]; then
    continue
  fi

  services=$(kong_konnect_fetch_control_plane_services $api $token $cp)
  json+=$(printf '{"control_plane_name": %s, "control_plane_id": %s, "services": %s}, \n' "$cp_name" "$cp_id" "$services")
done

json=$(echo $json | sed 's/.$//')
json+="]"

echo $json