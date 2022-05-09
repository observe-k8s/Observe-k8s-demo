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

#if ! command -v eksctl >/dev/null 2>&1; then
#    echo "Please install eksctl before continuing"
#    exit 1
#fi

#if ! command -v aws >/dev/null 2>&1; then
#    echo "Please install aws before continuing"
#    exit 1

################################################################################
### Clone repo
git clone https://github.com/observe-k8s/Observe-k8s-demo
cd Observe-k8s-demo

###### DEploy Nginx
echo "start depploying Nginx"
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole cluster-admin \
  --user $(gcloud config get-value account)
kubectl apply -f nginx/deploy.yaml

### get the ip adress of ingress ####
IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')

### Update the ip of the ip adress for the ingres
#TODO to update this part to use the dns entry /ELB/ALB
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/k8s-manifest.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml


### Depploy Prometheus
echo "start depploying Prometheus"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack
##wait that the prometheus pod is started
kubectl wait pod -l app.kubernetes.io/name=prometheus --for=condition=Ready
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


#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready
# Deploy the opentelemetry operator
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# Deploying Tempo
echo "Deploying Tempo"
helm upgrade --install tempo grafana/tempo
#TODO add the check if svc is running
#TEMPO_SERICE_NAME=$()
#sed -i "s,TEMPO_SERIVCE_NAME,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml
sed -i "s,PROM_SERVICE_TOREPLACE,$PROMETHEUS_SERVER," kubernetes-manifests/openTelemetry-manifest.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-manifest.yaml

#Deploying the fluent operator
echo "Deploying FluentOperator"
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v1.0.0/fluent-operator.tgz

# Deploying Loki
echo "Deploying Loki"
helm upgrade --install loki loki/loki
#LOKI_SERVICE=$()
#NAMESPACE_LOKI=
#sed -i "s,LOKI_SERVICE_TOREPLACE,$LOKI_SERVICE," fluent/ClusterOutput_loki.yaml
#sed -i "s,NAMESPACE_LOKI_TOREPLACE,$NAMESPACE_LOKI," fluent/ClusterOutput_loki.yaml

# Deploy the fluent agents
kubectl apply -f fluent/ClusterOutput_loki.yaml  -n kubesphere-logging-system
kubectl apply -f fluent/ClusterOutput_loki.yaml  -n kubesphere-logging-system

# Deploy the Kubecost
kubectl apply -f grafana/ingress.yaml
PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 --decode)
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

#Deploy demo Application
echo "Deploying Hipstershop"
kubectl create ns hipster-shop
kubectl apply -f kubernetes-manifests/k8s-manifest.yaml -n hipster-shop

#Deploy the OpenTelemetry Collector
echo "Deploying Otel Collector"
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml

# Deploy Dashboard in Grafana
GRAFANA_TOKEN=$(curl -X POST -H "Content-Type: application/json" -d '{"name":"apikeycurl", "role": "Admin"}' http://$USER_GRAFANA:$PASSWORD_GRAFANA@grafana.$IP.nip.io/api/auth/keys | jq -j '.key')
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/attached-disks.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/cluster-metrics.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/cluster-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/deployment-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/label-cost-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/namespace-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/node-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/pod-utilization.json http://grafana.$IP.nip.io/api/dashboards/db
curl -X POST --insecure -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -d @./grafana/prom-benchmark.json http://grafana.$IP.nip.io/api/dashboards/db



