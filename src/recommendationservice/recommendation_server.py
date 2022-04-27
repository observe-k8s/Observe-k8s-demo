#!/usr/bin/python
#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import random
import time
import traceback
from concurrent import futures

import googleclouddebugger
import googlecloudprofiler
from google.auth.exceptions import DefaultCredentialsError
import grpc


import demo_pb2
import demo_pb2_grpc
from grpc_health.v1 import health_pb2
from grpc_health.v1 import health_pb2_grpc

from logger import getJSONLogger
from opentelemetry import trace
from opentelemetry.instrumentation.grpc import server_interceptor
from opentelemetry.sdk.trace import Span,TracerProvider
from opentelemetry.sdk.resources import  Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.export import  SpanExporter, SpanExportResult


from opentelemetry.exporter.otlp.proto.grpc._log_exporter import (
    OTLPLogExporter,
)
from opentelemetry.sdk._logs import (
    LogEmitterProvider,
    LoggingHandler,
    set_log_emitter_provider,
)
from opentelemetry.sdk._logs.export import BatchLogProcessor

otlp_host = os.environ.get('OTLP_HOST')
otlp_port = os.environ.get('OTLP_PORT')
# create a CollectorSpanExporter
collector_exporter = OTLPSpanExporter(
     endpoint="http://"+otlp_host+":"+otlp_port,
      insecure=True
    # host_name="machine/container name",
)
resource=Resource.create({"service.name": "recommandationserivce-server"})
# Create a BatchExportSpanProcessor and add the exporter to it
# Create a BatchExportSpanProcessor and add the exporter to it
span_processor = BatchSpanProcessor(collector_exporter)
# Configure the tracer to use the collector exporter
trace.set_tracer_provider(TracerProvider(resource=resource))
trace.get_tracer_provider().add_span_processor(span_processor)
tracer = trace.get_tracer(__name__)


log_emitter_provider = LogEmitterProvider(
    resource=Resource.create(
        {
            "service.name": "recommandationserivce-server",
        }
    ),
)
exporter = OTLPLogExporter(endpoint="http://"+otlp_host+":"+otlp_port,insecure=True)
log_emitter_provider.add_log_processor(BatchLogProcessor(exporter))
log_emitter = log_emitter_provider.get_log_emitter(__name__, "0.1")
handler = LoggingHandler(level=logging.NOTSET, log_emitter=log_emitter)
# Attach OTLP handler to root logger
logging.getLogger().addHandler(handler)
logger1 = logging.getLogger("recommandationserivce.server")

set_log_emitter_provider(log_emitter_provider)
class RecommendationService(demo_pb2_grpc.RecommendationServiceServicer):
    def ListRecommendations(self, request, context):
        with tracer.start_as_current_span("ListRecommendations"):
            max_responses = 5
            # fetch list of products from product catalog stub
            cat_response = product_catalog_stub.ListProducts(demo_pb2.Empty())
            product_ids = [x.id for x in cat_response.products]
            filtered_products = list(set(product_ids)-set(request.product_ids))
            num_products = len(filtered_products)
            num_return = min(max_responses, num_products)
            # sample list of indicies to return
            indices = random.sample(range(num_products), num_return)
            # fetch product ids from indices
            prod_list = [filtered_products[i] for i in indices]
            logger1.info("[Recv ListRecommendations] product_ids={}".format(prod_list))
            # build and return response
            response = demo_pb2.ListRecommendationsResponse()
            response.product_ids.extend(prod_list)
        return response

    def Check(self, request, context):
        return health_pb2.HealthCheckResponse(
            status=health_pb2.HealthCheckResponse.SERVING)

    def Watch(self, request, context):
        return health_pb2.HealthCheckResponse(
            status=health_pb2.HealthCheckResponse.UNIMPLEMENTED)


if __name__ == "__main__":
    with tracer.start_as_current_span("recommendationserver start"):
        logger1.info("initializing recommendationservice")



        port = os.environ.get('PORT', "8080")
        catalog_addr = os.environ.get('PRODUCT_CATALOG_SERVICE_ADDR', '')
        if catalog_addr == "":
            raise Exception('PRODUCT_CATALOG_SERVICE_ADDR environment variable not set')
        logger1.info("product catalog address: " + catalog_addr)
        channel = grpc.insecure_channel(catalog_addr)
        product_catalog_stub = demo_pb2_grpc.ProductCatalogServiceStub(channel)

        # create gRPC server
        server = grpc.server(futures.ThreadPoolExecutor(max_workers=10),interceptors = [server_interceptor()])

        # add class to gRPC server
        service = RecommendationService()
        demo_pb2_grpc.add_RecommendationServiceServicer_to_server(service, server)
        health_pb2_grpc.add_HealthServicer_to_server(service, server)

        # start server
        logger1.info("listening on port: " + port)
        server.add_insecure_port('[::]:'+port)
        server.start()

    # keep alive
    try:
         while True:
            time.sleep(10000)
    except KeyboardInterrupt:
            server.stop(0)
