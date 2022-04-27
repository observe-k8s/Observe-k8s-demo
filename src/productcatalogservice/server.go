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
	"bytes"
	"context"
	"flag"
	"fmt"
	"io/ioutil"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/productcatalogservice/genproto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"


	"github.com/golang/protobuf/jsonpb"
	"github.com/sirupsen/logrus"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

    "go.opentelemetry.io/otel"
   "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"

    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"

    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv  "go.opentelemetry.io/otel/semconv/v1.7.0"



)

var (
	cat          pb.ListProductsResponse
	catalogMutex *sync.Mutex
	log          *logrus.Logger
	extraLatency time.Duration

	port = "3550"

	reloadCatalog bool
)
var tracer = otel.Tracer("productcatalogservice")
func init() {
	log = logrus.New()
	log.Formatter = &logrus.JSONFormatter{
		FieldMap: logrus.FieldMap{
			logrus.FieldKeyTime:  "timestamp",
			logrus.FieldKeyLevel: "severity",
			logrus.FieldKeyMsg:   "message",
		},
		TimestampFormat: time.RFC3339Nano,
	}
	log.Out = os.Stdout
	catalogMutex = &sync.Mutex{}
	err := readCatalogFile(&cat)
	if err != nil {
		log.Warnf("could not parse product catalog")
	}
}
func  initProvider() {
	ctx := context.Background()

    	res, err := resource.New(ctx,
    		resource.WithAttributes(
    			// the service name used to display traces in backends
    			semconv.ServiceNameKey.String("ProductCatalag-service"),
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
            //trace.WithSampler(sdktrace.AlwaysSample()), - please check TracerProvider.WithSampler() implementation for details.
        )

        otel.SetTracerProvider(tracerProvider)
        otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
            propagation.TraceContext{}, propagation.Baggage{}))


}
func main() {

    initProvider()

	flag.Parse()

	// set injected latency
	if s := os.Getenv("EXTRA_LATENCY"); s != "" {
		v, err := time.ParseDuration(s)
		if err != nil {
			log.Fatalf("failed to parse EXTRA_LATENCY (%s) as time.Duration: %+v", v, err)
		}
		extraLatency = v
		log.Infof("extra latency enabled (duration: %v)", extraLatency)
	} else {
		extraLatency = time.Duration(0)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGUSR1, syscall.SIGUSR2)
	go func() {
		for {
			sig := <-sigs
			log.Printf("Received signal: %s", sig)
			if sig == syscall.SIGUSR1 {
				reloadCatalog = true
				log.Infof("Enable catalog reloading")
			} else {
				reloadCatalog = false
				log.Infof("Disable catalog reloading")
			}
		}
	}()

	if os.Getenv("PORT") != "" {
		port = os.Getenv("PORT")
	}
	log.Infof("starting grpc server at :%s", port)
	run(port)
	select {}
}

func run(port string) string {
	l, err := net.Listen("tcp", fmt.Sprintf(":%s", port))
	if err != nil {
		log.Fatal(err)
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

	svc := &productCatalog{}

	pb.RegisterProductCatalogServiceServer(srv, svc)
	healthpb.RegisterHealthServer(srv, svc)
	go srv.Serve(l)
	return l.Addr().String()
}


type productCatalog struct{}

func readCatalogFile(catalog *pb.ListProductsResponse) error {
	catalogMutex.Lock()
	defer catalogMutex.Unlock()
	catalogJSON, err := ioutil.ReadFile("products.json")
	if err != nil {
		log.Fatalf("failed to open product catalog json file: %v", err)
		return err
	}
	if err := jsonpb.Unmarshal(bytes.NewReader(catalogJSON), catalog); err != nil {
		log.Warnf("failed to parse the catalog JSON: %v", err)
		return err
	}
	log.Info("successfully parsed product catalog json")
	return nil
}

func parseCatalog() []*pb.Product {
	if reloadCatalog || len(cat.Products) == 0 {
		err := readCatalogFile(&cat)
		if err != nil {
			return []*pb.Product{}
		}
	}
	return cat.Products
}

func (p *productCatalog) Check(ctx context.Context, req *healthpb.HealthCheckRequest) (*healthpb.HealthCheckResponse, error) {
	return &healthpb.HealthCheckResponse{Status: healthpb.HealthCheckResponse_SERVING}, nil
}

func (p *productCatalog) Watch(req *healthpb.HealthCheckRequest, ws healthpb.Health_WatchServer) error {
	return status.Errorf(codes.Unimplemented, "health check via Watch not implemented")
}

func (p *productCatalog) ListProducts(context.Context, *pb.Empty) (*pb.ListProductsResponse, error) {
	time.Sleep(extraLatency)
	return &pb.ListProductsResponse{Products: parseCatalog()}, nil
}

func (p *productCatalog) GetProduct(ctx context.Context, req *pb.GetProductRequest) (*pb.Product, error) {
	time.Sleep(extraLatency)
	var found *pb.Product
	for i := 0; i < len(parseCatalog()); i++ {
		if req.Id == parseCatalog()[i].Id {
			found = parseCatalog()[i]
		}
	}
	if found == nil {
		return nil, status.Errorf(codes.NotFound, "no product with ID %s", req.Id)
	}
	return found, nil
}

func (p *productCatalog) SearchProducts(ctx context.Context, req *pb.SearchProductsRequest) (*pb.SearchProductsResponse, error) {
	time.Sleep(extraLatency)
	// Intepret query as a substring match in name or description.
	var ps []*pb.Product
	for _, p := range parseCatalog() {
		if strings.Contains(strings.ToLower(p.Name), strings.ToLower(req.Query)) ||
			strings.Contains(strings.ToLower(p.Description), strings.ToLower(req.Query)) {
			ps = append(ps, p)
		}
	}
	return &pb.SearchProductsResponse{Results: ps}, nil
}
func handleErr(err error, message string) {
	if err != nil {
		log.Fatalf("%s: %v", message, err)
	}
}