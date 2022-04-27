module main

go 1.16

require (
	github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice v0.0.0-20211229172002-2e796c9dbb43
	github.com/golang/protobuf v1.5.2
	github.com/google/uuid v1.1.2
	github.com/sirupsen/logrus v1.8.1
	go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.31.0
	go.opentelemetry.io/otel v1.6.1
	go.opentelemetry.io/otel/metric v0.28.0
	go.opentelemetry.io/otel/sdk/metric v0.28.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.6.1
	go.opentelemetry.io/otel/sdk v1.6.1
	golang.org/x/net v0.0.0-20210503060351-7fd8e65b6420
	google.golang.org/grpc v1.42.0
)
