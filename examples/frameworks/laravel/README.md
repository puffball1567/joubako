# Laravel server

This directory is a drop-in API route file for a Laravel 12 application. API
routes are opt-in in a fresh Laravel project, so create the project and enable
them first:

```sh
composer create-project laravel/laravel:^12.0 joubako-laravel-demo
cd joubako-laravel-demo
php artisan install:api
```

Replace the generated `routes/api.php` with
[`routes/api.php`](routes/api.php), then start Laravel:

```sh
php artisan serve --host=127.0.0.1 --port=8000
```

From the Joubako repository, run the shared client:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8000/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The demo routes are intentionally public. Add Sanctum or the authentication
middleware used by your application before exposing equivalent routes in
production.
