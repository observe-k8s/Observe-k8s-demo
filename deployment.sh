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
#########################################################################################################
while [ $# -gt 0 ]; do
  case "$1" in
  --gitclone)
    GITCLONE="$2"
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

#if ! command -v eksctl >/dev/null 2>&1; then
#    echo "Please install eksctl before continuing"
#    exit 1
#fi

#if ! command -v aws >/dev/null 2>&1; then
#    echo "Please install aws before continuing"
#    exit 1

################################################################################
### Clone repo
if [ $GITCLONE -eq 1];
then
  git clone https://github.com/observe-k8s/Observe-k8s-demo
  cd Observe-k8s-demo
  K3d_mode=0
  #TODO add the provisionning of the cluster here

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
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/k8s-manifest.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml


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
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# Deploying Tempo
echo "Deploying Tempo"
kubectl create ns tempo
helm upgrade --install tempo grafana/tempo --namespace tempo
kubectl wait pod -l app.kubernetes.io/instance=tempo -n tempo --for=condition=Ready --timeout=2m
TEMPO_SERICE_NAME=$(kubectl  get svc -l app.kubernetes.io/instance=tempo -n tempo -o jsonpath="{.items[0].metadata.name}")
sed -i "s,TEMPO_SERIVCE_NAME,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml
sed -i "s,PROM_SERVICE_TOREPLACE,$PROMETHEUS_SERVER," kubernetes-manifests/openTelemetry-manifest.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-manifest.yaml

#Deploying the fluent operator
echo "Deploying FluentOperator"
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v1.0.0/fluent-operator.tgz

# Deploying Loki
echo "Deploying Loki"
kubectl create ns loki
helm upgrade --install loki grafana/loki --namespace loki
kubectl wait pod -n loki -l  app=loki --for=condition=Ready --timeout=2m
LOKI_SERVICE=$(kubectl  get svc -l app=loki  -n loki -o jsonpath="{.items[0].metadata.name}")
sed -i "s,LOKI_SERVICE_TOREPLACE,$LOKI_SERVICE," fluent/ClusterOutput_loki.yaml


# Deploy the fluent agents
kubectl apply -f fluentbit_deployment.yaml  -n kubesphere-logging-system
kubectl apply -f fluent/ClusterOutput_loki.yaml  -n kubesphere-logging-system

# Deploy the Kubecost
kubectl apply -f grafana/ingress.yaml
if [ $K3d_mode -eq 1 ]
then
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


#Deploy demo Application
echo "Deploying Hipstershop"
kubectl create ns hipster-shop
kubectl apply -f kubernetes-manifests/k8s-manifest.yaml -n hipster-shop

#Deploy the OpenTelemetry Collector
echo "Deploying Otel Collector"
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml


# Echo environ*
echo "========================================================"
echo "Environment fully deployed "
echo "Grafana url : http://grafana.$IP.nip.io"
echo "Grafana User: $USER_GRAFANA"
echo "Grafana Password: $PASSWORD_GRAFANA"
echo "Kubecost url: kubecost.$IP.nip.io"
echo "Online Boutique url: http://demo.$IP.nip.io"
echo "========================================================"
if [ $K3d_mode -eq 1 ]
then
  kubectl wait pod  -l app.kubernetes.io/name=grafana --for=condition=Ready --timeout=2m
  echo "Grafana k3D is accessible at http://localhost"
  kubectl port-forward svc/$GRAFANA_SERVICE 80:80
fi

