# Kubernestes Observabilty Demo

This repository will explain how to deploy the various CNCF prouject to observe properly your Kubernetes cluster .
This repository is based on the popular Demo platform provided by Google : The Online Boutique
<p align="center">
<img src="src/frontend/static/icons/Hipster_HeroLogoCyan.svg" width="300" alt="Online Boutique" />
</p>

**Online Boutique** is a cloud-native microservices demo application.
Online Boutique consists of a 10-tier microservices application. The application is a
web-based e-commerce app where users can browse items,
add them to the cart, and purchase them.
The Google HipsterShop is a microservice architecture using several langages :
* Go 
* Python
* Nodejs
* C#
* Java

## Screenshots

| Home Page                                                                                                         | Checkout Screen                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [![Screenshot of store homepage](./docs/img/online-boutique-frontend-1.png)](./docs/img/online-boutique-frontend-1.png) | [![Screenshot of checkout screen](./docs/img/online-boutique-frontend-2.png)](./docs/img/online-boutique-frontend-2.png) |


## Prerequisite
The following tools need to be install on your machine :
- jq
- kubectl
- git
- gcloud ( if you are using GKE)
- Helm

This tutorial will generate traces and send them to Dynatrace.
Therefore you will need a Dynatrace Tenant to be able to follow all the instructions of this tutorial .
If you don't have any dynatrace tenant , then let's start a [trial on Dynatrace](https://www.dynatrace.com/trial/)

## Deployment Steps

You will first need a Kubernetes cluster with 2 Nodes.
You can either deploy on Minikube or K3s or follow the instructions to create GKE cluster:
### 1.Create a Google Cloud Platform Project
```
PROJECT_ID="<your-project-id>"
gcloud services enable container.googleapis.com --project ${PROJECT_ID}
gcloud services enable monitoring.googleapis.com \
    cloudtrace.googleapis.com \
    clouddebugger.googleapis.com \
    cloudprofiler.googleapis.com \
    --project ${PROJECT_ID}
```
### 2.Create a GKE cluster
```
ZONE=us-central1-b
gcloud container clusters create onlineboutique \
--project=${PROJECT_ID} --zone=${ZONE} \
--machine-type=e2-standard-2 --num-nodes=4
```

### 3.Clone the Github Repository
```
git clone https://github.com/isItObservable/OpenTelemetry-Instrumentation
cd OpenTelemetry-Instrumentation
```
#### 4.Deploy Nginx Ingress Controller
```
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole cluster-admin \
  --user $(gcloud config get-value account)
kubectl apply -f nginx/deploy.yaml
```
this command will install the nginx controller on the nodes having the label `observability`

##### 5. get the ip adress of the ingress gateway
Since we are using Ingress controller to route the traffic , we will need to get the public ip adress of our ingress.
With the public ip , we would be able to update the deployment of the ingress for :
* hipstershop
* grafana
* K6
```
IP=$(kubectl get svc nginx-ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
```

update the following files to update the ingress definitions :
```
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/k8s-manifest.yaml
```

#### 4.Prometheus
Our Chaos experiments will utilize the Prometheus as an Observabilty backend
We will neeed to deploy Prometheus only on the nodes having the label `observability`.
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack --set server.nodeSelector.node-type=observability --set prometheusOperator.nodeSelector.selector.node-type=observability  --set prometheus.nodeSelector.selector.node-type=observability --set grafana.nodeSelector.selector.node-type=observability  
```
### 5. Configure Prometheus by enabling the feature remo-writer

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
### 4. Deploy the Opentelemetry Operator

#### Deploy the cert-manager
```
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
```
#### Wait for the service to be ready
```
kubectl get svc -n cert-manager
```
After a few minutes, you should see:
```
NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
cert-manager           ClusterIP   10.99.253.6     <none>        9402/TCP   42h
cert-manager-webhook   ClusterIP   10.99.253.123   <none>        443/TCP    42h
```

#### Deploy the OpenTelemetry Operator
```
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

### 6. Configure the OpenTelemetry Collector

#### Deploy Grafana Tempo
```
helm upgrade --install tempo grafana/tempo
```

#### Udpate the openTelemetry manifest file
```
TEMPO_SERICE_NAME=$()
sed -i "s,TEMPO_SERIVCE_NAME,$TEMPO_SERICE_NAME," kubernetes-manifests/openTelemetry-manifest.yaml
```
#### Deploy the OpenTelemetry Collector
```
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml
```

### 5. Deploy the sample app to the cluster.

#### Deploy
```
kubectl create ns hipster-shop
kubectl apply -f kubernetes-manifests/k8s-manifest.yaml -n hipster-shop
```
#### Wait for the Pods to be ready

```
kubectl get pods
```
After a few minutes, you should see:
```
NAME                                     READY   STATUS    RESTARTS   AGE
adservice-668484d797-jxqsg               1/1     Running   0          23d
cartservice-754d9f69b6-k5tlk             1/1     Running   0          23d
checkoutservice-56b96d95c-7k66b          1/1     Running   0          23d
currencyservice-c4bd899cd-zvwnx          1/1     Running   0          23d
emailservice-79bdf579f6-wvx4c            1/1     Running   0          22d
frontend-5694965584-gfkrk                1/1     Running   0          22d
k6loadgenerator-69d9579f98-w5g66         1/1     Running   1          24h
loadgenerator-546597c764-qs8ts           1/1     Running   22         22d
paymentservice-6fc857fd48-zfmfr          1/1     Running   0          22d
productcatalogservice-6b488c9d57-lwflb   1/1     Running   0          22d
recommendationservice-78fbf687c7-m68v9   1/1     Running   0          22d
redis-cart-79b499b7dd-wrlgf              1/1     Running   0          23d
shippingservice-7986c676f5-krnhv         1/1     Running   0          23d
```
#### Access the web frontend in a browser** using the frontend's `EXTERNAL_IP`.

with http://onlineboutique.<YOUR INGRESS IP>.nip.io

### 6. Deploy Fluent Operator & Loki

#### Deploy Fluent Operator
```
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v1.0.0/fluent-operator.tgz
```
#### Deploy Loki
```
helm upgrade --install loki loki/loki
```

#### Deploy Logs stream pipeline
```
kubectl apply -f fluent/fluentbit_deployment.yaml  -n kubesphere-logging-system
```
#### Update the fluentbit forward to send the logs to Loki
```
LOKI_SERVICE=$()
NAMESPACE_LOKI=
sed -i "s,LOKI_SERVICE_TOREPLACE,$LOKI_SERVICE," fluent/ClusterOutput_loki.yaml
sed -i "s,NAMESPACE_LOKI_TOREPLACE,$NAMESPACE_LOKI," fluent/ClusterOutput_loki.yaml
```

#### Deploy the output plugin
```
kubectl apply -f fluent/fluentbit_deployment.yaml  -n kubesphere-logging-system

```

### 7 [Optional] **Clean up**: TODO
```
gcloud container clusters delete onlineboutique \
    --project=${PROJECT_ID} --zone=${ZONE}
```

## Architecture

**Online Boutique** is composed of 11 microservices written in different
languages that talk to each other over gRPC. See the [Development Principles](/docs/development-principles.md) doc for more information.

[![Architecture of
microservices](./docs/img/architecture-diagram.png)](./docs/img/architecture-diagram.png)

Find **Protocol Buffers Descriptions** at the [`./pb` directory](./pb).

| Service                                              | Language      | Description                                                                                                                       |
| ---------------------------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| [frontend](./src/frontend)                           | Go            | Exposes an HTTP server to serve the website. Does not require signup/login and generates session IDs for all users automatically. |
| [cartservice](./src/cartservice)                     | C#            | Stores the items in the user's shopping cart in Redis and retrieves it.                                                           |
| [productcatalogservice](./src/productcatalogservice) | Go            | Provides the list of products from a JSON file and ability to search products and get individual products.                        |
| [currencyservice](./src/currencyservice)             | Node.js       | Converts one money amount to another currency. Uses real values fetched from European Central Bank. It's the highest QPS service. |
| [paymentservice](./src/paymentservice)               | Node.js       | Charges the given credit card info (mock) with the given amount and returns a transaction ID.                                     |
| [shippingservice](./src/shippingservice)             | Go            | Gives shipping cost estimates based on the shopping cart. Ships items to the given address (mock)                                 |
| [emailservice](./src/emailservice)                   | Python        | Sends users an order confirmation email (mock).                                                                                   |
| [checkoutservice](./src/checkoutservice)             | Go            | Retrieves user cart, prepares order and orchestrates the payment, shipping and the email notification.                            |
| [recommendationservice](./src/recommendationservice) | Python        | Recommends other products based on what's given in the cart.                                                                      |
| [adservice](./src/adservice)                         | Java          | Provides text ads based on given context words.                                                                                   |
| [loadgenerator](./src/loadgenerator)                 | JS    /K6     | Continuously sends requests imitating realistic user shopping flows to the frontend.                                              |




