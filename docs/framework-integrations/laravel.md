# Joubako with Laravel

This integration pairs a Nim/Joubako client with Laravel API routes. The demo
is a drop-in route file rather than a generated Laravel project.

## Backend implementation

Laravel's validator and JSON responses directly implement the shared contract:

```php
Route::post('/messages', function (Request $request) {
    $message = $request->validate([
        'text' => ['required', 'string', 'max:200'],
        'priority' => ['required', 'integer', 'between:1,5'],
    ]);

    return response()->json([
        'accepted' => true,
        'text' => $message['text'],
        'priority' => $message['priority'],
        'framework' => 'Laravel',
        'client' => $request->header('X-Joubako-Demo', 'unknown'),
    ], 201);
});
```

See [`routes/api.php`](../../examples/frameworks/laravel/routes/api.php) for all
three routes.

## Create and run the backend

```sh
composer create-project laravel/laravel:^12.0 joubako-laravel-demo
cd joubako-laravel-demo
php artisan install:api
```

Replace the generated `routes/api.php` with the Joubako demo route file, then:

```sh
php artisan serve --host=127.0.0.1 --port=8000
```

The detailed setup is also available in the
[`Laravel demo README`](../../examples/frameworks/laravel/README.md).

## Call Laravel from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8000/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Laravel \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Production notes

The demo routes are intentionally public. Apply Sanctum or the application's
authentication middleware, authorization policies, throttling, and production
server configuration before exposing equivalent routes.
