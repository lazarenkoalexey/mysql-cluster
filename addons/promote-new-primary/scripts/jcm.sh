#!/bin/bash

USER_SCRIPT_PATH="{URL}"

PROMOTE_NEW_PRIMARY_FLAG="/var/lib/jelastic/promotePrimary"

JCM_CONFIG="/etc/proxysql/jcm.conf"
ITERATION_CONFIG="/etc/proxysql/iteration.conf"

SUCCESS_CODE=0
FAIL_CODE=99
RUN_LOG=/var/log/jcm.log

WRITE_HG_ID=10
READ_HG_ID=11
MAX_REPL_LAG=20

log(){
  local message=$1
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
}

execResponse(){
  local result=$1
  local message=$2
  local output_json="{\"result\": ${result}, \"out\": \"${message}\"}"
  echo $output_json
}

proxyCommandExec(){
  local command="$1"
  MYSQL_PWD=admin mysql -uadmin -h127.0.0.1 -P6032 -BNe "$command"
}

execAction(){
  local action="$1"
  local message="$2"
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done";  } || {
    log "${message}...failed\n${stdout}\n";
    error="${message} failed, please check ${RUN_LOG} for details"
    execResponse "$FAIL_CODE" "$error";
    exit 0;
  }
}

primaryStatus(){
  local cmd="select status from runtime_mysql_servers where hostgroup_id=$WRITE_HG_ID;"
  local status=$(proxyCommandExec "$cmd")
  source $JCM_CONFIG;
  [[ -f $ITERATION_CONFIG ]] && source $ITERATION_CONFIG;
  if [[ "x$status" != "xONLINE" ]] && [[ ! -f $PROMOTE_NEW_PRIMARY_FLAG  ]]; then
    if [[ $ITERATION -eq $ONLINE_ITERATIONS ]]; then
      log "Primary node status is OFFLINE"
      log "Promoting new Primary"
#    resp=$(wget --no-check-certificate -qO- "${USER_SCRIPT_PATH}");
    else
      ITERATION=$(($ITERATION+1))
      echo "ITERATION=$ITERATION" > ${ITERATION_CONFIG};
    fi
  else
    if [ ! -f $PROMOTE_NEW_PRIMARY_FLAG  ]; then
      log "Primary node status is ONLINE"
      echo "ITERATION=0" > ${ITERATION_CONFIG};
    else
      log "Promoting new Primary in progress"
    fi
  fi
}

addNodeToWriteGroup(){
  local nodeId="$1"
  local cmd="INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES ($WRITE_HG_ID, '$nodeId', 3306);"
  proxyCommandExec "$cmd"
}

addNodeToReadGroup(){
  local nodeId="$1"
  local cmd="INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES ($READ_HG_ID, '$nodeId', 3306, '$MAX_REPL_LAG');"
  proxyCommandExec "$cmd"
}

loadServersToRuntime(){
  local cmd="LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
  proxyCommandExec "$cmd"
}

addSchedulerProxy(){
  local interval_ms="$1"
  local filename="$2"
  local arg1="$3"
  local comment="$4"
  local cmd="INSERT INTO scheduler(interval_ms,filename,arg1,active,comment) "
  cmd+="VALUES ($interval_ms,'$filename', '$arg1',1,'$comment');"
  proxyCommandExec "$cmd"
}

updateSchedulerProxy(){
  local interval_ms="$1"
  local comment="$2"
  local cmd="UPDATE scheduler SET interval_ms=$interval_ms WHERE comment='$comment';"
  proxyCommandExec "$cmd"
}

loadSchedulerToRuntime(){
  local cmd="LOAD SCHEDULER TO RUNTIME; SAVE SCHEDULER TO DISK;"
  proxyCommandExec "$cmd"
}

setSchedulerTimeout(){
  for i in "$@"; do
    case $i in
      --interval=*)
      INTERVAL=${i#*=}
      shift
      shift
      ;;

      --scheduler_name=*)
      SCHEDULER_NAME=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done

  local interval_ms=$((${INTERVAL} * 1000))
  execAction "updateSchedulerProxy $interval_ms $SCHEDULER_NAME" "Updating scheduler timeout"
  execAction "loadSchedulerToRuntime" "Loading cronjob tasks to runtime"
}

addScheduler(){
  for i in "$@"; do
    case $i in
      --interval=*)
      INTERVAL=${i#*=}
      shift
      shift
      ;;

      --filename=*)
      FILENAME=${i#*=}
      shift
      shift
      ;;

      --arg1=*)
      ARG1=${i#*=}
      shift
      shift
      ;;

      --arg2=*)
      ARG2=${i#*=}
      shift
      shift
      ;;

      --arg3=*)
      ARG3=${i#*=}
      shift
      shift
      ;;

      --arg4=*)
      ARG4=${i#*=}
      shift
      shift
      ;;

      --arg5=*)
      ARG5=${i#*=}
      shift
      shift
      ;;

      --scheduler_name=*)
      SCHEDULER_NAME=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done
  
#  local interval_ms=$((${INTERVAL} * 1000))
  local interval_ms=5000
  local interval_sec=5
  local online_iterations=$((${INTERVAL}/${interval_sec}))
  
  execAction "updateParameterInConfig ONLINE_ITERATIONS $online_iterations" "Set $online_iterations iterations checks in the $JCM_CONFIG"
  execAction "addSchedulerProxy $interval_ms $FILENAME $ARG1 $SCHEDULER_NAME" "Adding $SCHEDULER_NAME crontask to scheduler"
  execAction "loadSchedulerToRuntime" "Loading cronjob tasks to runtime"

}

deletePrimary(){
  local nodeId="$1"
  local cmd="DELETE from mysql_servers WHERE hostname='$nodeId';"
  proxyCommandExec "$cmd"
}

updateParameterInConfig(){
  local parameter="$1"
  local value="$2"
  grep -q "$parameter" ${JCM_CONFIG} && { sed -i "s/${parameter}.*/$parameter=$value/" ${JCM_CONFIG}; } || { echo "$parameter=$value" >> ${JCM_CONFIG}; }
}

newPrimary(){
  for i in "$@"; do
    case $i in
      --server=*)
      SERVER=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done
  if [[ -f $JCM_CONFIG ]]; then
    source $JCM_CONFIG;
    execAction "deletePrimary $PRIMARY_NODE_ID" "Deleting primary node $PRIMARY_NODE_ID from configuration"
    execAction "loadServersToRuntime" "Loading server configuration to runtime"
  fi
  execAction "addNodeToWriteGroup $SERVER" "Adding $SERVER to writer hostgroup"
  execAction "addNodeToReadGroup $SERVER" "Adding $SERVER to reader hostgroup"
  execAction "loadServersToRuntime" "Loading server configuration to runtime"
  execAction "updateParameterInConfig PRIMARY_NODE_ID $SERVER" "Set primary node to $SERVER in the $JCM_CONFIG"
}

case ${1} in
    primaryStatus)
      primaryStatus
      ;;

    newPrimary)
      newPrimary "$@"
      ;;

    addScheduler)
      addScheduler "$@"
      ;;

    setSchedulerTimeout)
      setSchedulerTimeout "$@"
      ;;

    updateParameterInConfig)
      updateParameterInConfig "$@"
      ;;
      
    *)
      echo "Please use $(basename "$BASH_SOURCE") primaryStatus or $(basename "$BASH_SOURCE") newPrimary"
esac
