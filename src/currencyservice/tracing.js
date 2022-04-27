'use strict';

const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { SimpleSpanProcessor } = require('@opentelemetry/sdk-trace-base');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-otlp-grpc');
const opentelemetry = require('@opentelemetry/api');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');
const { BasicTracerProvider, ConsoleSpanExporter } = require('@opentelemetry/sdk-trace-base');
const { Resource } = require('@opentelemetry/resources');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { registerInstrumentations } = require('@opentelemetry/instrumentation');

module.exports = (serviceName) => {
  registerInstrumentations({
  instrumentations: [ getNodeAutoInstrumentations() ],
  });
  opentelemetry.diag.setLogger(
  new opentelemetry.DiagConsoleLogger(),
  opentelemetry.DiagLogLevel.DEBUG,
  );

  const exporter = new OTLPTraceExporter({
      url: 'http://'+process.env.OTLP_HOST+":"+process.env.OTLP_PORT+"/v1/traces", // url is optional and can be omitted - default is http://localhost:55681/v1/traces
      headers: {}, // an optional object containing custom headers to be sent with each request
      concurrencyLimit: 10, // an opt
  });

  const provider = new NodeTracerProvider({
       resource: new Resource({
              [SemanticResourceAttributes.SERVICE_NAME]: serviceName,
            }),
  });
  provider.addSpanProcessor(new SimpleSpanProcessor(exporter));
  provider.addSpanProcessor(new SimpleSpanProcessor(new ConsoleSpanExporter()));
  provider.register();

  const tracer = opentelemetry.trace.getTracer(serviceName);

  return opentelemetry.trace.getTracer(serviceName);
};