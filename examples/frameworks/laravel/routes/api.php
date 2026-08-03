<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::get('/health', function () {
    return response()->json([
        'ok' => true,
        'framework' => 'Laravel',
    ]);
});

Route::get('/users/{id}', function (int $id) {
    if ($id !== 1) {
        return response()->json(['error' => 'user not found'], 404);
    }

    return response()->json([
        'id' => $id,
        'name' => 'Laravel User',
        'email' => 'laravel@example.test',
    ]);
})->whereNumber('id');

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
