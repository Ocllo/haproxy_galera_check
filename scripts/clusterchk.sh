#!/usr/bin/env bash

# shellcheck disable=SC1117

# Author:: Matteo Dessalvi
#
# Copyright:: 2017
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# 
# This script checks the status of a MySQL instance
# which has joined a Galera Cluster.
#
# It will return: 
# 
#    "HTTP/1.x 200 OK\r" (if the node status is 'Synced') 
# 
# - OR - 
# 
#    "HTTP/1.x 503 Service Unavailable\r" (for any other status) 
# 
# The return values from this script will be used by HAproxy 
# in order to know the (Galera) status of a node.
#

# Variables:
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

USER=""
PASSWORD=""
INIFILE="/etc/mysql/debian.cnf"

#
# Parse command line arguments
#

OPTIND=1

while getopts "h?i:u:p:" opt; do
    case "$opt" in
    h|\?)
        print_help
        exit 0
        ;;
    u)
        USER=$OPTARG
        ;;
    p)
        PASSWORD=$OPTARG
        ;;
    i)
        INIFILE=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

[[ "${1:-}" = "--" ]] && shift

if [[ -n "${USER}" ]] && [[ -n "${PASSWORD}" ]]; then
    # Concatenate the parameters for the MySQL client:
    USEROPTIONS=("--user=${USER}" "--password=${PASSWORD}")
else
    # Read the ini config
    read_ini_config "${INIFILE}"
fi

#
# Read the config file (INI format) for MySQL:
#
read_ini_config () {
  local dir
  dir=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

  # shellcheck disable=SC1090
  . "${dir}/read_ini.sh"

  # Call the parser function over the debian.cnf file:
  read_ini -p IniCnf "$1"

  # Concatenate the parameters for the MySQL client:
  USEROPTIONS=("--user=${IniCnf__client__user:?}" "--password=${IniCnf__client__password:?}")
}

#
# Node status looks fine, so return an 'HTTP 200' status code.
#
http_ok () {
  message=$1
  length=${#message}

  /bin/echo -ne "HTTP/1.1 200 OK\r\n"

  /bin/echo -ne "Content-Type: text/plain\r\n"
  /bin/echo -ne "Connection: close\r\n" 
  /bin/echo -ne "Content-Length: ${length}\r\n"

  /bin/echo -ne "\r\n"
  /bin/echo -ne "${message}"
  /bin/echo -ne "\r\n"

  sleep 0.1
}

#
# Node status reports problems, so return an 'HTTP 503' status code.
#
http_no_access () {
  message=$1
  length=${#message}

  /bin/echo -ne "HTTP/1.1 503 Service Unavailable\r\n"

  /bin/echo -ne "Content-Type: text/plain\r\n"
  /bin/echo -ne "Connection: close\r\n" 
  /bin/echo -ne "Content-Length: ${length}\r\n"

  /bin/echo -ne "\r\n"
  /bin/echo -ne "${message}"
  /bin/echo -ne "\r\n"

  sleep 0.1
}

#
# Run a SQL query on the local MySQL instance.
# 
status_query () {
  query=$(/usr/bin/mysql --host=${MYSQL_HOST} --port=${MYSQL_PORT} "${USEROPTIONS[@]}" --silent --raw -N -e "$1")
  
  result=$(echo "${query}" | /usr/bin/cut -f 2) # just remove the value label
  echo "$result"
}

#
# Safety check: verify if MySQL is up and running.
#

MYSQL_PID=$(pidof mysqld)
if [[ -z "${MYSQL_PID}" ]]; then
    http_no_access "Instance is not running.\r\n"
    exit 1
fi

#
# Check the node status against the Galera Cluster:
#
GALERA_STATUS=$(status_query "SHOW STATUS LIKE 'wsrep_local_state_comment';")

#
# Check the method used for SST transfers:
#
SST_METHOD=$(status_query "SHOW VARIABLES LIKE 'wsrep_sst_method';")

#
# Check if MySQL is in 'read-only' status:
#
MYSQL_READONLY=$(status_query "SELECT @@global.read_only;")

# 
# If the (Galera) WSREP provider reports a status different than Synced
# it would be safe for HAproxy to reschedule SQL queries somewhere else.
#
# Node states:
# http://galeracluster.com/documentation-webpages/nodestates.html#node-state-changes
#
if [[ "${GALERA_STATUS}" == "Synced" ]]; then
  if [[ "${MYSQL_READONLY}" -eq 0 ]]; then
     http_ok "Status is ${GALERA_STATUS}\r\n"
  else
     http_no_access "Status is ${GALERA_STATUS}. Instance is read only.\r\n"
  fi
elif [[ "${GALERA_STATUS}" == Donor* ]]; then # node is acting as 'Donor' for another node, status can be Donor/Desynced so wildcard match
  if [[ "${SST_METHOD}" == "xtrabackup" ]] || [[ "${SST_METHOD}" == "xtrabackup-v2" ]] || [[ "${SST_METHOD}" == "mariabackup" ]]; then
     http_ok "Status is ${GALERA_STATUS}.\r\n" # xtrabackup is a non-blocking method
  else
     http_no_access "Status is ${GALERA_STATUS}.\r\n"
  fi
else
  http_no_access "Status is ${GALERA_STATUS}.\r\n"
fi
