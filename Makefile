IMAGE_NAME=hrexed/observk8s
IMAGE_VERSION=0.1
DEMO_NAME=observk8s

.PHONY: build
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_VERSION) .

.PHONY: run
run:
	docker run --rm -it --name=$(DEMO_NAME) -v /var/run/docker.sock:/var/run/docker.sock:ro --add-host=host.docker.internal:host-gateway $(IMAGE_NAME):$(IMAGE_VERSION)

