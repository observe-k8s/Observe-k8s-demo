#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
###
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
###########################################################################################################
####  Required Environment variable :
#### GITCLONE: if parameter is not passed with a value then the script will clone the repo
#### oteldemo_version : default value v0.4.0-alpha. But can deploy newer version of the otel-demo application
#########################################################################################################
while [ $# -gt 0 ]; do
  case "$1" in
  --gitclone)
    GITCLONE="$2"
    shift 2
    ;;
   --oteldemo_version)
    VERSION="$2"
    shift 2
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done

if [ -z "$GITCLONE" ]; then
  GITCLONE=1
fi

if [ -z "$VERSION" ]; then
  VERSION=v1.2.1
    echo "Deploying the Otel demo version $VERSION"
fi
#if ! command -v eksctl >/dev/null 2>&1; then
#    echo "Please install eksctl before continuing"
#    exit 1
#fi

#if ! command -v aws >/dev/null 2>&1; then
#    echo "Please install aws before continuing"
#    exit 1

################################################################################
### Clone repo
if [ "$GITCLONE" -eq 1 ]; then
  echo "local deployment"
else
  echo "-- Bringing up a k3d cluster --"
  k3d cluster create observeK8s --config=/root/k3dconfig.yaml --wait
  K3d_mode=1
  # Add sleep before continuing to prevent misleading error
  sleep 10

  echo "-- Waiting for all resources to be ready (timeout 2 mins) --"
  kubectl wait --for=condition=ready pods --all --all-namespaces --timeout=2m
fi

###### DEploy Nginx
echo "start depploying Nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to use the dns entry /ELB/ALB
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/K8sdemo.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml

##Updating deployment files
sed -i "s,VERSION_TO_REPLACE,$VERSION," kubernetes-manifests/K8sdemo.yaml


### Depploy Prometheus
echo "start depploying Prometheus"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack --set sidecar.datasources.enabled=true --set sidecar.datasources.label=grafana_datasource --set sidecar.datasources.labelValue="1" --set sidecar.dashboards.enabled=true
##wait that the prometheus pod is started
kubectl wait pod --namespace default -l "release=prometheus" --for=condition=Ready --timeout=2m
PROMETHEUS_SERVER=$(kubectl get svc -l app=kube-prometheus-stack-prometheus -o jsonpath="{.items[0].metadata.name}")
echo "Prometheus service name is $PROMETHEUS_SERVER"
GRAFANA_SERVICE=$(kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")
echo "Grafana service name is  $GRAFANA_SERVICE"
ALERT_MANAGER_SVC=$(kubectl get svc -l app=kube-prometheus-stack-alertmanager -o jsonpath="{.items[0].metadata.name}")
echo "Alertmanager service name is  $ALERT_MANAGER_SVC"

#update the configuration of prometheus
kubectl apply -f prometheus/PrometheusRule.yaml
kubectl create secret generic addtional-scrape-configs --from-file=prometheus/additionnalscrapeconfig.yaml
kubectl apply -f prometheus/Prometheus.yaml

## Adding the grafana Helm Repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.0/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# Deploying Tempo
echo "Deploying Tempo"
kubectl create ns tempo
helm upgrade --install tempo-distributed grafana/tempo --namespace tempo --set queryFrontend.query.enabled=true --set prometheusRule.enabled=true --set metricsGenerator.enabled=true --set memcached.enabled=true
kubectl wait pod -l app.kubernetes.io/instance=tempo -n tempo --for=condition=Ready --timeout=2m
TEMPO_SERICE_NAME=$(kubectl  get svc -l  app.kubernetes.io/name=tempo -n tempo -o jsonpath="{.items[0].metadata.name}")
sed -i "s,TEMPO_TO_REPLACE,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-sidecar.yaml
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," fluent/clusterfilter.yaml
#Deploying the fluent operator
echo "Deploying FluentOperator"
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v2.0.1/fluent-operator.tgz

# Deploying Loki
echo "Deploying Loki"
kubectl create ns loki
helm upgrade --install loki grafana/loki --namespace loki --set loki.auth_enabled=false  --set minio.enabled=true
kubectl wait pod -n loki -l  app=loki --for=condition=Ready --timeout=2m
LOKI_SERVICE=$(kubectl  get svc -l app.kubernetes.io/component=gateway  -n loki -o jsonpath="{.items[0].metadata.name}")
sed -i "s,LOKI_SERVICE_TOREPLACE,$LOKI_SERVICE," fluent/ClusterOutput_loki.yaml


# Deploy the fluent agents
kubectl apply -f fluent/fluentbit_deployment.yaml  -n kubesphere-logging-system
kubectl apply -f fluent/ClusterOutput_loki.yaml  -n kubesphere-logging-system
kubectl apply -f fluent/clusterfilter.yaml  -n kubesphere-logging-system
# Deploy the Kubecost
kubectl apply -f grafana/ingress.yaml
if [ "$K3d_mode" -eq 1 ]; then
  PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d)
  USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 -d)
else
  PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
  USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 --decode)
fi
echo "Deploying Kubecost"
kubectl create namespace kubecost
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer --namespace kubecost --set kubecostToken="aGVucmlrLnJleGVkQGR5bmF0cmFjZS5jb20=xm343yadf98" --set prometheus.kube-state-metrics.disabled=true --set prometheus.nodeExporter.enabled=false --set ingress.enabled=true --set ingress.hosts[0]="kubecost.$IP.nip.io" --set global.grafana.enabled=false --set global.grafana.fqdn="http://$GRAFANA_SERVICE.default.svc" --set prometheusRule.enabled=true --set global.prometheus.fqdn="http://$PROMETHEUS_SERVER.default.svc:9090" --set global.prometheus.enabled=false --set serviceMonitor.enabled=true
sed -i "s,IP_TO_REPLACE,$IP," kubecost/kubecost_ingress.yaml
kubectl apply -f  kubecost/kubecost_ingress.yaml -n kubecost
sed -i "s,ALERT_MANAGER_TOREPLACE,$ALERT_MANAGER_SVC," kubecost/kubecost_cm.yaml
sed -i "s,PROMETHEUS_SVC_TOREPALCE,$PROMETHEUS_SERVER," kubecost/kubecost_cm.yaml
sed -i "s,GRAFANA_SERICE_TOREPLACE,$GRAFANA_SERVICE," kubecost/kubecost_nginx_cm.yaml
kubectl apply -n kubecost -f kubecost/kubecost_cm.yaml
kubectl apply -n kubecost -f kubecost/kubecost_nginx_cm.yaml
kubectl delete pod -n kubecost -l app=cost-analyzer

# update the grafana datasource
echo "adding the various datasource in Grafana"
sed -i "s,PROMEHTEUS_TO_REPLACE,$PROMETHEUS_SERVER," grafana/prometheus-datasource.yaml
sed -i "s,LOKI_TO_REPLACE,$LOKI_SERVICE," grafana/prometheus-datasource.yaml
sed -i "s,TEMPO_TO_REPLACE,$TEMPO_SERICE_NAME," grafana/prometheus-datasource.yaml
kubectl apply -f  grafana/prometheus-datasource.yaml

#Deploy the OpenTelemetry Collector
echo "Deploying Otel Collector"
kubectl apply -f kubernetes-manifests/rbac.yaml
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml
kubectl apply -f prometheus/ServiceMonitor.yaml

#Deploy demo Application
echo "Deploying Otel-demo"
kubectl create ns otel-demo
kubectl annotate ns otel-demo chaos-mesh.org/inject=enabled
kubectl apply -f kubernetes-manifests/openTelemetry-sidecar.yaml -n otel-demo
kubectl apply -f kubernetes-manifests/k8sdemo.yaml -n otel-demo

#Deploy ChaosMesh
helm repo add chaos-mesh https://charts.chaos-mesh.org
kubectl create ns chaos-testing
helm install chaos-mesh chaos-mesh/chaos-mesh -n=chaos-testing --version 2.3.1 --set chaosDaemon.hostNetwork=true --set chaosDaemon.runtime=containerd --set controllerManager.enableFilterNamespace=true  --set dashboard.ingress.enabled=true --set dashboard.ingress.hosts[0].name="chaos.$IP.nip.io" --set dashboard.create=true --set dashboard.ingress.ingressClassName=nginx --set chaosDaemon.socketPath=/run/containerd/containerd.sock
kubectl wait pod -l app.kubernetes.io/component=chaos-daemon -n chaos-testing --for=condition=Ready --timeout=2m
kubectl apply -f chaos-mesh/rbac_viewer.yaml -n otel-demo
# Creating the manager TOken in case ....TODO to delete this line
kubectl apply -f chaos-mesh/rbac_manager.yaml -n otel-demo
# Get the Token of the viewer profile
VIEWER_SECRET_NAME=$(kubectl get secrets -n hipster-shop -o=jsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="account-otel-demo-viewer")].metadata.name}')
VIEWER_SECRET_TOKEN=$(kubectl get secrets $VIEWER_SECRET_NAME -n hipster-shop -o  jsonpath="{.data.token}")
echo "Deploy Chaos Experiments"
kubectl apply -f chaos-mesh/podcpu-stress.yaml
kubectl apply -f chaos-mesh/podfailure.yaml
kubectl apply -f chaos-mesh/podlantency.yaml
kubectl apply -f chaos-mesh/podmemorystress.yaml
# Echo environ*
echo "==============Grafana============================="
echo "Environment fully deployed "
echo "Grafana url : http://grafana.$IP.nip.io"
echo "Grafana User: $USER_GRAFANA"
echo "Grafana Password: $PASSWORD_GRAFANA"
echo "--------------Demo--------------------"
echo "url of the demo: "
echo "Otel demo url: http://demo.$IP.nip.io"
echo "Locust: http://locust.$IP.nip.io"
echo "FeatureFlag : http://featureflag.$IP.nip.io"
echo "-------------ChasMesh---------------------"
echo "ChaosMesh url: http://chaos.$IP.nip.io"
echo "ChaosMesh sa name :account-otel-demo-viewer "
echo "ChoasMesh namespace: otel-demo"
echo "ChasMesh viewer token : $VIEWER_SECRET_TOKEN "
echo "========================================================"

if [ $K3d_mode -eq 1 ]
then
  kubectl wait pod  -l app.kubernetes.io/name=grafana --for=condition=Ready --timeout=2m
  echo "Grafana k3D is accessible at http://localhost"
  kubectl port-forward svc/$GRAFANA_SERVICE 80:80
fi

