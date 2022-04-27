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

import sys
import grpc
import demo_pb2
import demo_pb2_grpc

from opentelemetry import trace
from opentelemetry.instrumentation.grpc import client_interceptor
from opentelemetry.sdk.trace import Span,TracerProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.export import  SpanExporter, SpanExportResult



from logger import getJSONLogger
otlp_host = os.environ.get('OTLP_HOST')
otlp_port = os.environ.get('OTLP_PORT')
# create a CollectorSpanExporter
collector_exporter = OTLPSpanExporter(
     endpoint="http://"+otlp_host+":"+otlp_port,
      insecure=True
    # host_name="machine/container name",
)
resource=Resource.create({SERVICE_NAME: "recommandationserivce-server"})



# Configure the tracer to use the collector exporter
span_processor = BatchSpanProcessor(collector_exporter)
trace.set_tracer_provider(TracerProvider(resource=resource))
trace.get_tracer_provider().add_span_processor(span_processor)
tracer = trace.get_tracer(__name__)
logger = getJSONLogger('recommendationservice-client')

if __name__ == "__main__":
    # get port
    if len(sys.argv) > 1:
        port = sys.argv[1]
    else:
        port = "8080"

    with tracer.start_as_current_span("Recommendation client"):
        # set up server stub
        channel = grpc.insecure_channel('localhost:'+port)
        channel = grpc.intercept_channel(channel, client_interceptor())
        stub = demo_pb2_grpc.RecommendationServiceStub(channel)
        # form request
        request = demo_pb2.ListRecommendationsRequest(user_id="test", product_ids=["test"])
        # make call to server
        response = stub.ListRecommendations(request)
        logger.info(response)
