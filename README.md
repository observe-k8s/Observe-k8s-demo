# Kubernestes Observability Demo

Here we show you how to set up the Kubernestes Observability Demo in
Amazon EKS.

## Prerequisites

The following tools need to be installed on your local machine:

* `jq`
* `kubectl`
* `eksctl`
* `git`
* `aws`
* `helm`

## Deployment Steps in EKS

You will first need an EKS cluster, so let's create one with the provided
configuration file [`eks-cluster.yaml`](./eks-cluster.yaml):

```
eksctl create cluster -f eks-cluster.yaml
```

Note that the cluster config provided has the region fixed to `eu-west-1`.
If you want to deploy the EKS cluster in another region you will have to 
change this (as well as everywhere below where the region is required).

Next, clone the Github repository:

```
git clone https://github.com/observe-k8s/Observe-k8s-demo
cd Observe-k8s-demo
```

### 1. Deploy Ingress Controller

We're using the
[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/deploy/installation/)
to manage ingress resources that we use in the demo to make our frontends
such as Grafana publicly accessible.

The OIDC provider is already configured (via `eks-cluster.yaml`), so first we
get the IAM policy for the AWS Load Balancer Controller in place:

```
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.1/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json
```

Now take note of the policy ARN that is returned from the previous command
and use this as an input to create an IAM role along with a Kubernestes service
account for the AWS Load Balancer controller:

```
eksctl create iamserviceaccount \
--cluster=observe-k8s-wg \
--namespace=kube-system \
--name=aws-load-balancer-controller \
--attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
--override-existing-serviceaccounts \
--region eu-west-1 \
--approve
```

Since we are using an ingress controller to route the traffic, we need to
get the public IP adress of our ingress. With the public IP, we then are in
the position to update the deployment of the ingress for:

* Hipstershop
* Grafana
* K6

First, query the public IP like so:

```
IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
```

update the following files to update the ingress definitions :
```
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/k8s-manifest.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml
```

### 2. Deploy Prometheus

Install Prometheus via Helm:

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack --set sidecar.datasources.enabled=true --set sidecar.datasources.label=grafana_datasource --set sidecar.datasources.labelValue="1" --set sidecar.dashboards.enabled=true
```

Configure Prometheus by enabling `remote-writer`:

To measure the impact of our experiments on use traffic , we will use the load testing tool named K6.
K6 has a Prometheus integration that writes metrics to the Prometheus Server.
This integration requires to enable a feature in Prometheus named: remote-writer

To enable this feature we will need to edit the CRD containing all the settings of promethes: prometehus

To get the Prometheus object named use by prometheus we need to run the following command:

```
kubectl get Prometheus
```

here is the expected output:

```
NAME                                    VERSION   REPLICAS   AGE
prometheus-kube-prometheus-prometheus   v2.32.1   1          22h
```

We will need to add an extra property in the configuration object :
```
enableFeatures:
- remote-write-receiver
```

so to update the object :

```
kubectl edit Prometheus prometheus-kube-prometheus-prometheus
```

After the update your Prometheus object should look  like :
```
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  annotations:
    meta.helm.sh/release-name: prometheus
    meta.helm.sh/release-namespace: default
  generation: 2
  labels:
    app: kube-prometheus-stack-prometheus
    app.kubernetes.io/instance: prometheus
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: kube-prometheus-stack
    app.kubernetes.io/version: 30.0.1
    chart: kube-prometheus-stack-30.0.1
    heritage: Helm
    release: prometheus
  name: prometheus-kube-prometheus-prometheus
  namespace: default
spec:
  alerting:
  alertmanagers:
  - apiVersion: v2
    name: prometheus-kube-prometheus-alertmanager
    namespace: default
    pathPrefix: /
    port: http-web
  enableAdminAPI: false
  enableFeatures:
  - remote-write-receiver
  externalUrl: http://prometheus-kube-prometheus-prometheus.default:9090
  image: quay.io/prometheus/prometheus:v2.32.1
  listenLocal: false
  logFormat: logfmt
  logLevel: info
  paused: false
  podMonitorNamespaceSelector: {}
  podMonitorSelector:
  matchLabels:
  release: prometheus
  portName: http-web
  probeNamespaceSelector: {}
  probeSelector:
  matchLabels:
  release: prometheus
  replicas: 1
  retention: 10d
  routePrefix: /
  ruleNamespaceSelector: {}
  ruleSelector:
  matchLabels:
  release: prometheus
  securityContext:
  fsGroup: 2000
  runAsGroup: 2000
  runAsNonRoot: true
  runAsUser: 1000
  serviceAccountName: prometheus-kube-prometheus-prometheus
  serviceMonitorNamespaceSelector: {}
  serviceMonitorSelector:
  matchLabels:
  release: prometheus
  shards: 1
  version: v2.32.1
```

Deploy Prometheus rules:

```
kubectl apply -f prometheus/PrometheusRule.yaml
kubectl create secret generic addtional-scrape-configs --from-file=prometheus/additionnalscrapeconfig.yaml
kubectl apply -f prometheus/Prometheus.yaml
```

Get the Prometheus service:

```
PROMETHEUS_SERVER=$(kubectl get svc -l app=kube-prometheus-stack-prometheus -o jsonpath="{.items[0].metadata.name}")
GRAFANA_SERVICE=$(kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")
ALERT_MANAGER_SVC=$(kubectl get svc -l app=kube-prometheus-stack-alertmanager -o jsonpath="{.items[0].metadata.name}")
```

### 3. Deploy the Opentelemetry Operator

Deploy the cert-manager:

```
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
```

Wait for the service to be ready:
```
kubectl get svc -n cert-manager
```

After a few minutes, you should see:
```
NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
cert-manager           ClusterIP   10.99.253.6     <none>        9402/TCP   42h
cert-manager-webhook   ClusterIP   10.99.253.123   <none>        443/TCP    42h
```

Deploy the OpenTelemetry Operator:

```
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

Deploy Grafana Tempo:

```
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install tempo grafana/tempo
```

Update the openTelemetry manifest file:
```
TEMPO_SERICE_NAME=$(kubectl  get svc -l app.kubernetes.io/instance=tempo -n tempo -o jsonpath="{.items[0].metadata.name}")
sed -i "s,TEMPO_SERIVCE_NAME,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml
sed -i "s,PROM_SERVICE_TOREPLACE,$PROMETHEUS_SERVER," kubernetes-manifests/openTelemetry-manifest.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-manifest.yaml
```

### 4. Deploy the FluentOperator

```
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v1.0.0/fluent-operator.tgz
```

Deploy Loki:

```
kubectl create ns loki
helm upgrade --install loki grafana/loki --namespace loki
kubectl wait pod -n loki -l  app=loki --for=condition=Ready --timeout=2m
LOKI_SERVICE=$(kubectl  get svc -l app=loki  -n loki -o jsonpath="{.items[0].metadata.name}")
sed -i "s,LOKI_SERVICE_TOREPLACE,$LOKI_SERVICE," fluent/ClusterOutput_loki.yaml
```

Deploy the Fluent Bit pipeline:

```
kubectl apply -f fluentbit_deployment.yaml  -n kubesphere-logging-system
kubectl apply -f fluent/ClusterOutput_loki.yaml  -n kubesphere-logging-system
```

### 5. Deploy Kubecost

Install via Helm:

```
kubectl create namespace kubecost
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer --namespace kubecost --set kubecostToken="aGVucmlrLnJleGVkQGR5bmF0cmFjZS5jb20=xm343yadf98" --set prometheus.kube-state-metrics.disabled=true --set prometheus.nodeExporter.enabled=false --set ingress.enabled=true --set ingress.hosts[0]="kubecost.$IP.nip.io" --set global.grafana.enabled=false --set global.grafana.fqdn="http://$GRAFANA_SERVICE.default.svc" --set prometheusRule.enabled=true --set global.prometheus.fqdn="http://$PROMETHEUS_SERVER.default.svc:9090" --set global.prometheus.enabled=false --set serviceMonitor.enabled=true
```

Configure Kubecost:

```
sed -i "s,IP_TO_REPLACE,$IP," kubecost/kubecost_ingress.yaml
kubectl apply -f  kubecost/kubecost_ingress.yaml -n kubecost
sed -i "s,ALERT_MANAGER_TOREPLACE,$ALERT_MANAGER_SVC," kubecost/kubecost_cm.yaml
sed -i "s,PROMETHEUS_SVC_TOREPALCE,$PROMETHEUS_SERVER," kubecost/kubecost_cm.yaml
sed -i "s,GRAFANA_SERICE_TOREPLACE,$GRAFANA_SERVICE," kubecost/kubecost_nginx_cm.yaml
kubectl apply -n kubecost -f kubecost/kubecost_cm.yaml
kubectl apply -n kubecost -f kubecost/kubecost_nginx_cm.yaml
kubectl delete pod -n kubecost -l app=cost-analyzer
```
### 6. Update Grafana Datasource

```
echo "adding the various datasource in Grafana"
sed -i "s,PROMEHTEUS_TO_REPLACE,$PROMETHEUS_SERVER," grafana/prometheus-datasource.yaml
sed -i "s,LOKI_TO_REPLACE,$LOKI_SERVICE," grafana/prometheus-datasource.yaml
sed -i "s,TEMPO_TO_REPLACE,$TEMPO_SERICE_NAME," grafana/prometheus-datasource.yaml
kubectl apply -f  grafana/prometheus-datasource.yaml
```
### 7. Deploy OnlineBoutique

```
kubectl create ns hipster-shop
kubectl apply -f kubernetes-manifests/k8s-manifest.yaml -n hipster-shop
```

### 8. Deploy the OpenTelemetry Collector
```
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml
```


