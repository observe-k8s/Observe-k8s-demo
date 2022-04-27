module github.com/GoogleCloudPlatform/microservices-demo/src/frontend

go 1.16

require (

		github.com/golang/protobuf v1.4.2
		github.com/google/pprof v0.0.0-20200229191704-1ebb73c60ed3
		github.com/google/uuid v1.1.1
		github.com/gorilla/mux v1.7.3
		github.com/konsorten/go-windows-terminal-sequences v1.0.2
		github.com/pkg/errors v0.8.1
		github.com/sirupsen/logrus v1.4.2
		go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.27.0
		go.opentelemetry.io/otel v1.3.0
		go.opentelemetry.io/otel/exporters/stdout v0.20.0
		go.opentelemetry.io/otel/sdk v1.3.0
		google.golang.org/grpc v1.31.0
		go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.3.0
		go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.28.0
		go.opentelemetry.io/contrib/instrumentation/github.com/gorilla/mux/otelmux v0.27.0
)
