# !/bin/sh
# Copyright 2018, Oracle Corporation and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.

#############################################################################
#
# Description:
#
#   This test performs some basic end-to-end introspector tests while
#   emulating (mocking) the operator pod.  It's useful for verifying the
#   introspector is working correctly, and for quickly testing changes to
#   its overall flow.
#
#   See the README in this directory for overall flow and usage.
#
# Notes:
#
#   The test can optionally work with any arbitrary exiting domain home, or
#   it can create a domain_home for you.  See CREATE_DOMAIN in the implementation
#   below, (default true).
#
#   The test calls the integration test 'cleanup.sh' when it starts.  It
#   passes a special parameter to cleanup.sh to skip domain_home deletion if
#   the test's CREATE_DOMAIN parameter is set to false.
#
# Internal design:
#
#   The 'meat' of the test mainly works via a series of yaml and python
#   template files in combination with a set of environment variables.  
#
#   The environment variables, such as PV_ROOT, DOMAIN_UID, NAMESPACE,
#   IMAGE_NAME, etc, all have defaults, or can be passed in.  See the 'export'
#   calls in the implementation below for the complete list.
#

#############################################################################
#
# Initialize basic globals
#

SCRIPTPATH="$( cd "$(dirname "$0")" > /dev/null 2>&1 ; pwd -P )"
SOURCEPATH="`echo $SCRIPTPATH | sed 's/weblogic-kubernetes-operator.*/weblogic-kubernetes-operator/'`"
traceFile=${SOURCEPATH}/operator/src/main/resources/scripts/traceUtils.sh
source ${traceFile}
source ${SCRIPTPATH}/util_dots.sh
[ $? -ne 0 ] && echo "Error: missing file ${traceFile}" && exit 1

# Set TRACE_INCLUDE_FILE to true to cause tracing to include filename & line number.
export TRACE_INCLUDE_FILE=false

set -o pipefail

trace "Info: Starting."

#############################################################################
#
# Set root directory for PV
#   This matches env vars used by the 'cleanup.sh' call below. 
#

export PV_ROOT=${PV_ROOT:-/scratch/$USER/wl_k8s_test_results}

#############################################################################
#
# Set CREATE_DOMAIN to false to use an existing domain instead 
# of creating a new one.  
#   - If setting to true (the default), see "extra env var" section below
#     for additional related env vars.
#   - If setting to false, remember to also set PVCOMMENT if the 
#     pre-existing domain is not in a PV.
#

CREATE_DOMAIN=${CREATE_DOMAIN:-true}

#############################################################################
#
# Set PVCOMMENT to "#" to remove PV from wl-job/wl-pod yaml.
#   - Do this when the introspector job or wl-pod already has
#     the domain home burned into the image and so doesn't need
#     to mount a PV.
#   - Do not do this when CREATE_DOMAIN is true (create domain
#     depends on the PV).
#

export PVCOMMENT=${PVCOMMENT:-""}

#############################################################################
#
# Set env vars for an existing domain and/or a to-be-created domain:
#

export WEBLOGIC_IMAGE_NAME=${WEBLOGIC_IMAGE_NAME:-store/oracle/weblogic}
export WEBLOGIC_IMAGE_TAG=${WEBLOGIC_IMAGE_TAG:-19.1.0.0}
export WEBLOGIC_IMAGE_PULL_POLICY=${WEBLOGIC_IMAGE_PULL_POLICY:-IfNotPresent}

export DOMAIN_UID=${DOMAIN_UID:-domain1}
export NAMESPACE=${NAMESPACE:-default}

export LOG_HOME=${LOG_HOME:-/shared/logs}
export SERVER_OUT_IN_POD_LOG=${SERVER_OUT_IN_POD_LOG:-true}
export DOMAIN_HOME=${DOMAIN_HOME:-/shared/domains/${DOMAIN_UID}}

[ -z ${WEBLOGIC_CREDENTIALS_SECRET_NAME} ] && \
  export WEBLOGIC_CREDENTIALS_SECRET_NAME="${DOMAIN_UID}-weblogic-credentials"

export NODEMGR_HOME=${NODEMGR_HOME:-/shared/nodemanagers}

export ADMIN_NAME=${ADMIN_NAME:-"admin-server"}
export ADMIN_PORT=${ADMIN_PORT:-7001}
export MANAGED_SERVER_NAME_BASE=${MANAGED_SERVER_NAME_BASE:-"managed-server"}
export DOMAIN_NAME=${DOMAIN_NAME:-"base_domain"}
export ADMINISTRATION_PORT=${ADMINISTRATION_PORT:-7099}

#############################################################################
#
# Set extra env vars needed when CREATE_DOMAIN == true
#

#publicip="`kubectl cluster-info | grep KubeDNS | sed 's;.*//\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\):.*;\1;'`"
#export TEST_HOST="`nslookup $publicip | grep 'name =' | sed 's/.*name = \(.*\)./\1/'`"
export TEST_HOST="mycustompublicaddress"

export CLUSTER_NAME="${CLUSTER_NAME:-mycluster}"
export MANAGED_SERVER_PORT=${MANAGED_SERVER_PORT:-8001}
export CONFIGURED_MANAGED_SERVER_COUNT=${CONFIGURED_MANAGED_SERVER_COUNT:-2}
export CLUSTER_TYPE="${CLUSTER_TYPE:-DYNAMIC}"
export T3CHANNEL1_PORT=${T3CHANNEL1_PORT:-30012}
export T3CHANNEL2_PORT=${T3CHANNEL2_PORT:-30013}
export T3CHANNEL3_PORT=${T3CHANNEL3_PORT:-30014}
export T3_PUBLIC_ADDRESS=${T3_PUBLIC_ADDRESS:-}
export PRODUCTION_MODE_ENABLED=${PRODUCTION_MODE_ENABLED:-true}

#############################################################################
#
# End of setup! All that follows is implementation.
#

#############################################################################
#
# Cleanup k8s artifacts and test files from previous run
#

# Location for this test to put its temporary files
test_home=/tmp/introspect

function cleanupMajor() {
  trace "Info: Cleaning files and k8s artifacts from previous run."

  # first, let's delete the test's local tmp files for rm -fr
  #
  # CAUTION: We deliberately hard code the path here instead of using 
  #          using the test_home env var.  This helps prevent
  #          rm -fr from accidentally blowing away stuff it shouldn't!
   
  rm -fr /tmp/introspect
  mkdir -p $test_home || exit 1

  # now we use the generic integration test cleanup script to
  #
  #   1 - delete all operator related k8s artifacts
  #   2 - delete contents of k8s weblogic domain PV/PVC
  #       (if CREATE_DOMAIN has been set to "true")

  tracen "Info: Waiting for cleanup.sh to complete."
  printdots_start
  DELETE_FILES=${CREATE_DOMAIN:-false} \
    ${SOURCEPATH}/src/integration-tests/bash/cleanup.sh 2>&1 > \
    ${test_home}/cleanup.out
  status=$?
  printdots_end

  if [ $status -ne 0 ]; then
    trace "Error:  cleanup failed.   Cleanup output:"
    cat ${test_home}/cleanup.out
    exit 1
  fi
}

function cleanupMinor() {
  trace "Info: RERUN_INTROSPECT_ONLY==true, skipping cleanup.sh and domain home setup, and only deleting wl pods + introspector job."

  kubectl -n $NAMESPACE delete pod ${DOMAIN_UID}-${ADMIN_NAME}                --grace-period=2 > /dev/null 2>&1
  kubectl -n $NAMESPACE delete pod ${DOMAIN_UID}-${MANAGED_SERVER_NAME_BASE}1 --grace-period=2 > /dev/null 2>&1
  kubectl -n $NAMESPACE delete job ${DOMAIN_UID}-introspect-domain-job        --grace-period=2 > /dev/null 2>&1
  kubectl -n $NAMESPACE delete pod ${DOMAIN_UID}--introspect-domain-pod       --grace-period=2 > /dev/null 2>&1
  rm -fr ${test_home}/jobfiles
  tracen "Info: Waiting for wl pods to completely go away before continuing."
  while [ 1 -eq 1 ]; do
    echo -n "."
    # echo
    # echo "Waiting for: '`kubectl -n ${NAMESPACE} get pods | grep \"${DOMAIN_UID}.*server\"`'"
    # echo "Waiting for: '`kubectl -n ${NAMESPACE} get pods | grep \"${DOMAIN_UID}.*introspect\"`'"
    [ "`kubectl -n ${NAMESPACE} get pods | grep \"${DOMAIN_UID}.*server\"`" = "" ] \
     && [ "`kubectl -n ${NAMESPACE} get pods | grep \"${DOMAIN_UID}.*introspect\"`" = "" ] \
     && break
    sleep 1
  done
  echo
}

#############################################################################
#
# Helper function for running a job
#

function runJob() {
  trace "Info: Running job '${1?}' for script '${2?}'."

  local job_name=${1?}
  local job_script=${2?}
  local yaml_template=${3?}
  local yaml_file=${4?}

  # Remove old job yaml in case its leftover from a previous run

  rm -f ${test_home}/${yaml_file}

  # Create the job yaml from its template

  env \
    JOB_SCRIPT=${job_script} \
    JOB_NAME=${job_name} \
    ${SCRIPTPATH}/util_subst.sh -g ${yaml_template} ${test_home}/${yaml_file} \
    || exit 1

  # Run the job

  tracen "Info: Waiting for job '$job_name' to complete."
  printdots_start
  env \
    KUBECONFIG=$KUBECONFIG \
    JOB_YAML=${test_home}/${yaml_file} \
    JOB_NAME=${job_name} \
    NAMESPACE=$NAMESPACE \
    ${SCRIPTPATH}/util_job.sh \
    2>&1 > ${test_home}/job-${1}.out
  local status=$?
  printdots_end

  if [ ! $status -eq 0 ]; then
    printdots_end
    trace "Error:  job failed, job contents"
    cat ${test_home}/job-${1}.out
    trace "Error:  end of failed job contents"
    exit 1
  fi
}

#############################################################################
#
# Helper function for deploying a yaml template.  Template $1 is converted
# to ${test_home}/$2, and then ${test_home}/$2 is deployed.
#

function deployYamlTemplate() {
  local yamlt_file="${1?}"
  local yaml_file="${2?}"

  # Delete anything left over from a previous invocation of this function

  if [ -f "{test_home}/${yaml_file}" ]; then
    kubectl -n $NAMESPACE delete -f ${test_home}/${yaml_file} \
      --ignore-not-found \
      2>&1 | tracePipe "Info: kubectl output: "
    rm -f ${test_home}/${yaml_file}
  fi

  # Apply template and create its k8s resource

  ${SCRIPTPATH}/util_subst.sh -g ${yaml_file}t ${test_home}/${yaml_file} || exit 1

  kubectl create -f ${test_home}/${yaml_file} \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1 
}

#############################################################################
#
# Helper function for deploying a configmap that contains the files in 
# a directory.
#

createConfigMapFromDir() {
  local cm_name=${1?}
  local cm_dir=${2?}

  kubectl -n $NAMESPACE create cm ${cm_name} \
    --from-file ${cm_dir} \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1 

  kubectl -n $NAMESPACE label cm ${cm_name} \
    weblogic.createdByOperator=true \
    weblogic.operatorName=look-ma-no-hands \
    weblogic.resourceVersion=domain-v2 \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1 
}


#############################################################################
#
# Helper function to lowercase a value and make it a legal DNS1123 name
# $1 - value to convert to lowercase
#

function toDNS1123Legal {
  local val=`echo $1 | tr "[:upper:]" "[:lower:]"`
  val=${val//"_"/"-"}
  echo "$val"
}


#############################################################################
#
# Deploy domain cm 
#   - this emulates what the operator pod would do
#   - contains the operator's introspect, nm, start server scripts, etc.
#   - mounted by create domain job, introspect job, and wl pods
#

function deployDomainConfigMap() {
  trace "Info: Deploying 'weblogic-domain-cm'."

  kubectl -n $NAMESPACE delete cm weblogic-domain-cm \
    --ignore-not-found  \
    2>&1 | tracePipe "Info: kubectl output: "

  createConfigMapFromDir weblogic-domain-cm ${SOURCEPATH}/operator/src/main/resources/scripts
}

#############################################################################
#
# Deploy test script cm 
#   - contains create domain script, create test root script, and helpers for
#     same
#   - mounted by create test root job, and by create domain job
#

function deployTestScriptConfigMap() {
  trace "Info: Deploying 'test-script-cm'."

  mkdir -p ${test_home}/test-scripts

  cp ${SOURCEPATH}/operator/src/main/resources/scripts/traceUtils* ${test_home}/test-scripts || exit 1
  cp ${SCRIPTPATH}/createDomain.sh ${test_home}/test-scripts || exit 1
  cp ${SCRIPTPATH}/createTestRoot.sh ${test_home}/test-scripts || exit 1
  cp ${SCRIPTPATH}/introspectDomainProxy.sh ${test_home}/test-scripts || exit 1

  if [ "$CREATE_DOMAIN" = "true" ]; then
    rm -f ${test_home}/test-scripts/createDomain.py
    ${SCRIPTPATH}/util_subst.sh -g createDomain.pyt ${test_home}/test-scripts/createDomain.py || exit 1
  fi
  
  kubectl -n $NAMESPACE delete cm test-script-cm \
    --ignore-not-found  \
    2>&1 | tracePipe "Info: kubectl output: "

  createConfigMapFromDir test-script-cm ${test_home}/test-scripts

}

#############################################################################
#
# Deploy custom override cm, just like a customer would
#


function deployCustomOverridesConfigMap() {
  local cmdir="${test_home}/customOverrides"
  local cmname="${DOMAIN_UID}-mycustom-overrides-cm"

  trace "Info: Setting up custom overrides map '$cmname' using directory '$cmdir'."

  mkdir -p $cmdir
  rm -f $cmdir/*.xml
  rm -f $cmdir/*.txt
  local bfilname dfilname filname
  for filname in override--*.xmlt override--*.txtt; do
     bfilname="`basename $filname`"
     bfilname="${bfilname/override--/}"
     bfilname="${bfilname/xmlt/xml}"
     bfilname="${bfilname/txtt/txt}"
     #echo $filname "+" $bfilname "+" ${cmdir}/${bfilname} 
     #cp ${filname} ${cmdir}/${bfilname} || exit 1
     ${SCRIPTPATH}/util_subst.sh -g ${filname} ${cmdir}/${bfilname}  || exit 1
  done

  kubectl -n $NAMESPACE delete cm $cmname \
    --ignore-not-found  \
    2>&1 | tracePipe "Info: kubectl output: "

  createConfigMapFromDir $cmname $cmdir || exit 1
}


#############################################################################
#
# Create base directory for PV (uses a job)
# (Skip if PVCOMMENT="#".)
#

function createTestRootPVDir() {

  [ "$PVCOMMENT" = "#" ] && return

  trace "Info: Creating k8s cluster physical directory 'PV_ROOT/acceptance_test_pv/domain-${DOMAIN_UID}-storage'."
  trace "Info: PV_ROOT='$PV_ROOT'"
  trace "Info: Test k8s resources use this physical directory via a PV/PVC '/shared' logical directory."

  # TBD on Wercker/Jenkins PV_ROOT will differ and may already exist or be remote
  #     so we need to add logic/booleans to skip the following mkdir/chmod as needed
  mkdir -p ${PV_ROOT} || exit 1
  chmod 777 ${PV_ROOT} || exit 1

  # Create test root within PV_ROOT via a job

  deployYamlTemplate create-test-root-pv.yamlt create-test-root-pv.yaml
  deployYamlTemplate create-test-root-pvc.yamlt create-test-root-pvc.yaml

  runJob ${DOMAIN_UID}-create-test-root-job \
         /test-scripts/createTestRoot.sh \
         create-test-root-job.yamlt \
         create-test-root-job.yaml
}

#############################################################################
#
# Deploy WebLogic pv, pvc, & admin user/pass secret
# (Skip pv/pvc if PVCOMMENT="#".)
#

function deployWebLogic_PV_PVC_and_Secret() {
  trace "Info: Deploying WebLogic domain's pv, pvc, & secret."

  [ "$PVCOMMENT" = "#" ] || deployYamlTemplate wl-pv.yamlt wl-pv.yaml
  [ "$PVCOMMENT" = "#" ] || deployYamlTemplate wl-pvc.yamlt wl-pvc.yaml
  deployYamlTemplate wl-secret.yamlt wl-secret.yaml
}

#############################################################################
#
# Run create domain job if CREATE_DOMAIN is true
#

function deployCreateDomainJob() {
  [ ! "$CREATE_DOMAIN" = "true" ] && return 0

  trace "Info: Run create domain job."

  [ "$PVCOMMENT" = "#" ] \
    && trace "Error: Cannot run create domain job, PV is disabled via PVCOMMENT." \
    && exit 1

  runJob ${DOMAIN_UID}-create-domain-job \
         /test-scripts/createDomain.sh \
         wl-job.yamlt \
         wl-create-domain-job.yaml
}

#############################################################################
#
# Run introspection job, parse its output to files, and put files in a cm
#   - this emulates what the operator pod would do prior to start wl-pods
#

# Alternatively, run deployIntrospectJobPod() instead.
function deployIntrospectJob() {
  local introspect_output_cm_name=${DOMAIN_UID}-weblogic-domain-introspect-cm

  trace "Info: Run introspection job, parse its output to files, and put files in configmap '$introspect_output_cm_name'."

  # delete anything left over from a previous invocation of this function

  kubectl -n $NAMESPACE delete cm $introspect_output_cm_name \
    --ignore-not-found  \
    2>&1 | tracePipe "Info: kubectl output: "

  # run introspection job

  runJob ${DOMAIN_UID}-introspect-domain-job \
         /weblogic-operator/scripts/introspectDomain.sh \
         wl-job.yamlt \
         wl-introspect-domain-job.yaml 

  # parse job's output files

  ${SCRIPTPATH}/util_fsplit.sh \
    ${test_home}/job-${DOMAIN_UID}-introspect-domain-job.out \
    ${test_home}/jobfiles || exit 1

  # put the outputfile in a cm

  createConfigMapFromDir $introspect_output_cm_name ${test_home}/jobfiles 

}

# Here we emulate the introspect job by directly starting an introspect pod and monitoring it.
# deployIntrospectJob() does about the same thing, but starts a pod via a job
# (Running a pod directly is helpful for debugging.)

function deployIntrospectJobPod() {
  local introspect_output_cm_name=${DOMAIN_UID}-weblogic-domain-introspect-cm
  local target_yaml=${test_home}/wl-introspect-pod.yaml
  local pod_name=${DOMAIN_UID}--introspect-domain-pod
  local job_name=$pod_name

  trace "Info: Run introspection job, parse its output to files, and put files in configmap '$introspect_output_cm_name'."

  # delete anything left over from a previous invocation of this function, assume all pods
  # have already been cleaned up

  rm -f ${target_yaml}

  kubectl -n $NAMESPACE delete cm $introspect_output_cm_name \
    --ignore-not-found  \
    2>&1 | tracePipe "Info: kubectl output: "

  trace "Info: Deploying job pod '$pod_name' and waiting for it to be ready."

  (
    export SERVER_NAME=introspect
    export JOB_NAME=${DOMAIN_UID}--introspect-domain-pod
    export JOB_SCRIPT=/test-scripts/introspectDomainProxy.sh
    export SERVICE_NAME=`toDNS1123Legal ${DOMAIN_UID}-${server_name}`
    export AS_SERVICE_NAME=`toDNS1123Legal ${DOMAIN_UID}-${ADMIN_NAME}`
    if [ "${SERVER_NAME}" = "${ADMIN_NAME}" ]; then
      export LOCAL_SERVER_DEFAULT_PORT=$ADMIN_PORT
    else
      export LOCAL_SERVER_DEFAULT_PORT=$MANAGED_SERVER_PORT
    fi
    ${SCRIPTPATH}/util_subst.sh -g wl-introspect-pod.yamlt ${target_yaml}  || exit 1
  ) || exit 1

  kubectl create -f ${target_yaml} \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1

  # Wait for pod to come up successfully

  # TBD make the following a helper fn since this is the second place
  #     we wait for a pod to start, and the code is exactly the same...
  local status="0/1"
  local startsecs=$SECONDS
  local maxsecs=180
  tracen "Info: Waiting up to $maxsecs seconds for pod '$pod_name' readiness"
  while [ "${status}" != "1/1" ] ; do
    if [ $((SECONDS - startsecs)) -gt $maxsecs ]; then
      echo
      trace "Error: pod $pod_name failed to start within $maxsecs seconds.  kubectl describe:"
      kubectl -n $NAMESPACE describe pod $pod_name
      trace "Error: pod $pod_name failed to start within $maxsecs seconds.  kubectl log:"
      kubectl -n $NAMESPACE logs $pod_name
      exit 1
    fi
    echo -n "."
    sleep 1
    status=`kubectl -n $NAMESPACE get pods 2>&1 | egrep $pod_name | awk '{print $2}'`
  done
  echo "  ($((SECONDS - startsecs)) seconds)"

  local startSecs=$SECONDS
  local maxsecs=30
  local exitString=""
  tracen "Info: Waiting up to $maxsecs seconds for pod '$pod_name' to run the introspectDomain.py script."
  printdots_start
  while [ $((SECONDS - startSecs)) -lt $maxsecs ] && [ "$exitString" = "" ]; do
    exitString="`kubectl -n $NAMESPACE logs $pod_name 2>&1 | grep INTROSPECT_DOMAIN_EXIT`"
    sleep 1
  done
  printdots_end
  if [ "$exitString" = "" ]; then
    trace "Error: Introspector timed out, see 'kubectl -n $NAMESPACE logs $pod_name'."
    exit 1
  fi
  if [ ! "$exitString" = "INTROSPECT_DOMAIN_EXIT=0" ]; then
    trace "Error: Introspector pod script failed, see 'kubectl -n $NAMESPACE logs $pod_name'."
    exit 1
  fi

  # parse job pod's output files

  kubectl -n $NAMESPACE logs $pod_name > ${test_home}/job-${DOMAIN_UID}-introspect-domain-pod-job.out 

  ${SCRIPTPATH}/util_fsplit.sh \
    ${test_home}/job-${DOMAIN_UID}-introspect-domain-pod-job.out \
    ${test_home}/jobfiles || exit 1

  # put the outputfile in a cm

  createConfigMapFromDir $introspect_output_cm_name ${test_home}/jobfiles 
}

#############################################################################
#
# Launch pod and wait up to 180 seconds for it to succeed, also launch
# services.
#   - this emulates what the operator pod would do after running the introspect job
#

function deployPod() {
  local server_name=${1?}
  local pod_name=${DOMAIN_UID}-${server_name}
  local target_yaml=${test_home}/wl-${server_name}-pod.yaml 

  trace "Info: Deploying pod '$pod_name' and waiting for it to be ready."

  # delete anything left over from a previous invocation of this function

  if [ -f "${target_yaml}" ]; then
    kubectl -n $NAMESPACE delete -f ${target_yaml} \
      --ignore-not-found \
      2>&1 | tracePipe "Info: kubectl output: "
    rm -f ${target_yaml}
  fi

  # Generate server pod yaml from template and deploy it

  ( 
    export SERVER_NAME=${server_name}
    export SERVICE_NAME=`toDNS1123Legal ${DOMAIN_UID}-${server_name}`
    export AS_SERVICE_NAME=`toDNS1123Legal ${DOMAIN_UID}-${ADMIN_NAME}`
    if [ "${SERVER_NAME}" = "${ADMIN_NAME}" ]; then
      export LOCAL_SERVER_DEFAULT_PORT=$ADMIN_PORT
    else
      export LOCAL_SERVER_DEFAULT_PORT=$MANAGED_SERVER_PORT
    fi
    ${SCRIPTPATH}/util_subst.sh -g wl-pod.yamlt ${target_yaml}  || exit 1
  ) || exit 1

  kubectl create -f ${target_yaml} \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1 

  # Wait for pod to come up successfully

  local status="0/1"
  local startsecs=$SECONDS
  local maxsecs=180
  tracen "Info: Waiting up to $maxsecs seconds for pod '$pod_name' readiness"
  while [ "${status}" != "1/1" ] ; do
    if [ $((SECONDS - startsecs)) -gt $maxsecs ]; then
      echo
      trace "Error: pod $pod_name failed to start within $maxsecs seconds.  kubectl describe:"
      kubectl -n $NAMESPACE describe pod $pod_name
      trace "Error: pod $pod_name failed to start within $maxsecs seconds.  kubectl log:"
      kubectl -n $NAMESPACE logs $pod_name
      exit 1
    fi
    echo -n "."
    sleep 1
    status=`kubectl -n $NAMESPACE get pods 2>&1 | egrep $pod_name | awk '{print $2}'`
  done
  echo "  ($((SECONDS - startsecs)) seconds)"
}

function deploySinglePodService() {
  local server_name=${1?}
  local internal_port=${2?}
  local external_port=${3?}
  local service_name=`toDNS1123Legal ${DOMAIN_UID}-${server_name}`
  local target_yaml=${test_home}/wl-nodeport-svc-${service_name}.yaml

  trace "Info: Launching service '$service_name' internal_port=$internal_port external_port=$external_port."

  # delete anything left over from a previous invocation of this function
  if [ -f "${target_yaml}" ]; then
    kubectl -n $NAMESPACE delete -f ${target_yaml} \
      --ignore-not-found \
      2>&1 | tracePipe "Info: kubectl output: "
    rm -f ${target_yaml}
  fi

  ( # Generate svc yaml from template 
    export SERVER_NAME="${server_name}"
    export SERVICE_INTERNAL_PORT="${internal_port}"
    export SERVICE_EXTERNAL_PORT="${external_port}"
    export SERVICE_NAME=${service_name}
    ${SCRIPTPATH}/util_subst.sh -g wl-nodeport-svc.yamlt ${target_yaml} || exit 1
  )

  kubectl create -f ${target_yaml} \
    2>&1 | tracePipe "Info: kubectl output: " || exit 1 

  local svc=""
  local startsecs=$SECONDS
  local maxsecs=5
  while [ -z "$svc" ] ; do
    if [ $((SECONDS - startsecs)) -gt $maxsecs ]; then
      trace "Error: Service '$service_name' not found after waiting $maxsecs seconds."
      exit 1
    fi
    local cmd="kubectl get services -n $NAMESPACE -o jsonpath='{.items[?(@.metadata.name == \"$service_name\")]}'"
    svc="`eval $cmd`"
    [ -z "$svc" ] && sleep 1
  done
}


#############################################################################
#
# Check if automatic overrides and custom overrides took effect on the admin pod
#

function checkOverrides() {
  
  trace "Info: Checking admin server stdout to make sure situational config was loaded and there are no reported situational config errors."
  
  # Check for exactly 3 occurances of Info.*.BEA.*situational lines -- one for each file we're overriding.
  #   the awk expression below gets the tail of the log, everything after the last occurance of 'Starting WebLogic...'
  
  linecount="`kubectl -n ${NAMESPACE} logs ${DOMAIN_UID}-${ADMIN_NAME} | awk '/.*Starting WebLogic server with command/ { buf = "" } { buf = buf "\n" $0 } END { print buf }' | grep -ci 'Info.*BEA.*situational'`"
  logstatus=0

  if [ "$linecount" != "3" ]; then
    trace "Error: The latest boot in 'kubectl -n ${NAMESPACE} logs ${DOMAIN_UID}-${ADMIN_NAME}' does not contain exactly 3 lines that match ' grep 'Info.*BEA.*situational' ', this probably means that it's reporting situational config problems."
    logstatus=1
  fi
  
  #
  # Call on-line WLST on the admin-server to determine if overrides are
  # taking effect in the admin tree
  #
  
  trace "Info: Checking beans to see if sit-cfg took effect.  Input file '$test_home/checkBeans.input', output file '$test_home/checkBeans.out'."
  
  rm -f ${test_home}/checkBeans.input
  ${SCRIPTPATH}/util_subst.sh -g checkBeans.inputt ${test_home}/checkBeans.input || exit 1
  kubectl -n ${NAMESPACE} cp ${test_home}/checkBeans.input ${DOMAIN_UID}-${ADMIN_NAME}:/shared/checkBeans.input || exit 1
  kubectl -n ${NAMESPACE} cp ${SCRIPTPATH}/checkBeans.py ${DOMAIN_UID}-${ADMIN_NAME}:/shared/checkBeans.py || exit 1
  tracen "Info: Waiting for WLST checkBeans.py to complete."
  printdots_start
  # TBD weblogic/welcome1 should be deduced via a base64 of the admin secret
  kubectl exec -it ${DOMAIN_UID}-${ADMIN_NAME} \
    wlst.sh /shared/checkBeans.py \
      weblogic welcome1 t3://${DOMAIN_UID}-${ADMIN_NAME}:${ADMIN_PORT} \
      /shared/checkBeans.input \
      > $test_home/checkBeans.out 2>&1
  status=$?
  printdots_end
  if [ $status -ne 0 ]; then
    trace "Error: The checkBeans verification failed, see '$test_home/checkBeans.out'."
  fi

  if [ $status -ne 0 ] || [ $logstatus -ne 0 ]; then
    exit 1
  fi
}


#############################################################################
#
# Main
#
# Some of the following calls will be a partial or complete no-op if
# PVCOMMENT is set, or if CREATE_DOMAIN is set to false.
#

#
# TBD ADMIN_NAME, ADMIN_PORT, and MANAGED_SERVER_NAME_BASE, etc env vars
#     should be checked to see if topology file the introspector generated
#     matches
#


kubectl -n $NAMESPACE delete secret my-secret > /dev/null 2>&1
kubectl -n $NAMESPACE create secret generic my-secret \
        --from-literal=key1=supersecret  \
        --from-literal=key2=topsecret 2>&1 | tracePipe "Info: kubectl output: "


if [ ! "$RERUN_INTROSPECT_ONLY" = "true" ]; then

  cleanupMajor

  deployDomainConfigMap
  deployTestScriptConfigMap
  deployCustomOverridesConfigMap
  createTestRootPVDir
  deployWebLogic_PV_PVC_and_Secret
  deployCreateDomainJob
  #deployIntrospectJob
  deployIntrospectJobPod
  deployPod ${ADMIN_NAME?}
  deploySinglePodService ${ADMIN_NAME?} ${ADMIN_PORT?} 30701
  deployPod ${MANAGED_SERVER_NAME_BASE?}1
  deploySinglePodService ${MANAGED_SERVER_NAME_BASE?}1 ${MANAGED_SERVER_PORT?} 30801

else

  # This path assumes we've already run the test succesfully once, it re-uses
  # the existing domain-home/pv/pvc/secret/etc, deletes wl pods, deletes introspect job, then
  # redeploys the custom overrides, reruns the introspect job, and restarts the admin server pod.

  cleanupMinor

  deployDomainConfigMap
  deployTestScriptConfigMap
  deployCustomOverridesConfigMap
  #deployIntrospectJob
  deployIntrospectJobPod
  deployPod ${ADMIN_NAME?}
  deployPod ${MANAGED_SERVER_NAME_BASE?}1

fi

#
# Check admin-server pod log and also Call on-line WLST to check
# if automatic and custom overrides are taking effect in the bean
# tree.
#

checkOverrides

#
# TBD potentially add additional checks to verify wl pods are healthy
#

trace "Info: Success!"
