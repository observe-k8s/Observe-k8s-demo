using System;
using System.Collections.Generic;
using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using cartservice.cartstore;
using cartservice.services;
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Context.Propagation;
using Grpc.Core;

namespace cartservice
{
    public class Startup
    {
        public Startup(IConfiguration configuration)
        {
            Configuration = configuration;
        }
        const string OTLP_PORT="OTLP_PORT";
        const string OTLP_HOST = "OTLP_HOST";

        public IConfiguration Configuration { get; }
        
        // This method gets called by the runtime. Use this method to add services to the container.
        // For more information on how to configure your application, visit https://go.microsoft.com/fwlink/?LinkID=398940
        public void ConfigureServices(IServiceCollection services)
        {

            string otlpHost = Environment.GetEnvironmentVariable(OTLP_HOST);
            int otlpPort = Int32.Parse(Environment.GetEnvironmentVariable(OTLP_PORT));
            string cartserviceName = Environment.GetEnvironmentVariable("OTLP-SERVICENAME");
            var myActivitySource = new ActivitySource(cartserviceName);
            services.AddSingleton(myActivitySource);
            OpenTelemetry.Sdk.SetDefaultTextMapPropagator(new B3Propagator());

            string redisAddress = Configuration["REDIS_ADDR"];
            ICartStore cartStore = null;
            if (!string.IsNullOrEmpty(redisAddress))
            {
                cartStore = new RedisCartStore(redisAddress);
            }
            else
            {
                Console.WriteLine("Redis cache host(hostname+port) was not specified. Starting a cart service using local store");
                Console.WriteLine("If you wanted to use Redis Cache as a backup store, you should provide its address via command line or REDIS_ADDR environment variable.");
                cartStore = new LocalCartStore();
            }
             services.AddOpenTelemetryTracing((builder) => builder
                            .AddSource(cartserviceName)
                            .AddAspNetCoreInstrumentation(opt =>
                                {
                                    opt.EnableGrpcAspNetCoreSupport = true;
                                                                   })
                            .AddHttpClientInstrumentation()
                            .AddGrpcClientInstrumentation()
                            .AddConsoleExporter()
                            .AddRedisInstrumentation(cartStore.Connection)
                            .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(serviceName: cartserviceName, serviceVersion: "1.0"))
                            .AddOtlpExporter(opt => {
                                opt.Endpoint = new System.Uri("http://"+otlpHost+":"+otlpPort.ToString());
                            }
                            )
            );
            // Initialize the redis store
            cartStore.InitializeAsync().GetAwaiter().GetResult();
            Console.WriteLine("Initialization completed");

            services.AddSingleton<ICartStore>(cartStore);

            services.AddGrpc();
        }

        // This method gets called by the runtime. Use this method to configure the HTTP request pipeline.
        public void Configure(IApplicationBuilder app, IWebHostEnvironment env)
        {
            if (env.IsDevelopment())
            {
                app.UseDeveloperExceptionPage();
            }

            app.UseRouting();

            app.UseEndpoints(endpoints =>
                {
                    endpoints.MapGrpcService<CartService>();
                    endpoints.MapGrpcService<cartservice.services.HealthCheckService>();

                    endpoints.MapGet("/", async context =>
                    {
                        await context.Response.WriteAsync("Communication with gRPC endpoints must be made through a gRPC client. To learn how to create a client, visit: https://go.microsoft.com/fwlink/?linkid=2086909");
                    });
                }
            );
        }
    }
}