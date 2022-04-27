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

using System;
using System.Linq;
using System.Threading.Tasks;
using Grpc.Core;
using StackExchange.Redis;
using Google.Protobuf;
using System.Diagnostics;
using OpenTelemetry;
using OpenTelemetry.Resources;


namespace cartservice.cartstore
{
    public class RedisCartStore : ICartStore
    {
        private const string CART_FIELD_NAME = "cart";
        private const int REDIS_RETRY_NUM = 30;
        private volatile ConnectionMultiplexer redis;
        private volatile bool isRedisConnectionOpened = false;

        private readonly object locker = new object();
        private readonly byte[] emptyCartBytes;
        private readonly string connectionString;

        private readonly ConfigurationOptions redisConnectionOptions;

        public ConnectionMultiplexer Connection { get; }
        static  ActivitySource activitySource = new ActivitySource("OnlineBoutique.cartservice.Rediscartstore");
        public RedisCartStore(string redisAddress)
        {
            using (var activity = activitySource.StartActivity("RedisCartStore",ActivityKind.Server))
            {
                // Serialize empty cart into byte array.
                var cart = new Hipstershop.Cart();
                emptyCartBytes = cart.ToByteArray();
                connectionString = $"{redisAddress},ssl=false,allowAdmin=true,abortConnect=false";

                redisConnectionOptions = ConfigurationOptions.Parse(connectionString);

                // Try to reconnect multiple times if the first retry fails.
                redisConnectionOptions.ConnectRetry = REDIS_RETRY_NUM;
                redisConnectionOptions.ReconnectRetryPolicy = new ExponentialRetry(1000);

                redisConnectionOptions.KeepAlive = 180;
                 EnsureRedisConnected();
                Connection = redis;
            }
        }

        public Task InitializeAsync()
        {
            using (var activity  = activitySource.StartActivity("InitializeAsync",ActivityKind.Server))
            {
                EnsureRedisConnected();
            }
            return Task.CompletedTask;
        }

        private void EnsureRedisConnected()
        {
             using (var activity = activitySource.StartActivity("EnsureRedisConnected",ActivityKind.Server))
             {
                if (isRedisConnectionOpened)
                {
                    return;
                }

                // Connection is closed or failed - open a new one but only at the first thread
                lock (locker)
                {
                    if (isRedisConnectionOpened)
                    {
                        return;
                    }

                    Console.WriteLine("Connecting to Redis: " + connectionString);
                    redis = ConnectionMultiplexer.Connect(redisConnectionOptions);

                    if (redis == null || !redis.IsConnected)
                    {
                        activity?.AddEvent(new("Wasn't able to connect to redis"));
                        Console.WriteLine("Wasn't able to connect to redis");

                        // We weren't able to connect to Redis despite some retries with exponential backoff.
                        throw new ApplicationException("Wasn't able to connect to redis");
                    }
                    activity?.AddEvent(new("Successfully connected to Redis"));
                    Console.WriteLine("Successfully connected to Redis");
                    var cache = redis.GetDatabase();

                    activity?.AddEvent(new("Performing small test"));
                    Console.WriteLine("Performing small test");
                    cache.StringSet("cart", "OK" );
                    object res = cache.StringGet("cart");
                    Console.WriteLine($"Small test result: {res}");

                    redis.InternalError += (o, e) => { Console.WriteLine(e.Exception); };
                    redis.ConnectionRestored += (o, e) =>
                    {
                        isRedisConnectionOpened = true;
                        Console.WriteLine("Connection to redis was retored successfully");
                    };
                    redis.ConnectionFailed += (o, e) =>
                    {
                        Console.WriteLine("Connection failed. Disposing the object");
                        isRedisConnectionOpened = false;
                    };

                    isRedisConnectionOpened = true;
                }
            }

        }

        public async Task AddItemAsync(string userId, string productId, int quantity)
        {
             using (var activity  = activitySource.StartActivity("AddItemAsync",ActivityKind.Server))
             {


                activity?.AddEvent(new("AddItemAsync called with userId={userId}, productId={productId}, quantity={quantity}"));
                Console.WriteLine($"AddItemAsync called with userId={userId}, productId={productId}, quantity={quantity}");

                try
                {
                    EnsureRedisConnected();

                    var db = redis.GetDatabase();

                    // Access the cart from the cache
                    var value = await db.HashGetAsync(userId, CART_FIELD_NAME);

                    Hipstershop.Cart cart;
                    if (value.IsNull)
                    {
                        cart = new Hipstershop.Cart();
                        cart.UserId = userId;
                        cart.Items.Add(new Hipstershop.CartItem { ProductId = productId, Quantity = quantity });
                    }
                    else
                    {
                        cart = Hipstershop.Cart.Parser.ParseFrom(value);
                        var existingItem = cart.Items.SingleOrDefault(i => i.ProductId == productId);
                        if (existingItem == null)
                        {
                            cart.Items.Add(new Hipstershop.CartItem { ProductId = productId, Quantity = quantity });
                        }
                        else
                        {
                            existingItem.Quantity += quantity;
                        }
                    }

                    await db.HashSetAsync(userId, new[]{ new HashEntry(CART_FIELD_NAME, cart.ToByteArray()) });
                }
                catch (Exception ex)
                {
                    throw new RpcException(new Status(StatusCode.FailedPrecondition, $"Can't access cart storage. {ex}"));
                }
            }
        }

        public async Task EmptyCartAsync(string userId)
        {
            using (var activity = activitySource.StartActivity("EmptyCartAsync",ActivityKind.Server))
            {

                activity?.AddEvent(new("EmptyCartAsync called with userId={userId}"));

                Console.WriteLine($"EmptyCartAsync called with userId={userId}");

                try
                {
                    EnsureRedisConnected();
                    var db = redis.GetDatabase();

                    // Update the cache with empty cart for given user
                    await db.HashSetAsync(userId, new[] { new HashEntry(CART_FIELD_NAME, emptyCartBytes) });
                }
                catch (Exception ex)
                {
                    throw new RpcException(new Status(StatusCode.FailedPrecondition, $"Can't access cart storage. {ex}"));
                }
            }
        }

        public async Task<Hipstershop.Cart> GetCartAsync(string userId)
        {
            using (var activity = activitySource.StartActivity("GetCartAsync",ActivityKind.Server))
            {

                Console.WriteLine($"GetCartAsync called with userId={userId}");

                try
                {
                    EnsureRedisConnected();

                    var db = redis.GetDatabase();

                    // Access the cart from the cache
                    var value = await db.HashGetAsync(userId, CART_FIELD_NAME);

                    if (!value.IsNull)
                    {
                        return Hipstershop.Cart.Parser.ParseFrom(value);
                    }

                    // We decided to return empty cart in cases when user wasn't in the cache before
                    return new Hipstershop.Cart();
                }
                catch (Exception ex)
                {
                    throw new RpcException(new Status(StatusCode.FailedPrecondition, $"Can't access cart storage. {ex}"));
                }
            }
        }

        public bool Ping()
        {
            try
            {
                var cache = redis.GetDatabase();
                var res = cache.Ping();
                return res != TimeSpan.Zero;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
