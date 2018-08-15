#!/bin/bash
[[ $# != 2 ]] && echo -e "Fatal error.\nUsage: $0 gcp_project_name kube_user_email_address" && exit 1

gcloud config set project "$1"
proj=$(gcloud config list --format='value(core.project)')

zone="europe-west1-b"
cluster="cluster-1"
gcloud container clusters create $cluster --zone $zone --username "admin" \
--cluster-version "1.9.7-gke.5" --machine-type "n1-standard-2" --image-type "COS" --disk-size "100" \
--scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/devstorage.read_only",\
"https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring",\
"https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly",\
"https://www.googleapis.com/auth/trace.append" \
--num-nodes "4" --network "default" --enable-cloud-logging --enable-cloud-monitoring --enable-ip-alias --no-enable-autorepair --async
cluster="cluster-2"
zone2="southamerica-east1-b"
gcloud container clusters create $cluster --zone $zone2 --username "admin" \
--cluster-version "1.9.7-gke.5" --machine-type "n1-standard-2" --image-type "COS" --disk-size "100" \
--scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/devstorage.read_only",\
"https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring",\
"https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly",\
"https://www.googleapis.com/auth/trace.append" \
--num-nodes "4" --network "default" --enable-cloud-logging --enable-cloud-monitoring --enable-ip-alias --no-enable-autorepair

gcloud container clusters list

gcloud container clusters get-credentials cluster-1 --zone $zone
gcloud container clusters get-credentials cluster-2 --zone $zone2

kubectl config use-context "gke_${proj}_${zone}_cluster-1"
kubectl get pods --all-namespaces

kubectl create clusterrolebinding gke-cluster-admin-binding --clusterrole=cluster-admin --user="$2"

kubectl config use-context "gke_${proj}_${zone2}_cluster-2"
kubectl get pods --all-namespaces

kubectl create clusterrolebinding gke-cluster-admin-binding --clusterrole=cluster-admin --user="$2"

function join_by { local IFS="$1"; shift; echo "$*"; }
ALL_CLUSTER_CIDRS=$(gcloud container clusters list --format='value(clusterIpv4Cidr)' | sort | uniq)
ALL_CLUSTER_CIDRS=$(join_by , $(echo "${ALL_CLUSTER_CIDRS}"))
ALL_CLUSTER_NETTAGS=$(gcloud compute instances list --format='value(tags.items.[0])' | sort | uniq)
ALL_CLUSTER_NETTAGS=$(join_by , $(echo "${ALL_CLUSTER_NETTAGS}"))
gcloud compute firewall-rules create istio-multicluster-test-pods \
  --allow=tcp,udp,icmp,esp,ah,sctp \
  --direction=INGRESS \
  --priority=900 \
  --source-ranges="${ALL_CLUSTER_CIDRS}" \
  --target-tags="${ALL_CLUSTER_NETTAGS}" --quiet


git clone git@github.com:istio/istio.git
cd istio

kubectl config use-context "gke_${proj}_${zone}_cluster-1"
helm template install/kubernetes/helm/istio --name istio --namespace istio-system > ../istio_master.yaml
kubectl create ns istio-system
kubectl apply -f ../istio_master.yaml
kubectl label namespace default istio-injection=enabled


#TODO wait here 
sleep 60

kubectl get pods -n istio-system

export PILOT_POD_IP=$(kubectl -n istio-system get pod -l istio=pilot -o jsonpath='{.items[0].status.podIP}')
export POLICY_POD_IP=$(kubectl -n istio-system get pod -l istio=mixer -o jsonpath='{.items[0].status.podIP}')
export STATSD_POD_IP=$(kubectl -n istio-system get pod -l istio=statsd-prom-bridge -o jsonpath='{.items[0].status.podIP}')
export TELEMETRY_POD_IP=$(kubectl -n istio-system get pod -l istio-mixer-type=telemetry -o jsonpath='{.items[0].status.podIP}')

helm template install/kubernetes/helm/istio-remote --namespace istio-system \
  --name istio-remote \
  --set global.remotePilotAddress=${PILOT_POD_IP} \
  --set global.remotePolicyAddress=${POLICY_POD_IP} \
  --set global.remoteTelemetryAddress=${TELEMETRY_POD_IP} \
  --set global.proxy.envoyStatsd.enabled=true \
  --set global.proxy.envoyStatsd.host=${STATSD_POD_IP} > ../istio-remote.yaml

kubectl config use-context "gke_${proj}_${zone2}_cluster-2"
kubectl create ns istio-system
kubectl apply -f ../istio-remote.yaml
kubectl label namespace default istio-injection=enabled

export WORK_DIR=$(pwd)
CLUSTER_NAME=$(kubectl config view --minify=true -o "jsonpath={.clusters[].name}")
CLUSTER_NAME="${CLUSTER_NAME##*_}"
export KUBECFG_FILE=${WORK_DIR}/${CLUSTER_NAME}
SERVER=$(kubectl config view --minify=true -o "jsonpath={.clusters[].cluster.server}")
NAMESPACE=istio-system
SERVICE_ACCOUNT=istio-multi
SECRET_NAME=$(kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} -o jsonpath='{.secrets[].name}')
CA_DATA=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o "jsonpath={.data['ca\.crt']}")
TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o "jsonpath={.data['token']}" | base64 --decode)


cat <<EOF > ${KUBECFG_FILE}
apiVersion: v1
clusters:
   - cluster:
       certificate-authority-data: ${CA_DATA}
       server: ${SERVER}
     name: ${CLUSTER_NAME}
contexts:
   - context:
       cluster: ${CLUSTER_NAME}
       user: ${CLUSTER_NAME}
     name: ${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}
kind: Config
preferences: {}
users:
   - name: ${CLUSTER_NAME}
     user:
       token: ${TOKEN}
EOF


kubectl config use-context "gke_${proj}_${zone}_cluster-1"
kubectl create secret generic ${CLUSTER_NAME} --from-file ${KUBECFG_FILE} -n ${NAMESPACE}
kubectl label secret ${CLUSTER_NAME} istio/multiCluster=true -n ${NAMESPACE}


kubectl config use-context "gke_${proj}_${zone}_cluster-1"
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml
kubectl delete deployment reviews-v3

kubectl config use-context "gke_${proj}_${zone2}_cluster-2"
kubectl apply -f ../reviews-v3.yaml


kubectl get svc istio-ingressgateway -n istio-system

