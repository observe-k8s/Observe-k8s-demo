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

Next, clone the Git repo that contains the demo app:

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
curl https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.1/docs/install/iam_policy.json \
     -o iam-policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json
```

Next, create an IAM role along with a Kubernestes service account for the 
AWS Load Balancer controller by replacing `$AWS_ACCOUNT_ID` in the following
command with your own AWS account ID (and replace `region`, if necessary):

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

Now we can install the AWS Load Balancer Controller using Helm like so:

```
helm repo add eks https://aws.github.io/eks-charts

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=observe-k8s-wg \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller
```

To verify if the controller was installed properly and is up and running you 
can use `kubectl -n kube-system get all` and you would expect the respective
pods and the service to show up there.

### 2. Deploy Prometheus

Install the Prometheus stack via Helm:

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
     --set sidecar.datasources.enabled=true \
     --set sidecar.datasources.label=grafana_datasource \
     --set sidecar.datasources.labelValue="1" \
     --set sidecar.dashboards.enabled=true \
     --set grafana.grafana\.ini.auth.anonymous.enabled=true \
     --set grafana.grafana\.ini.auth\.anonymous.org_role=Viewer 
```

To measure the impact of our experiments on the traffic, we use the load testing
tool named K6, which has a Prometheus integration that writes metrics to the 
Prometheus server. This integration requires us to enable the `remote-write`
feature in Prometheus. For this to happen we next need to edit the Prometheus CRD 
containing the respective settings.

To get the Prometheus CRD, do:

```
$ kubectl get Prometheus
NAME                                    VERSION   REPLICAS   AGE
prometheus-kube-prometheus-prometheus   v2.35.0   1          2m51s
```

So, to update the Prometheus CRD, execute the following (which will open up
the CRD in your editor):

```
kubectl edit Prometheus prometheus-kube-prometheus-prometheus
```

Now add an extra property to the Prometheus CRD under the `spec` key as follows:

```
...
spec:
  ...
  enableFeatures:
  - remote-write-receiver
  ...
```

After you've saved the file and exited your editor you should see the following
confirmation:

```
prometheus.monitoring.coreos.com/prometheus-kube-prometheus-prometheus edited
```

Now you can deploy the Prometheus rules:

```
kubectl apply -f prometheus/PrometheusRule.yaml

kubectl create secret generic addtional-scrape-configs \
        --from-file=prometheus/additionnalscrapeconfig.yaml

kubectl apply -f prometheus/Prometheus.yaml
```

Finally, capture the Prometheus services as follows (assuming you're using
Bash):

```
PROMETHEUS_SERVER=$(kubectl get svc -l app=kube-prometheus-stack-prometheus -o jsonpath="{.items[0].metadata.name}")

GRAFANA_SERVICE=$(kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")

ALERT_MANAGER_SVC=$(kubectl get svc -l app=kube-prometheus-stack-alertmanager -o jsonpath="{.items[0].metadata.name}")
```

### 3. Deploy the Opentelemetry Operator

For the OpenTelemetry operator to work, we first need to deploy the cert-manager:

```
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
```

Wait for the cert-manager to be ready using `kubectl -n cert-manager get all`
to check the state.

Now we can deploy the OpenTelemetry operator:

```
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

Deploy Grafana Tempo for distributed tracing:

```
helm repo add grafana https://grafana.github.io/helm-charts

helm repo update

kubectl create ns tempo

helm upgrade --install --namespace tempo tempo grafana/tempo
```

And now update the OpenTelemetry manifest file like so (again, assuming Bash):

```
TEMPO_SERICE_NAME=$(kubectl  get svc -l app.kubernetes.io/instance=tempo -n tempo -o jsonpath="{.items[0].metadata.name}")

sed -i "s,TEMPO_SERIVCE_NAME,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml

sed -i "s,PROM_SERVICE_TOREPLACE,$PROMETHEUS_SERVER," kubernetes-manifests/openTelemetry-manifest.yaml

CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')

sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-manifest.yaml
```

### 4. Deploy the FluentOperator

Deploy the FluentOperator using:

```
kubectl create ns fluent

kubectl apply -f https://raw.githubusercontent.com/fluent/fluent-operator/release-1.0/manifests/setup/setup.yaml
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
kubectl -n fluent apply -f fluent/fluentbit_deployment.yaml
kubectl -n fluent apply -f fluent/ClusterOutput_loki.yaml
```

### 5. Deploy Kubecost

Install via Helm:

```
kubectl create namespace kubecost

helm repo add kubecost https://kubecost.github.io/cost-analyzer/

helm install kubecost kubecost/cost-analyzer \
     --namespace kubecost \
     --set kubecostToken="aGVucmlrLnJleGVkQGR5bmF0cmFjZS5jb20=xm343yadf98" \
     --set prometheus.kube-state-metrics.disabled=true \
     --set prometheus.nodeExporter.enabled=false \
     --set ingress.enabled=true \
     --set ingress.hosts[0]="kubecost.2022-05-cncf-tag-o11y.nip.io" \
     --set global.grafana.enabled=false \
     --set global.grafana.fqdn="http://prometheus-grafana.default.svc" \
     --set prometheusRule.enabled=true \
     --set global.prometheus.fqdn="http://prometheus-kube-prometheus-prometheus.default.svc:9090" \
     --set global.prometheus.enabled=false \
     --set serviceMonitor.enabled=true
```

Configure Kubecost:

```
kubectl -n kubecost apply -f  kubecost/kubecost_ingress.yaml

kubectl -n kubecost apply -f kubecost/kubecost_cm.yaml

kubectl -n kubecost apply -f kubecost/kubecost_nginx_cm.yaml

kubectl -n kubecost delete pod -l app=cost-analyzer
```
### 6. Update Grafana Datasource

```
kubectl apply -f  grafana/prometheus-datasource.yaml
```

### 7. Deploy OnlineBoutique

```
kubectl create ns hipster-shop

kubectl -n hipster-shop apply -f kubernetes-manifests/k8s-manifest.yaml
```

### 8. Deploy the OpenTelemetry Collector

```
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml
```

