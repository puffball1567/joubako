# Joubako with NestJS

This integration pairs Joubako with a structured NestJS controller, DTO, and
validation pipeline. It demonstrates that NestJS validation failures remain
ordinary HTTP errors at the Joubako boundary.

## Backend implementation

The controller uses standard NestJS decorators:

```ts
@Controller("api")
export class DemoController {
  @Get("health")
  health() {
    return { ok: true, framework: "NestJS" };
  }

  @Post("messages")
  message(
    @Body() payload: MessageDto,
    @Headers("x-joubako-demo") client = "unknown",
  ) {
    return {
      accepted: true,
      ...payload,
      framework: "NestJS",
      client,
    };
  }
}
```

A global `ValidationPipe` rejects invalid DTOs with `422`. See the complete
[`controller`](../../examples/frameworks/nestjs/src/demo.controller.ts),
[`DTO`](../../examples/frameworks/nestjs/src/message.dto.ts), and
[`bootstrap`](../../examples/frameworks/nestjs/src/main.ts).

## Run NestJS

Node.js 20 or newer is required.

```sh
cd examples/frameworks/nestjs
npm ci
npm start
```

## Call NestJS from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:3001/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=NestJS \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The same Nim request model used for every other guide is serialized to the DTO;
the response is decoded into a Nim type without a NestJS-specific adapter.

## Production notes

Retain DTO whitelisting and validation, add application guards and interceptors,
and set deployment-level body and timeout limits. Keep Joubako retries limited
to requests that the NestJS endpoint can safely receive more than once.
