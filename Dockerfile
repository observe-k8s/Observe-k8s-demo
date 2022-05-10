FROM rancher/k3d:5.3.0-dind


# Install Helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh

# Install Keptn CLI
WORKDIR /root
COPY k3dconfig.yaml .
COPY deployment.sh .
ADD prometheus/ ./prometheus
ADD kubernetes-manifests/ ./kubernetes-manifests
ADD kubecost/ ./kubecost
ADD grafana/ ./grafana
ADD fluent/ ./fluent


ENV PATH="${PATH}:/root"

ENTRYPOINT ["/bin/bash", "./deployment.sh", "--gitclone=false"]
