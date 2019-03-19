#!/bin/bash
#
# Purpose: Collects API Connect logs and packages into an archive.
#
# Authors:        Charles Johnson, cjohnso@us.ibm.com
#                 Franck Delporte, franck.delporte@us.ibm.com
#                 Nagarjun Nama Balaji, nagarjun.nama.balaji@ibm.com
#
#

#parse passed arguments
for switch in $@; do
    case $switch in
        *"-h"*|*"--help"*)
            echo -e 'Usage: generate_postmortem.sh {optional: LOG LIMIT}'
            echo -e ""
            echo -e "LOG LIMIT defaults to pull a maximum of 10000 lines from each pod."
            echo -e 'LOG LIMIT (if specified) must be >= 0.  (0 means no limit, not recommended)'
            echo -e ""
            echo -e "Set environment variable [APICUP_PROJECT_PATH] to the Install Assist project directory."
            echo -e 'Set using command:  export APICUP_PROJECT_PATH="/path/to/directory"'
            echo -e 'If apicup project is not available, pass the switch "--no-apicup"'
            echo -e ""
            echo -e 'To enable debug pass the switch "--debug"'
            echo -e ""
            exit 0
            ;;
        *"--debug"*)
            set -x
            DEBUG_SET=1
            if [[ $# -eq 1 ]]; then
                LOG_LIMIT="--tail=10000"
            fi
            ;;
        *"--no-apicup"*)
            NO_APICUP=1
            ;;
        *)
            if [[ "$switch" =~ ^[0-9]+$ ]]; then
                if [[ $switch -eq 0 ]]; then
                    #proceed with no log limit set
                    echo -e "Proceeding with no log limit set, this process may take quite some time to complete."
                    LOG_LIMIT=""
                else
                    LOG_LIMIT="--tail=$1"
                fi
            else
                echo -e "Parameter [LOG_LIMIT] invalid, EXITING..."
                exit 1
            fi
            if [[ -z "$DEBUG_SET" ]]; then
                set +e
            fi
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    #set defaults
    LOG_LIMIT="--tail=10000"
    set +e
fi

#====================================== Confirm pre-reqs and init variables ======================================
#----------------------------------------- Validate everything ----------------------------------------
if [[ -z "$NO_APICUP" ]]; then
    if [[ -z "$APICUP_PROJECT_PATH" ]]; then
        APICUP_PROJECT_PATH=`pwd`
    fi

    if [[ ! -f "$APICUP_PROJECT_PATH/apiconnect-up.yml" && ! -f "$APICUP_PROJECT_PATH/apiconnect-up.yaml" ]]; then
        echo -e "Set environment variable pointing to Install Assist project directory."
        echo -e "Make sure it contains the file: apiconnect-up.yml or apiconnect-up.yaml"
        echo -e 'Set using command:  export APICUP_PROJECT_PATH="/path/to/directory"'
        exit 1
    fi
fi
#------------------------------------------------------------------------------------------------------

#------------------------------- Make sure all necessary commands exists ------------------------------
which kubectl &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "Unable to locate the command [kubectl] in the path.  Either install or add it to the path.  EXITING..."
    exit 1
fi

ARCHIVE_UTILITY=`which zip 2>/dev/null`
if [[ $? -ne 0 ]]; then
    ARCHIVE_UTILITY=`which tar 2>/dev/null`
    if [[ $? -ne 0 ]]; then
        echo "Unable to locate either command [tar] / [zip] in the path.  Either install or add it to the path.  EXITING..."
        exit 1
    fi
fi

which apicup &> /dev/null
if [[ -z "$NO_APICUP" && $? -ne 0 ]]; then
    echo "Unable to locate the command [apicup] in the path.  Either install or add it to the path.  EXITING..."
    exit 1
fi

which nslookup &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "Unable to locate the command [nslookup] in the path.  Either install the package [bind-utils] or add the command [nslookup] to the path.  EXITING..."
    exit 1
fi
#------------------------------------------------------------------------------------------------------

#------------------------------------------ custom functions ------------------------------------------
#compare versions
function version_gte() { test "$1" == "$2" || test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

#XML to generate error report
function generateXmlForErrorReport()
{
cat << EOF > $1
<?xml version="1.0" encoding="UTF-8"?>
<!--  ErrorReport Request -->
<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
  <env:Body>
    <dp:request xmlns:dp="http://www.datapower.com/schemas/management" domain="apiconnect">
      <dp:do-action>
        <ErrorReport/>
      </dp:do-action>
    </dp:request>
  </env:Body>
</env:Envelope>
EOF
}
#------------------------------------------------------------------------------------------------------

#------------------------------------------- Set variables --------------------------------------------
LOG_PATH="/tmp"
CURRENT_PATH=`pwd`
TIMESTAMP=`date +%Y%m%dT%H%M%S%Z`
TEMP_NAME="postmortem-$TIMESTAMP"
TEMP_PATH="${LOG_PATH}/${TEMP_NAME}"

NAMESPACE_LIST="kube-system"
ARCHIVE_FILE=""

ERROR_REPORT_SLEEP_TIMEOUT=30

MIN_DOCKER_VERSION="17.03"
MIN_KUBELET_VERSION="1.10"

COLOR_YELLOW=`tput setaf 3`
COLOR_WHITE=`tput setaf 7`
COLOR_RESET=`tput sgr0`
#------------------------------------------------------------------------------------------------------

#------------------------------------------- Clean up area --------------------------------------------
function cleanup {
  echo "Cleaning up.  Removing directory [$TEMP_PATH]."
  rm -fr $TEMP_PATH
}

trap cleanup EXIT
#------------------------------------------------------------------------------------------------------
#=================================================================================================================

echo -e "Generating postmortem, please wait..."

mkdir -p $TEMP_PATH

#determine if metrics is installed
kubectl get pods --all-namespaces | grep -q "metrics-server"
OUTPUT_METRICS=$?

kubectl get ns 2> /dev/null | grep -q "rook-ceph"
if [[ $? -eq 0 ]]; then
    NAMESPACE_LIST+=" rook-ceph"
fi

kubectl get ns 2> /dev/null | grep -q "rook-ceph-system"
if [[ $? -eq 0 ]]; then
    NAMESPACE_LIST+=" rook-ceph-system"
fi

#================================================ pull apicup data ===============================================
if [[ -z "$NO_APICUP" ]]; then
    #----------------------------------------- create directories -----------------------------------------
    APICUP_DATA="${TEMP_PATH}/apicup"
    APICUP_CERTS_DATA="${APICUP_DATA}/certs"
    APICUP_ENDPOINT_DATA="${APICUP_DATA}/endpoints"

    mkdir -p $APICUP_CERTS_DATA
    mkdir -p $APICUP_ENDPOINT_DATA
    #------------------------------------------------------------------------------------------------------
    cd $APICUP_PROJECT_PATH

    #grab version
    apicup version --semver > "${APICUP_DATA}/apicup.version"

    #deploy busybox
    kubectl get pods 2>/dev/null | grep -q busybox
    if [[ $? -eq 0 ]]; then
        REMOVE_BUSYBOX=0
    else
        #install busybox pod
        REMOVE_BUSYBOX=1
        kubectl create -f https://k8s.io/examples/admin/dns/busybox.yaml &>/dev/null
        sleep 10
    fi

    #loop through subsystems
    OUTPUT1=`apicup subsys list 2>/dev/null | cut -d' ' -f1`
    while read line1; do
        if [[ "${line1,,}" != *"name"* ]]; then
            #grab certs lists for subsystem
            apicup certs list $line1 1>"${APICUP_CERTS_DATA}/certs-$line1.out" 2>/dev/null

            #check each endpoint using nslookup
            OUTPUT2=`apicup subsys get $line1 2>/dev/null`
            START_READ=0
            i=0
            while read line2; do
                if [[ "${line2,,}" == *"endpoints"* ]]; then
                    i=4
                    START_READ=1
                elif [[ $START_READ -eq 1 && $i -gt 0 ]]; then
                    ((i--))
                elif [[ $START_READ -eq 1 && $i -eq 0 && ${#line2} -eq 0 ]]; then
                    break
                elif [[ $START_READ -eq 1 && $i -eq 0 ]]; then
                    name=`echo "$line2" | awk -F' ' '{print $1}'`
                    endpoint=`echo "$line2" | awk -F' ' '{print $2}'`

                    echo -e "$ nslookup $endpoint\n" >"${APICUP_ENDPOINT_DATA}/nslookup-${name}.out"
                    kubectl exec busybox -- nslookup $endpoint &>>"${APICUP_ENDPOINT_DATA}/nslookup-${name}.out"
                fi
            done <<< "$OUTPUT2"
        fi
    done <<< "$OUTPUT1"

    #remove busybox pod
    if [[ $REMOVE_BUSYBOX -eq 1 ]]; then
        kubectl delete -f https://k8s.io/examples/admin/dns/busybox.yaml &>/dev/null
    fi

    #grab configuration file
    if [[ -f "$APICUP_PROJECT_PATH/apiconnect-up.yml" ]]; then
        cp $APICUP_PROJECT_PATH/apiconnect-up.yml $APICUP_DATA/apiconnect-up.yml
    else
        cp $APICUP_PROJECT_PATH/apiconnect-up.yaml $APICUP_DATA/apiconnect-up.yaml
    fi
fi
#=================================================================================================================

#================================================= pull helm data ================================================
#----------------------------------------- create directories -----------------------------------------
HELM_DATA="${TEMP_PATH}/helm"
HELM_DEPLOYMENT_DATA="${HELM_DATA}/deployments"

mkdir -p $HELM_DEPLOYMENT_DATA
#------------------------------------------------------------------------------------------------------

#grab version
helm version > "${HELM_DATA}/helm.version"

#initialize variables
SUBSYS_ANALYTICS=""
SUBSYS_MANAGER=""
SUBSYS_PORTAL=""
SUBSYS_CASSANDRA_OPERATOR=""
SUBSYS_GATEWAY=""
SUBSYS_INGRESS=""

OUTPUT=`helm ls -a 2>/dev/null`
echo "$OUTPUT" > "${HELM_DATA}/deployments.out"
while read line; do
    if [[ "$line" != *"NAME"* ]]; then
        release=`echo "$line" | awk -F ' ' '{print $1}'`
        chart=`echo "$line" | awk -F ' ' '{print $9}'`
        ns=`echo "$line" | awk -F ' ' '{print $(NF -0)}'`
        namespace=""

        case $chart in
            *"apic-analytics"*) 
                namespace=$ns
                SUBSYS_ANALYTICS+=" $release"
                ;;
            *"apiconnect"*)
                namespace=$ns
                SUBSYS_MANAGER+=" $release"
                ;;
            *"apic-portal"*)
                namespace=$ns
                SUBSYS_PORTAL+=" $release"
                ;;
            *"cassandra-operator"*)
                namespace=$ns
                SUBSYS_CASSANDRA_OPERATOR+=" $release"
                ;;
            *"dynamic-gateway-service"*)
                namespace=$ns
                SUBSYS_GATEWAY+=" $release"
                ;;
            *"nginx-ingress"*)
                namespace=$ns
                SUBSYS_INGRESS+=" $release"
                ;;
            *) ;;
        esac

        if [[ ! -z "$namespace" ]]; then
            ns_found=0
            for ns in $NAMESPACE_LIST; do
                if [[ "${namespace,,}" == "${ns,,}" ]]; then
                    ns_found=1
                    break
                fi
            done
            if [[ $ns_found -eq 0 ]]; then
                NAMESPACE_LIST+=" $namespace"
            fi
        fi

        helm get values --all $release 1>"${HELM_DEPLOYMENT_DATA}/${release}_${chart}.out" 2>/dev/null
        [ $? -eq 0 ] || rm -f "${HELM_DEPLOYMENT_DATA}/${release}_${chart}.out"
    fi
done <<< "$OUTPUT"

#if still blank then mark subsystem as does not exist
[[ ! -z "$SUBSYS_ANALYTICS" ]] || SUBSYS_ANALYTICS="ISNOTSET"
[[ ! -z "$SUBSYS_MANAGER" ]] || SUBSYS_MANAGER="ISNOTSET"
[[ ! -z "$SUBSYS_PORTAL" ]] || SUBSYS_PORTAL="ISNOTSET"
[[ ! -z "$SUBSYS_CASSANDRA_OPERATOR" ]] || SUBSYS_CASSANDRA_OPERATOR="ISNOTSET"
[[ ! -z "$SUBSYS_ANALYTICS" ]] || SUBSYS_GATEWAY="ISNOTSET"
[[ ! -z "$SUBSYS_INGRESS" ]] || SUBSYS_INGRESS="ISNOTSET"
#=================================================================================================================


#============================================= pull kubernetes data ==============================================
#----------------------------------------- create directories -----------------------------------------
K8S_DATA="${TEMP_PATH}/kubernetes"

K8S_CLUSTER="${K8S_DATA}/cluster"
K8S_NAMESPACES="${K8S_DATA}/namespaces"

K8S_CLUSTER_NODE_DATA="${K8S_CLUSTER}/nodes"
K8S_CLUSTER_LIST_DATA="${K8S_CLUSTER}/lists"
K8S_CLUSTER_ROLE_DATA="${K8S_CLUSTER}/clusterroles"
K8S_CLUSTER_ROLEBINDING_DATA="${K8S_CLUSTER}/clusterrolebindings"
K8S_CLUSTER_STORAGE_DATA="${K8S_CLUSTER}/storage"

mkdir -p $K8S_CLUSTER_NODE_DATA
mkdir -p $K8S_CLUSTER_LIST_DATA
mkdir -p $K8S_CLUSTER_ROLE_DATA
mkdir -p $K8S_CLUSTER_ROLEBINDING_DATA
mkdir -p $K8S_CLUSTER_STORAGE_DATA

#------------------------------------------------------------------------------------------------------

#grab version
kubectl version 1>"${K8S_DATA}/kubectl.version" 2>/dev/null
docker version 1>"${K8S_DATA}/docker.version" 2>/dev/null

#----------------------------------- collect cluster specific data ------------------------------------
#node
OUTPUT=`kubectl get nodes 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" &> "${K8S_CLUSTER_NODE_DATA}/nodes.out"
    while read line; do
        name=`echo "$line" | awk -F ' ' '{print $1}'`
        role=`echo "$line" | awk -F ' ' '{print $3}'`

        describe_stdout=`kubectl describe node $name 2>/dev/null`
        if [[ $? -eq 0 && ${#describe_stdout} -gt 0 ]]; then
            if [[ -z "$role" ]]; then
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DATA}/describe-${name}.out"
            else
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DATA}/describe-${name}_${role}.out"
            fi

            if [[ -z "$ARCHIVE_FILE" && "$role" == *"master"* ]]; then
                host=`echo $name | cut -d'.' -f1`
                if [[ -z "$host" ]]; then
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
                else
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${host}-${TIMESTAMP}"
                fi
            fi

            #check the docker / kubelet versions
            docker_version=`echo "$describe_stdout" | grep -i docker | awk -F'//' '{print $2}'`
            kubelet_version=`echo "$describe_stdout" | grep "Kubelet Version:" | awk -F' ' '{print $NF}' | awk -F'v' '{print $2}'`

            version_gte $docker_version $MIN_DOCKER_VERSION
            if [[ $? -ne 0 ]]; then
                warning1="WARNING!  Node "
                warning2=" docker version [$docker_version] less than minimum [$MIN_DOCKER_VERSION]."
                echo -e "${COLOR_YELLOW}${warning1}${COLOR_WHITE}$name${COLOR_YELLOW}${warning2}${COLOR_RESET}"
                echo -e "${warning1}${name}${warning2}" >> "${K8S_DATA}/warnings.out"
            fi

            version_gte $kubelet_version $MIN_KUBELET_VERSION
            if [[ $? -ne 0 ]]; then
                warning1="WARNING!  Node "
                warning2=" kubelet version [$kubelet_version] less than minimum [$MIN_KUBELET_VERSION]."
                echo -e "${COLOR_YELLOW}${warning1}${COLOR_WHITE}$name${COLOR_YELLOW}${warning2}${COLOR_RESET}"
                echo -e "${warning1}${name}${warning2}" >> "${K8S_DATA}/warnings.out"
            fi
        fi
        
        
    done <<< "$OUTPUT"

    if [[ $OUTPUT_METRICS -eq 0 ]]; then
        kubectl top nodes &> "${K8S_CLUSTER_NODE_DATA}/top.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_NODE_DATA}/top.out"
    fi
else
    rm -fr $K8S_CLUSTER_NODE_DATA
fi

if [[ -z "$ARCHIVE_FILE" ]]; then
    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
fi

#crds
OUTPUT=`kubectl get crds 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_LIST_DATA}/crds.out"
else
    rm -fr $K8S_CLUSTER_LIST_DATA
fi

#storage
OUTPUT=`kubectl get pv 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_STORAGE_DATA}/pv.out"
fi
OUTPUT=`kubectl get storageclasses 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_STORAGE_DATA}/storageclasses.out"
fi
if [[ ! -f "${K8S_CLUSTER_STORAGE_DATA}/pv.out" && ! -f "${K8S_CLUSTER_STORAGE_DATA}/storageclasses.out" ]]; then
    rm -fr $K8S_CLUSTER_STORAGE_DATA
fi

#cluster roles
OUTPUT=`kubectl get clusterroles 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        kubectl describe clusterrole $line &> "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLE_DATA
fi

#cluster rolebindings
OUTPUT=`kubectl get clusterrolebindings 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        kubectl describe clusterrolebinding $line &> "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLEBINDING_DATA
fi
#------------------------------------------------------------------------------------------------------

#---------------------------------- collect namespace specific data -----------------------------------
for NAMESPACE in $NAMESPACE_LIST; do

    K8S_NAMESPACES_SPECIFIC="${K8S_NAMESPACES}/${NAMESPACE}"

    K8S_NAMESPACES_LIST_DATA="${K8S_NAMESPACES_SPECIFIC}/lists"
    K8S_NAMESPACES_STORAGE_DATA="${K8S_NAMESPACES_SPECIFIC}/storage"
    K8S_NAMESPACES_CASSANDRA_DATA="${K8S_NAMESPACES_SPECIFIC}/cassandra"

    K8S_NAMESPACES_CONFIGMAP_DATA="${K8S_NAMESPACES_SPECIFIC}/configmaps"
    K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT="${K8S_NAMESPACES_CONFIGMAP_DATA}/yaml"
    K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA="${K8S_NAMESPACES_CONFIGMAP_DATA}/describe"

    K8S_NAMESPACES_JOB_DATA="${K8S_NAMESPACES_SPECIFIC}/jobs"
    K8S_NAMESPACES_JOB_DESCRIBE_DATA="${K8S_NAMESPACES_JOB_DATA}/describe"

    K8S_NAMESPACES_POD_DATA="${K8S_NAMESPACES_SPECIFIC}/pods"
    K8S_NAMESPACES_POD_DESCRIBE_DATA="${K8S_NAMESPACES_POD_DATA}/describe"
    K8S_NAMESPACES_POD_LOG_DATA="${K8S_NAMESPACES_POD_DATA}/logs"

    K8S_NAMESPACES_ROLE_DATA="${K8S_NAMESPACES_SPECIFIC}/roles"
    K8S_NAMESPACES_ROLE_DESCRIBE_DATA="${K8S_NAMESPACES_ROLE_DATA}/describe"

    K8S_NAMESPACES_ROLEBINDING_DATA="${K8S_NAMESPACES_SPECIFIC}/rolebindings"
    K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA="${K8S_NAMESPACES_ROLEBINDING_DATA}/describe"

    K8S_NAMESPACES_SA_DATA="${K8S_NAMESPACES_SPECIFIC}/service_accounts"
    K8S_NAMESPACES_SA_DESCRIBE_DATA="${K8S_NAMESPACES_SA_DATA}/describe"

    mkdir -p $K8S_NAMESPACES_LIST_DATA
    mkdir -p $K8S_NAMESPACES_STORAGE_DATA
    mkdir -p $K8S_NAMESPACES_CASSANDRA_DATA

    mkdir -p $K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_JOB_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_POD_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_POD_LOG_DATA

    mkdir -p $K8S_NAMESPACES_ROLE_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_SA_DESCRIBE_DATA

    #grab lists
    OUTPUT=`kubectl get endpoints -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/endpoints.out"
    OUTPUT=`kubectl get events -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/events.out"
    OUTPUT=`kubectl get ingress -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/ingress.out"
    OUTPUT=`kubectl get secrets -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/secrets.out"
    OUTPUT=`kubectl get svc -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/services.out"


    #grab cassandra data
    OUTPUT=`kubectl get cassandraclusters -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CASSANDRA_DATA}/cassandraclusters.out"

        while read line; do
            cc=`echo "$line" | cut -d' ' -f1`
            kubectl describe cassandracluster $cc -n $NAMESPACE &> "${K8S_NAMESPACES_CASSANDRA_DATA}/${cc}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CASSANDRA_DATA}/${cc}.out"
        done <<< "$OUTPUT"

        #nodetool status
        OUTPUT=`kubectl get pods -n $NAMESPACE 2>/dev/null | grep "\-cc\-" | grep -v "stats" | grep -v "repair"`
        while read line; do
            pod=`echo "${OUTPUT}" | awk -F' ' '{print $1}'`
            kubectl exec -n $NAMESPACE $pod -- nodetool status &>"${K8S_NAMESPACES_CASSANDRA_DATA}/${pod}-nodetool_status.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CASSANDRA_DATA}/${pod}-nodetool_status.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CASSANDRA_DATA
    fi

    #grab storage data
    OUTPUT=`kubectl get pvc -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0  ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_STORAGE_DATA}/pvc.out"
    else
        rm -fr $K8S_NAMESPACES_STORAGE_DATA
    fi

    #grab job data
    OUTPUT=`kubectl get jobs -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_JOB_DATA}/jobs.out"
        while read line; do
            job=`echo "$line" | cut -d' ' -f1`
            kubectl describe job $job -n $NAMESPACE &> "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_JOB_DATA
    fi

    #grab configmap data
    OUTPUT=`kubectl get configmaps -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CONFIGMAP_DATA}/configmaps.out"
        while read line; do
            cm=`echo "$line" | cut -d' ' -f1`
            kubectl get configmap $cm -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT}/${cm}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUTA}/${cm}.yaml"

            kubectl describe configmap $cm -n $NAMESPACE &> "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CONFIGMAP_DATA
    fi

    #grab pod data
    OUTPUT=`kubectl get pods -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_POD_DATA}/pods.out"
        while read line; do
            pod=`echo "$line" | awk -F ' ' '{print $1}'`
            ready=`echo "$line" | awk -F ' ' '{print $2}'`
            status=`echo "$line" | awk -F ' ' '{print $3}'`
            pod_helm_release=`echo "$pod" | awk -F '-' '{print $1}'`

            IS_INGRESS=0
            IS_GATEWAY=0

            case $NAMESPACE in
                "kube-system")
                    case "$pod" in
                        *"calico"*|*"flannel"*) SUBFOLDER="networking";;
                        *"coredns"*) SUBFOLDER="coredns";;
                        *"etcd"*) SUBFOLDER="etcd";;
                        *"ingress"*) 
                            IS_INGRESS=1
                            SUBFOLDER="ingress"
                            ;;
                        *"kube"*) SUBFOLDER="kube";;
                        *"metrics"*) SUBFOLDER="metrics";;
                        *"tiller"*) SUBFOLDER="tiller";;
                        *) SUBFOLDER="other";;
                    esac
                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}/${SUBFOLDER}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}/${SUBFOLDER}";;
                *"rook"*)
                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}";;
                *)
                    if [[ "$SUBSYS_ANALYTICS" == *"$pod_helm_release"* ]]; then
                        SUBFOLDER="analytics"
                    elif [[ "$SUBSYS_GATEWAY" == *"$pod_helm_release"* ]]; then
                        SUBFOLDER="gateway"
                        IS_GATEWAY=1
                    elif [[ "$SUBSYS_INGRESS" == *"$pod_helm_release"* ]]; then
                        IS_INGRESS=1
                        SUBFOLDER="ingress"
                    elif [[ "$SUBSYS_MANAGER" == *"$pod_helm_release"* ]]; then
                        SUBFOLDER="manager"
                    elif [[ "$SUBSYS_CASSANDRA_OPERATOR" == *"$pod_helm_release"* ]]; then
                        SUBFOLDER="manager"
                    elif [[ "$SUBSYS_PORTAL" == *"$pod_helm_release"* ]]; then
                        SUBFOLDER="portal"
                    else
                        SUBFOLDER="other"
                    fi

                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}/${SUBFOLDER}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}/${SUBFOLDER}";;
            esac
            
            #make sure directories exist
            if [[ ! -d "$DESCRIBE_TARGET_PATH" ]]; then
                mkdir -p $DESCRIBE_TARGET_PATH
            fi
            if [[ ! -d "$LOG_TARGET_PATH" ]]; then
                mkdir -p $LOG_TARGET_PATH
            fi

            #grab ingress configuration
            if [[ $IS_INGRESS -eq 1 ]]; then
                kubectl cp -n $NAMESPACE "${pod}:/etc/nginx/nginx.conf" "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" &>/dev/null
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out"

                #reset variable
                IS_INGRESS=0
            fi

            #grab gateway data
            if [[ $IS_GATEWAY -eq 1 && "$ready" == "1/1" && "$status" == "Running" ]]; then
                #grab gwd-log.log
                kubectl cp -n $NAMESPACE "${pod}:/drouter/temporary/log/apiconnect/gwd-log.log" "${LOG_TARGET_PATH}/gwd-log.log" &>/dev/null

                #open SOMA port to localhost
                kubectl port-forward ${pod} 5550:5550 -n ${NAMESPACE} 1>/dev/null 2>/dev/null &
                pid=$!
                #necessary to wait for port-forward to start
                sleep 1

                #write out XML to to file
                XML_PATH="${TEMP_PATH}/error_report.xml"
                generateXmlForErrorReport "$XML_PATH"

                #POST XML to gateway, start error report creation
                response=`curl -k -X POST --write-out %{http_code} --silent --output /dev/null \
                    -u admin:admin \
                    -H "Content-Type: application/xml" \
                    -d "@${XML_PATH}" \
                    https://127.0.0.1:5550`

                #only proceed with error report if response status code is 200
                if [[ $response -eq 200 ]]; then
                    
                    #pull error report
                    echo -e "Pausing for error report to generate..."
                    sleep $ERROR_REPORT_SLEEP_TIMEOUT

                    #this will give a link that points to the target error report
                    kubectl cp -n $NAMESPACE "${pod}:/drouter/temporary/error-report.txt.gz" "${LOG_TARGET_PATH}/error-report.txt.gz" &>/dev/null

                    #extract path
                    REPORT_PATH=`ls -l ${LOG_TARGET_PATH} | grep error-report.txt.gz | awk -F' ' '{print $NF}'`
                    if [[ ! -v "$REPORT_PATH" ]]; then
                        #extract filename from path
                        REPORT_NAME=$(basename $REPORT_PATH)

                        #grab error report
                        kubectl cp -n $NAMESPACE "${pod}:${REPORT_PATH}" "${LOG_TARGET_PATH}/${REPORT_NAME}" &>/dev/null
                    fi

                    #remove link
                    rm -f "${LOG_TARGET_PATH}/error-report.txt.gz"
                fi

                #clean up
                kill -9 $pid
                wait $pid &>/dev/null
                rm -f $XML_PATH $SCRIPT_PATH

                #reset variable
                IS_GATEWAY=0
            fi

            #write out pod descriptions
            kubectl describe pod -n $NAMESPACE $pod &> "${DESCRIBE_TARGET_PATH}/${pod}.out"
            [ $? -eq 0 ] || rm -f "${DESCRIBE_TARGET_PATH}/${pod}.out"

            #write out logs
            for container in `kubectl get pod -n $NAMESPACE $pod -o jsonpath="{.spec.containers[*].name}" 2>/dev/null`; do
                kubectl logs -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}.log"
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_${container}.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}.log"

                kubectl logs --previous -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"
                [[ $? -eq 0 && -s  "${LOG_TARGET_PATH}/${pod}_${container}_previous.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"
            done
        done <<< "$OUTPUT"

        #grab metric data
        if [[ $OUTPUT_METRICS -eq 0 ]]; then
            kubectl top pods -n $NAMESPACE &> "${K8S_NAMESPACES_POD_DATA}/top.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_POD_DATA}/top.out"
        fi
    else
        rm -fr $K8S_NAMESPACES_POD_DATA
    fi

    #grab role data
    OUTPUT=`kubectl get roles -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLE_DATA}/roles.out"
        while read line; do
            role=`echo "$line" | cut -d' ' -f1`
            kubectl describe role $role -n $NAMESPACE &> "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLE_DATA
    fi

    #grab rolebinding data
    OUTPUT=`kubectl get rolebindings -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLEBINDING_DATA}/rolebindings.out"
        while read line; do
            rolebinding=`echo "$line" | cut -d' ' -f1`
            kubectl describe rolebinding $rolebinding -n $NAMESPACE &> "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLEBINDING_DATA
    fi
    
    #grab role service account data
    OUTPUT=`kubectl get sa -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SA_DATA}/sa.out"
        while read line; do
            sa=`echo "$line" | cut -d' ' -f1`
            kubectl describe sa $sa -n $NAMESPACE &> "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_SA_DATA
    fi
done
#------------------------------------------------------------------------------------------------------
#=================================================================================================================

#write out data to zip file
cd $TEMP_PATH
if [[ "${ARCHIVE_UTILITY,,}" == *"zip"* ]]; then
    ARCHIVE_FILE="${ARCHIVE_FILE}.zip"
    zip -rq $ARCHIVE_FILE .
else
    ARCHIVE_FILE="${ARCHIVE_FILE}.tgz"
    tar -cz -f $ARCHIVE_FILE .
fi

echo -e "Created [$ARCHIVE_FILE]."
exit 0
