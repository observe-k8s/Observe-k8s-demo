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

import grpc

import demo_pb2
import demo_pb2_grpc
from opentelemetry import trace
from opentelemetry.instrumentation.grpc import client_interceptor
from opentelemetry.sdk.trace import TracerProvider,Span
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace.export import  SpanExporter, SimpleSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from logger import getJSONLogger
logger = getJSONLogger('emailservice-client')

otlp_host = os.environ.get('OTLP_HOST')
otlp_port = os.environ.get('OTLP_PORT')
# create a CollectorSpanExporter
collector_exporter = OTLPSpanExporter(
     endpoint="http://"+otlp_host+":"+otlp_port,
      insecure=True
    # host_name="machine/container name",
)
resource=Resource.create({SERVICE_NAME: "emailservice-client"})
# Create a BatchExportSpanProcessor and add the exporter to it
# Create a BatchExportSpanProcessor and add the exporter to it
span_processor = BatchSpanProcessor(collector_exporter)

# Configure the tracer to use the collector exporter
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(span_processor)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer_provider().get_tracer(__name__)


def send_confirmation_email(email, order):
  channel = grpc.insecure_channel('0.0.0.0:8080')
  channel = grpc.intercept_channel(channel,  client_interceptor())
  stub = demo_pb2_grpc.EmailServiceStub(channel)
  try:
    response = stub.SendOrderConfirmation(demo_pb2.SendOrderConfirmationRequest(
      email = email,
      order = order
    ))
    logger.info('Request sent.')
  except grpc.RpcError as err:
    logger.error(err.details())
    logger.error('{}, {}'.format(err.code().name, err.code().value))

if __name__ == '__main__':
  logger.info('Client for email service.')
