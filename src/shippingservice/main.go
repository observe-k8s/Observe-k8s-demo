// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"net"
	"os"
	"time"


	"github.com/sirupsen/logrus"

	"golang.org/x/net/context"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/shippingservice/genproto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

     "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"

     "go.opentelemetry.io/otel/propagation"
     "go.opentelemetry.io/otel/sdk/resource"

     "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
     sdktrace "go.opentelemetry.io/otel/sdk/trace"
     semconv  "go.opentelemetry.io/otel/semconv/v1.7.0"
)

const (
	defaultPort = "50051"
)
var tracer = otel.Tracer("shippingservicei")
var log *logrus.Logger

func init() {
	log = logrus.New()
	log.Level = logrus.DebugLevel
	log.Formatter = &logrus.JSONFormatter{
		FieldMap: logrus.FieldMap{
			logrus.FieldKeyTime:  "timestamp",
			logrus.FieldKeyLevel: "severity",
			logrus.FieldKeyMsg:   "message",
		},
		TimestampFormat: time.RFC3339Nano,
	}
	log.Out = os.Stdout
}
func  initProvider()  {
	ctx := context.Background()

    	res, err := resource.New(ctx,
    		resource.WithAttributes(
    			// the service name used to display traces in backends
    			semconv.ServiceNameKey.String("Shipping-service"),
    		),
    	)

    	handleErr(err, "failed to create resource")

    	// If the OpenTelemetry Collector is running on a local cluster (minikube or
    	// microk8s), it should be accessible through the NodePort service at the
    	// `localhost:30080` endpoint. Otherwise, replace `localhost` with the
    	// endpoint of your cluster. If you run the app inside k8s, then you can
    	// probably connect directly to the service through dns
        svcAddr := os.Getenv("OTLP_SERVICE_ADDR")
        if svcAddr == "" {
            log.Info("OpenTelemetry initialization disabled.")
            return
        }
        svcPort := os.Getenv("OTLP_SERVICE_PORT")
                if svcPort == "" {
                    log.Info("OpenTelemetry initialization disabled.")
                    return
                }
    	conn, err := grpc.DialContext(ctx, svcAddr+":"+svcPort, grpc.WithInsecure(), grpc.WithBlock())
        handleErr(err, "failed to create gRPC connection to collector")


        otlpTraceExporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
        handleErr(err, "failed to create trace exporter")

        batchSpanProcessor := sdktrace.NewBatchSpanProcessor(otlpTraceExporter)

        tracerProvider := sdktrace.NewTracerProvider(
        sdktrace.WithSampler(sdktrace.AlwaysSample()),
        sdktrace.WithSpanProcessor(batchSpanProcessor),
        sdktrace.WithResource(res),
         )

        otel.SetTracerProvider(tracerProvider)
        otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, propagation.Baggage{}))
}
func main() {

    initProvider()

	port := defaultPort
	if value, ok := os.LookupEnv("PORT"); ok {
		port = value
	}
	port = fmt.Sprintf(":%s", port)

	lis, err := net.Listen("tcp", port)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	var srv *grpc.Server
	if os.Getenv("DISABLE_STATS") == "" {
		log.Info("Stats enabled.")
		srv = grpc.NewServer(
           grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
           grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
		)
	} else {
		log.Info("Stats disabled.")
		srv = grpc.NewServer(
		   grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
           grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
		)
	}
	svc := &server{}
	pb.RegisterShippingServiceServer(srv, svc)
	healthpb.RegisterHealthServer(srv, svc)
	log.Infof("Shipping Service listening on port %s", port)

	// Register reflection service on gRPC server.
	reflection.Register(srv)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}

// server controls RPC service responses.
type server struct{}

// Check is for health checking.
func (s *server) Check(ctx context.Context, req *healthpb.HealthCheckRequest) (*healthpb.HealthCheckResponse, error) {
	return &healthpb.HealthCheckResponse{Status: healthpb.HealthCheckResponse_SERVING}, nil
}

func (s *server) Watch(req *healthpb.HealthCheckRequest, ws healthpb.Health_WatchServer) error {
	return status.Errorf(codes.Unimplemented, "health check via Watch not implemented")
}

// GetQuote produces a shipping quote (cost) in USD.
func (s *server) GetQuote(ctx context.Context, in *pb.GetQuoteRequest) (*pb.GetQuoteResponse, error) {
	log.Info("[GetQuote] received request")
	defer log.Info("[GetQuote] completed request")

	// 1. Our quote system requires the total number of items to be shipped.
	count := 0
	for _, item := range in.Items {
		count += int(item.Quantity)
	}

	// 2. Generate a quote based on the total number of items to be shipped.
	quote := CreateQuoteFromCount(count)

	// 3. Generate a response.
	return &pb.GetQuoteResponse{
		CostUsd: &pb.Money{
			CurrencyCode: "USD",
			Units:        int64(quote.Dollars),
			Nanos:        int32(quote.Cents * 10000000)},
	}, nil

}

// ShipOrder mocks that the requested items will be shipped.
// It supplies a tracking ID for notional lookup of shipment delivery status.
func (s *server) ShipOrder(ctx context.Context, in *pb.ShipOrderRequest) (*pb.ShipOrderResponse, error) {
	log.Info("[ShipOrder] received request")
	defer log.Info("[ShipOrder] completed request")
	// 1. Create a Tracking ID
	baseAddress := fmt.Sprintf("%s, %s, %s", in.Address.StreetAddress, in.Address.City, in.Address.State)
	id := CreateTrackingId(baseAddress)

	// 2. Generate a response.
	return &pb.ShipOrderResponse{
		TrackingId: id,
	}, nil
}
func handleErr(err error, message string) {
	if err != nil {
		log.Fatalf("%s: %v", message, err)
	}
}





